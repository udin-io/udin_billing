defmodule UdinBilling.SubscriptionsTest do
  use UdinBilling.DataCase, async: false

  alias UdinBilling.{Access, Subscriptions}

  @start ~U[2026-10-10 09:00:00.000000Z]

  setup do
    %{user: user_fixture(), plan: subscription_plan_fixture()}
  end

  defp apply!(user, state, now \\ DateTime.add(@start, 60)) do
    {:ok, sub} = Subscriptions.apply_state("fake", user.id, state, now: now)
    sub
  end

  defp access(user, now), do: Access.load(user.id, now: now)

  # How a store reports a plan change: the old subscription now ends at the switch, then
  # the new one starts there (`apply_customer/4` applies them in this order).
  defp switch!(user, old, new, at) do
    apply!(user, %{old | period_ends_at: at, auto_renew: false}, at)
    apply!(user, new, at)
  end

  test "a new subscription grants its switches and counters", %{user: user} do
    apply!(user, sub_state())
    access = access(user, DateTime.add(@start, 3600))

    assert Access.enabled?(access, "share_recipe")
    assert Access.remaining(access, "reel_imports") == 15
  end

  test "a renewal starts a fresh cycle; nothing carries over", %{user: user} do
    state = sub_state()
    apply!(user, state)

    {:ok, _} =
      UdinBilling.consume(user.id, "reel_imports",
        reference: "e1",
        now: DateTime.add(@start, 120)
      )

    renewal = %{
      state
      | period_starts_at: state.period_ends_at,
        period_ends_at: DateTime.shift(state.period_ends_at, month: 1)
    }

    apply!(user, renewal, state.period_ends_at)

    assert Access.remaining(access(user, DateTime.add(state.period_ends_at, 60)), "reel_imports") ==
             15
  end

  test "cancelling keeps access until the period ends", %{user: user} do
    state = sub_state(%{auto_renew: false})
    sub = apply!(user, state)

    assert sub.auto_renew == false and sub.status == :active
    assert Access.enabled?(access(user, DateTime.add(state.period_ends_at, -60)), "share_recipe")
    refute Access.enabled?(access(user, DateTime.add(state.period_ends_at, 1)), "share_recipe")
  end

  test "the store's grace period keeps access", %{user: user} do
    state = sub_state()
    grace = DateTime.add(state.period_ends_at, 6, :day)
    apply!(user, Map.put(state, :grace_ends_at, grace))

    assert Access.enabled?(
             access(user, DateTime.add(state.period_ends_at, 3, :day)),
             "share_recipe"
           )

    refute Access.enabled?(access(user, DateTime.add(grace, 1)), "share_recipe")
  end

  test "a refund ends access at once and revokes units", %{user: user} do
    state = sub_state()
    apply!(user, state)

    {:ok, _} =
      UdinBilling.consume(user.id, "reel_imports",
        reference: "e1",
        now: DateTime.add(@start, 120)
      )

    refunded_at = DateTime.add(@start, 3600)
    sub = apply!(user, Map.put(state, :refunded_at, refunded_at), refunded_at)

    assert sub.status == :refunded
    after_refund = access(user, DateTime.add(refunded_at, 1))
    refute Access.enabled?(after_refund, "share_recipe")
    assert Access.remaining(after_refund, "reel_imports") == 0
  end

  test "applying the same state twice changes nothing", %{user: user} do
    state = sub_state()
    first = apply!(user, state)
    second = apply!(user, state)
    assert first.id == second.id
    assert [_] = Ash.read!(Subscription, authorize?: false)
  end

  test "sandbox purchases are refused unless allowed", %{user: user} do
    assert {:error, :sandbox_not_allowed} =
             Subscriptions.apply_state("fake", user.id, sub_state(%{sandbox: true}))

    with_env(:allow_sandbox, true, fn ->
      assert {:ok, _} = Subscriptions.apply_state("fake", user.id, sub_state(%{sandbox: true}))
    end)
  end

  test "unknown products and one-time products are refused", %{user: user} do
    assert {:error, {:unknown_product, "nope"}} =
             Subscriptions.apply_state("fake", user.id, sub_state(%{product_id: "nope"}))

    plan_fixture(%{provider_product_ids: %{"fake" => "one_reel"}})

    assert {:error, {:not_a_recurring_plan, _}} =
             Subscriptions.apply_state("fake", user.id, sub_state(%{product_id: "one_reel"}))
  end

  test "a yearly plan resets its counter monthly", %{user: user} do
    subscription_plan_fixture(%{
      code: "basic-yearly",
      validity_unit: :year,
      provider_product_ids: %{"fake" => "basic_yearly"}
    })

    apply!(
      user,
      sub_state(%{product_id: "basic_yearly", period_ends_at: DateTime.shift(@start, year: 1)})
    )

    {:ok, _} =
      UdinBilling.consume(user.id, "reel_imports",
        reference: "e1",
        now: DateTime.add(@start, 120)
      )

    assert Access.remaining(access(user, DateTime.add(@start, 3600)), "reel_imports") == 14

    assert Access.remaining(
             access(user, DateTime.shift(@start, month: 5, day: 1)),
             "reel_imports"
           ) == 15
  end

  test "a renewal of a deactivated plan still gives access and is reported", %{
    user: user,
    plan: plan
  } do
    state = sub_state()
    apply!(user, state)
    plan |> Ash.Changeset.for_update(:deactivate) |> Ash.update!(authorize?: false)
    refute Subscriptions.renewable?(Ash.get!(Plan, plan.id, authorize?: false))

    ref =
      :telemetry_test.attach_event_handlers(self(), [
        [:udin_billing, :subscription, :renewed_inactive_plan]
      ])

    renewal = %{
      state
      | period_starts_at: state.period_ends_at,
        period_ends_at: DateTime.shift(state.period_ends_at, month: 1)
    }

    apply!(user, renewal, state.period_ends_at)

    assert_received {[:udin_billing, :subscription, :renewed_inactive_plan], ^ref, _, _}
  end

  test "keeps the store it was bought in when a later update doesn't say", %{user: user} do
    state = sub_state(%{store: "app_store"})
    apply!(user, state)
    sub = apply!(user, %{Map.delete(state, :store) | auto_renew: false})

    assert sub.store == "app_store"
  end

  describe "plan changes" do
    setup do
      subscription_plan_fixture(%{
        code: "plus",
        provider_product_ids: %{"fake" => "plus_monthly"},
        features: %{"reel_imports" => 40, "share_recipe" => true}
      })

      :ok
    end

    defp upgrade(user, used) do
      basic = sub_state()
      apply!(user, basic)

      for n <- 1..used,
          do:
            {:ok, _} =
              UdinBilling.consume(user.id, "reel_imports",
                reference: "e#{n}",
                now: DateTime.add(@start, n * 60)
              )

      at = DateTime.add(@start, 3, :day)

      switch!(
        user,
        basic,
        sub_state(%{
          product_id: "plus_monthly",
          period_starts_at: at,
          period_ends_at: DateTime.shift(at, month: 1)
        }),
        at
      )

      Access.remaining(access(user, DateTime.add(at, 60)), "reel_imports")
    end

    test "switching before using any units gives only the new plan's", %{user: user} do
      basic = sub_state()
      apply!(user, basic)
      at = DateTime.add(@start, 3, :day)

      switch!(
        user,
        basic,
        sub_state(%{
          product_id: "plus_monthly",
          period_starts_at: at,
          period_ends_at: DateTime.shift(at, month: 1)
        }),
        at
      )

      # 40 (plus), not 40 + 15: the old plan's untouched month is withdrawn too.
      assert Access.remaining(access(user, DateTime.add(at, 60)), "reel_imports") == 40
    end

    test "two subscriptions paid at the same time both count, renewals included", %{
      user: user
    } do
      # Basic on one phone, Plus bought on another: neither replaces the other.
      basic = sub_state(%{provider_ref: "#{user.id}:basic_monthly"})
      apply!(user, basic)

      plus_start = DateTime.add(@start, 10, :day)

      apply!(
        user,
        sub_state(%{
          provider_ref: "#{user.id}:plus_monthly",
          product_id: "plus_monthly",
          period_starts_at: plus_start,
          period_ends_at: DateTime.shift(plus_start, month: 1)
        }),
        plus_start
      )

      assert Access.remaining(access(user, DateTime.add(plus_start, 60)), "reel_imports") == 55

      renewal = basic.period_ends_at

      apply!(
        user,
        %{basic | period_starts_at: renewal, period_ends_at: DateTime.shift(renewal, month: 1)},
        renewal
      )

      assert Access.remaining(access(user, DateTime.add(renewal, 60)), "reel_imports") == 55
    end

    test "switching back to an earlier plan withdraws the one in between", %{user: user} do
      basic = sub_state(%{provider_ref: "#{user.id}:basic_monthly"})
      apply!(user, basic)

      to_plus = DateTime.add(@start, 3, :day)

      plus =
        sub_state(%{
          provider_ref: "#{user.id}:plus_monthly",
          product_id: "plus_monthly",
          period_starts_at: to_plus,
          period_ends_at: DateTime.shift(to_plus, month: 1)
        })

      switch!(user, basic, plus, to_plus)

      # Back to Basic mid-way through Plus's month: the store reuses Basic's row.
      back = DateTime.add(@start, 10, :day)

      switch!(
        user,
        plus,
        %{basic | period_starts_at: back, period_ends_at: DateTime.shift(back, month: 1)},
        back
      )

      assert Access.remaining(access(user, DateTime.add(back, 60)), "reel_imports") == 15
    end

    test ":shift takes off what was spent, not what's only held", %{user: user} do
      with_env(:upgrade_policy, :shift, fn ->
        basic = sub_state()
        apply!(user, basic)

        for n <- 1..10 do
          {:ok, _} =
            UdinBilling.consume(user.id, "reel_imports",
              reference: "spent-#{n}",
              now: DateTime.add(@start, n * 60)
            )
        end

        {:ok, _} =
          UdinBilling.reserve(user.id, "reel_imports",
            reference: "held",
            now: DateTime.add(@start, 3600)
          )

        at = DateTime.add(@start, 3, :day)

        switch!(
          user,
          basic,
          sub_state(%{
            product_id: "plus_monthly",
            period_starts_at: at,
            period_ends_at: DateTime.shift(at, month: 1)
          }),
          at
        )

        # 40 - 10 spent; the held one wasn't spent, so it isn't taken off.
        assert Access.remaining(access(user, DateTime.add(at, 60)), "reel_imports") == 30
      end)
    end

    test ":fresh gives the new plan's full counter", %{user: user} do
      with_env(:upgrade_policy, :fresh, fn -> assert upgrade(user, 10) == 40 end)
    end

    test ":shift takes off what was used this cycle", %{user: user} do
      with_env(:upgrade_policy, :shift, fn -> assert upgrade(user, 10) == 30 end)
    end
  end

  describe "active/2" do
    test "subscriptions granting access now, for some users or for everyone", %{user: user} do
      other = user_fixture()
      lapsed_user = user_fixture()
      apply!(user, sub_state())
      apply!(other, sub_state())

      lapsed = %{
        sub_state()
        | period_starts_at: DateTime.add(@start, -40, :day),
          period_ends_at: DateTime.add(@start, -10, :day)
      }

      apply!(lapsed_user, lapsed)

      at = DateTime.add(@start, 3600)

      assert [%{user_id: user_id}] = Subscriptions.active(at, [user.id])
      assert user_id == user.id

      assert at
             |> Subscriptions.active()
             |> Enum.map(& &1.user_id)
             |> Enum.sort() == Enum.sort([user.id, other.id])
    end

    test "a refunded subscription doesn't count", %{user: user} do
      state = sub_state()
      apply!(user, state)

      apply!(
        user,
        Map.put(state, :refunded_at, DateTime.add(@start, 120)),
        DateTime.add(@start, 180)
      )

      assert Subscriptions.active(DateTime.add(@start, 3600)) == []
    end
  end

  describe "apply_customer" do
    test "applies subscriptions and one-time top-ups, refunds included; skips bad items", %{
      user: user
    } do
      plan_fixture(%{
        code: "one_reel",
        price: Decimal.new(15),
        validity_unit: nil,
        validity_count: nil,
        provider_product_ids: %{"fake" => "one_reel"},
        features: %{"reel_imports" => 1}
      })

      customer = %{
        subscriptions: [sub_state(), sub_state(%{product_id: "ghost"})],
        one_time: [
          %{provider_ref: "t1", product_id: "one_reel", paid_at: @start},
          %{
            provider_ref: "t2",
            product_id: "one_reel",
            paid_at: @start,
            refunded_at: DateTime.add(@start, 10)
          }
        ]
      }

      assert {:ok, %{applied: 3, skipped: [{_ref, {:unknown_product, "ghost"}}]}} =
               UdinBilling.apply_customer("fake", user.id, customer,
                 now: DateTime.add(@start, 60)
               )

      assert Access.remaining(access(user, DateTime.add(@start, 3600)), "reel_imports") == 16

      assert {:ok, %{applied: 3}} =
               UdinBilling.apply_customer("fake", user.id, customer,
                 now: DateTime.add(@start, 60)
               )

      assert length(Ash.read!(Purchase, authorize?: false)) == 2
    end
  end
end

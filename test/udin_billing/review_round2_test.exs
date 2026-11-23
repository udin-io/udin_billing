defmodule UdinBilling.ReviewRound2Test do
  @moduledoc "Regression tests for the second independent review."
  use UdinBilling.DataCase, async: false

  alias UdinBilling.{Access, FeatureValue, Purchases, Quotas, Subscriptions, Webhooks}

  @start ~U[2026-10-10 09:00:00.000000Z]

  setup do
    %{user: user_fixture()}
  end

  defp apply!(user, state, now) do
    {:ok, sub} = Subscriptions.apply_state("fake", user.id, state, now: now)
    sub
  end

  defp left(user, now), do: Access.remaining(Access.load(user.id, now: now), "reel_imports")

  test "a plan with two counters grants both", %{user: user} do
    plan = plan_fixture(%{features: %{"rides" => 2, "reel_imports" => 3}})
    paid_purchase_fixture(user, plan)

    {:ok, _} = UdinBilling.consume(user.id, "rides", reference: "r1")
    assert {:ok, %{remaining: 3}} = Quotas.balance(user.id, "reel_imports")
    assert {:ok, _} = UdinBilling.consume(user.id, "reel_imports", reference: "x1")
  end

  test "a subscription the store ends early can't be spent from, matching the balance", %{
    user: user
  } do
    subscription_plan_fixture()
    state = sub_state()
    apply!(user, state, DateTime.add(@start, 60))

    {:ok, _} =
      UdinBilling.consume(user.id, "reel_imports", reference: "a", now: DateTime.add(@start, 120))

    apply!(
      user,
      %{state | period_ends_at: DateTime.add(@start, 1, :day)},
      DateTime.add(@start, 2, :day)
    )

    at = DateTime.add(@start, 3, :day)
    assert left(user, at) == 0

    assert {:error, :insufficient_quota} =
             UdinBilling.consume(user.id, "reel_imports", reference: "b", now: at)
  end

  test "a renewal doesn't carry the previous period's units over", %{user: user} do
    subscription_plan_fixture()
    state = sub_state()
    apply!(user, state, DateTime.add(@start, 60))

    {:ok, _} =
      UdinBilling.consume(user.id, "reel_imports", reference: "a", now: DateTime.add(@start, 120))

    # Store reports the renewal a day early (period starts before the old lot's end).
    early = DateTime.add(state.period_ends_at, -1, :day)

    apply!(
      user,
      %{state | period_starts_at: early, period_ends_at: DateTime.shift(early, month: 1)},
      DateTime.add(early, 60)
    )

    assert left(user, DateTime.add(early, 120)) == 15

    spent =
      for n <- 1..20 do
        UdinBilling.consume(user.id, "reel_imports",
          reference: "c#{n}",
          now: DateTime.add(early, 120)
        )
      end

    assert Enum.count(spent, &match?({:ok, _}, &1)) == 15
  end

  test "grace keeps features but grants no new unpaid month of units", %{user: user} do
    subscription_plan_fixture()
    state = sub_state()
    apply!(user, state, DateTime.add(@start, 60))

    apply!(
      user,
      Map.put(state, :grace_ends_at, DateTime.add(state.period_ends_at, 16, :day)),
      DateTime.add(state.period_ends_at, 60)
    )

    in_grace = DateTime.add(state.period_ends_at, 2, :day)
    access = Access.load(user.id, now: in_grace)
    assert Access.enabled?(access, "share_recipe")
    assert Access.remaining(access, "reel_imports") == 0

    assert {:error, :insufficient_quota} =
             UdinBilling.consume(user.id, "reel_imports", reference: "g", now: in_grace)
  end

  test "in grace, the free plan's allowance is back: a subscription only replaces it while paid",
       %{user: user} do
    free_plan_fixture(%{features: %{"reel_imports" => 3}})
    subscription_plan_fixture()
    state = sub_state()
    apply!(user, state, DateTime.add(@start, 60))

    apply!(
      user,
      Map.put(state, :grace_ends_at, DateTime.add(state.period_ends_at, 16, :day)),
      DateTime.add(state.period_ends_at, 60)
    )

    in_grace = DateTime.add(state.period_ends_at, 2, :day)
    access = Access.load(user.id, now: in_grace)

    # The plan's features stay on (grace), and the user has at least the free imports.
    assert Access.enabled?(access, "share_recipe")
    assert Access.remaining(access, "reel_imports") == 3
  end

  test "with grace_access off, access stops at the paid period's end until payment succeeds",
       %{user: user} do
    subscription_plan_fixture()
    state = sub_state()
    apply!(user, state, DateTime.add(@start, 60))
    grace = Map.put(state, :grace_ends_at, DateTime.add(state.period_ends_at, 16, :day))
    sub = apply!(user, grace, DateTime.add(state.period_ends_at, 60))
    assert sub.status == :grace

    in_grace = DateTime.add(state.period_ends_at, 2, :day)
    assert Access.enabled?(Access.load(user.id, now: in_grace), "share_recipe")

    with_env(:grace_access, false, fn ->
      refute Access.enabled?(Access.load(user.id, now: in_grace), "share_recipe")

      # The payment succeeds: the store reports the new paid period.
      renewed = %{
        state
        | period_starts_at: state.period_ends_at,
          period_ends_at: DateTime.shift(state.period_ends_at, month: 1)
      }

      apply!(user, Map.put(renewed, :grace_ends_at, nil), DateTime.add(in_grace, 60))
      access = Access.load(user.id, now: DateTime.add(in_grace, 120))
      assert Access.enabled?(access, "share_recipe")
      assert Access.remaining(access, "reel_imports") == 15
    end)
  end

  test "an invalid grace_access value fails loudly" do
    with_env(:grace_access, "yes", fn ->
      assert_raise ArgumentError, ~r/grace_access/, fn -> UdinBilling.Config.grace_access?() end
    end)
  end

  test ":shift doesn't carry last month's use into a plan that starts at the period boundary", %{
    user: user
  } do
    subscription_plan_fixture()

    subscription_plan_fixture(%{
      code: "plus",
      provider_product_ids: %{"fake" => "plus_monthly"},
      features: %{"reel_imports" => 40, "share_recipe" => true}
    })

    with_env(:upgrade_policy, :shift, fn ->
      basic = sub_state(%{auto_renew: false})
      apply!(user, basic, DateTime.add(@start, 60))

      for n <- 1..15,
          do:
            {:ok, _} =
              UdinBilling.consume(user.id, "reel_imports",
                reference: "e#{n}",
                now: DateTime.add(@start, n * 60)
              )

      at = basic.period_ends_at

      apply!(
        user,
        sub_state(%{
          product_id: "plus_monthly",
          period_starts_at: at,
          period_ends_at: DateTime.shift(at, month: 1)
        }),
        DateTime.add(at, 30)
      )

      assert left(user, DateTime.add(at, 60)) == 40
    end)
  end

  test "a store top-up of a deactivated plan still counts and doesn't block the rest", %{
    user: user
  } do
    subscription_plan_fixture()

    reel =
      plan_fixture(%{
        code: "one_reel",
        price: Decimal.new(15),
        validity_unit: nil,
        validity_count: nil,
        provider_product_ids: %{"fake" => "one_reel"},
        features: %{"reel_imports" => 1}
      })

    reel |> Ash.Changeset.for_update(:deactivate) |> Ash.update!(authorize?: false)

    now = DateTime.utc_now()

    params = %{
      "event_id" => "cc-1",
      "type" => "customer_changed",
      "user_id" => user.id,
      "customer" => %{
        "subscriptions" => [
          %{
            "provider_ref" => "s1",
            "product_id" => "basic_monthly",
            "period_starts_at" => DateTime.to_iso8601(DateTime.add(now, -60)),
            "period_ends_at" => DateTime.to_iso8601(DateTime.shift(now, month: 1))
          }
        ],
        "one_time" => [
          %{
            "provider_ref" => "t1",
            "product_id" => "one_reel",
            "paid_at" => DateTime.to_iso8601(DateTime.add(now, -30))
          },
          %{
            "provider_ref" => "t2",
            "product_id" => "ghost",
            "paid_at" => DateTime.to_iso8601(now)
          }
        ]
      }
    }

    # The unknown "ghost" product fails the message (shown for review), but everything else
    # in it is applied.
    assert {:ok, :failed} =
             Webhooks.handle("fake", params, %{"x-fake-signature" => "a-long-test-secret-value"})

    assert [_] = Ash.read!(Subscription, authorize?: false)
    assert [%{status: :paid}] = Ash.read!(Purchase, authorize?: false)
    assert Access.remaining(Access.load(user.id), "reel_imports") == 16
  end

  test "an older subscription state never rolls a newer one back", %{user: user} do
    subscription_plan_fixture()
    old = sub_state()

    renewed = %{
      old
      | period_starts_at: old.period_ends_at,
        period_ends_at: DateTime.shift(old.period_ends_at, month: 1)
    }

    apply!(user, renewed, DateTime.add(renewed.period_starts_at, 60))

    sub = apply!(user, old, DateTime.add(renewed.period_starts_at, 120))
    assert DateTime.compare(sub.period_starts_at, renewed.period_starts_at) == :eq
    assert sub.status == :active
  end

  test "single_active: a declined checkout still counts as open until it expires", %{user: user} do
    plan = plan_fixture()

    with_env(:purchase_policy, :single_active, fn ->
      {:ok, first} = Purchases.start(user.id, plan.id, "fake")
      {:ok, _} = Purchases.fail(first.id, "declined")
      assert {:error, _} = Purchases.start(user.id, plan.id, "fake")
    end)
  end

  test "changing the free plan's cycle shape gives the new allowance", %{user: user} do
    free = free_plan_fixture(%{validity_unit: nil, cycle_unit: :month, cycle_count: 1})
    {:ok, _} = UdinBilling.ensure_account(user.id, @start)

    for n <- 1..3,
        do:
          {:ok, _} =
            UdinBilling.consume(user.id, "reel_imports",
              reference: "f#{n}",
              now: DateTime.add(@start, n)
            )

    free
    |> Ash.Changeset.for_update(:update, %{cycle_unit: nil, cycle_count: nil})
    |> Ash.update!(authorize?: false)

    assert left(user, DateTime.add(@start, 10)) == 3
  end

  test "admin form values are accepted: \"15\", \"true\", \"unlimited\"" do
    assert {:ok, 15} = FeatureValue.normalize(:counter, "15")
    assert {:ok, "unlimited"} = FeatureValue.normalize(:counter, "unlimited")
    assert {:ok, true} = FeatureValue.normalize(:switch, "true")
    assert {:ok, false} = FeatureValue.normalize(:switch, "false")
    assert {:error, _} = FeatureValue.normalize(:counter, "-1")
    assert {:error, _} = FeatureValue.normalize(:counter, "1.5")
  end
end

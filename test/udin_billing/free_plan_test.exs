defmodule UdinBilling.FreePlanTest do
  @moduledoc """
  How the free (default) plan combines with paid plans: a subscription replaces it while
  the subscription grants access; one-time purchases add on top of it.
  """
  use UdinBilling.DataCase, async: false

  alias UdinBilling.{Access, Subscriptions}

  @t0 ~U[2026-10-01 10:00:00.000000Z]
  @sub_start ~U[2026-10-10 09:00:00.000000Z]

  setup do
    user = user_fixture()
    {:ok, _} = UdinBilling.ensure_account(user.id, @t0)
    %{user: user}
  end

  defp subscribe(user, attrs \\ %{}) do
    subscription_plan_fixture(%{features: %{"reel_imports" => 15, "share_recipe" => true}})
    state = sub_state(Map.merge(%{period_starts_at: @sub_start}, attrs))
    {:ok, sub} = Subscriptions.apply_state("fake", user.id, state, now: @sub_start)
    sub
  end

  defp lifetime_fresh_start_plan do
    free_plan_fixture(%{
      cycle_unit: nil,
      cycle_count: nil,
      after_subscription: :fresh_start,
      features: %{"reel_imports" => 5}
    })
  end

  defp remaining(user, at),
    do: user.id |> Access.load(now: at) |> Access.remaining("reel_imports")

  defp use_reels(user, count, at) do
    for n <- 1..count do
      {:ok, _} =
        UdinBilling.consume(user.id, "reel_imports", reference: "use-#{at}-#{n}", now: at)
    end
  end

  test "a subscription replaces the free plan: Basic gives 15, not 15 + 3", %{user: user} do
    free_plan_fixture(%{features: %{"reel_imports" => 3, "meal_plan" => true}})
    subscribe(user)

    access = Access.load(user.id, now: DateTime.add(@sub_start, 60))
    assert Access.remaining(access, "reel_imports") == 15
    assert Access.enabled?(access, "share_recipe")
    # The free plan's switches are off too while it's replaced.
    refute Access.enabled?(access, "meal_plan")
    assert [%{kind: :subscription}] = access.sources
  end

  test "free credits used before subscribing stay used when the user is back on free",
       %{user: user} do
    free_plan_fixture()
    use_reels(user, 3, DateTime.add(@t0, 60))
    assert remaining(user, DateTime.add(@t0, 120)) == 0

    subscribe(user)
    assert remaining(user, DateTime.add(@sub_start, 60)) == 15

    # The subscription ends Nov 10; the free month (from Oct 1) runs until Nov 1, then Dec 1.
    # Back on free on Nov 12: the free month that started Nov 1 is fresh.
    assert remaining(user, ~U[2026-11-12 10:00:00.000000Z]) == 3
  end

  test "coming back within the same free month doesn't refill it", %{user: user} do
    free_plan_fixture()
    use_reels(user, 3, ~U[2026-10-02 10:00:00.000000Z])

    # A one-week subscription inside the October free month.
    subscribe(user, %{period_ends_at: ~U[2026-10-17 09:00:00.000000Z]})
    assert remaining(user, ~U[2026-10-12 10:00:00.000000Z]) == 15

    # Oct 20: subscription over, still the same free month (Oct 1 - Nov 1): nothing new.
    assert remaining(user, ~U[2026-10-20 10:00:00.000000Z]) == 0
    assert remaining(user, ~U[2026-11-01 10:00:01.000000Z]) == 3
  end

  test "a lifetime free plan is given once, even after a subscription ends", %{user: user} do
    free_plan_fixture(%{cycle_unit: nil, cycle_count: nil, features: %{"reel_imports" => 5}})
    use_reels(user, 2, DateTime.add(@t0, 60))

    subscribe(user)
    assert remaining(user, DateTime.add(@sub_start, 60)) == 15

    later = ~U[2027-03-01 10:00:00.000000Z]
    assert remaining(user, later) == 3
  end

  describe "after_subscription: :fresh_start" do
    test "a lifetime allowance is given again after a subscription ends", %{user: user} do
      free_plan_fixture(%{
        cycle_unit: nil,
        cycle_count: nil,
        after_subscription: :fresh_start,
        features: %{"reel_imports" => 5}
      })

      use_reels(user, 2, DateTime.add(@t0, 60))
      subscribe(user)

      assert remaining(user, ~U[2026-11-11 10:00:00.000000Z]) == 5
    end

    test "a monthly allowance starts a new month on the day the subscription ended",
         %{user: user} do
      free_plan_fixture(%{after_subscription: :fresh_start})
      use_reels(user, 3, ~U[2026-10-02 10:00:00.000000Z])

      subscribe(user, %{period_ends_at: ~U[2026-10-17 09:00:00.000000Z]})

      back = ~U[2026-10-20 10:00:00.000000Z]
      assert remaining(user, back) == 3

      assert %{resets_at: ~U[2026-11-17 09:00:00.000000Z]} =
               Access.load(user.id, now: back).counters["reel_imports"]
    end

    test "only applies when subscriptions replace the free plan", %{user: user} do
      free_plan_fixture(%{after_subscription: :fresh_start})
      use_reels(user, 3, ~U[2026-10-02 10:00:00.000000Z])
      subscribe(user, %{period_ends_at: ~U[2026-10-17 09:00:00.000000Z]})

      with_env(:free_plan_with_subscription, :keep, fn ->
        assert remaining(user, ~U[2026-10-20 10:00:00.000000Z]) == 0
      end)
    end

    test "the store's grace period after a failed renewal gives nothing new", %{user: user} do
      lifetime_fresh_start_plan()
      use_reels(user, 5, DateTime.add(@t0, 60))

      paid_end = ~U[2026-11-10 09:00:00.000000Z]

      subscribe(user, %{
        period_ends_at: paid_end,
        grace_ends_at: DateTime.add(paid_end, 16, :day)
      })

      assert remaining(user, DateTime.add(paid_end, 1, :day)) == 0
    end

    test "the allowance comes back once the grace period is over", %{user: user} do
      lifetime_fresh_start_plan()
      use_reels(user, 5, DateTime.add(@t0, 60))

      paid_end = ~U[2026-11-10 09:00:00.000000Z]
      grace_end = DateTime.add(paid_end, 16, :day)
      subscribe(user, %{period_ends_at: paid_end, grace_ends_at: grace_end})

      assert remaining(user, DateTime.add(grace_end, 60)) == 5
    end

    test "a refunded subscription gives nothing new", %{user: user} do
      lifetime_fresh_start_plan()
      use_reels(user, 5, DateTime.add(@t0, 60))

      subscribe(user, %{refunded_at: DateTime.add(@sub_start, 1, :day)})

      assert remaining(user, DateTime.add(@sub_start, 2, :day)) == 0
    end

    test "a user who never subscribed just has the normal allowance", %{user: user} do
      free_plan_fixture(%{after_subscription: :fresh_start})
      use_reels(user, 1, DateTime.add(@t0, 60))

      assert remaining(user, DateTime.add(@t0, 120)) == 2
    end
  end

  test "one-time purchases add on top of the free plan", %{user: user} do
    free_plan_fixture()

    top_up =
      plan_fixture(%{validity_unit: nil, validity_count: nil, features: %{"reel_imports" => 1}})

    paid_purchase_fixture(user, top_up, paid_at: DateTime.add(@t0, 60))

    assert remaining(user, DateTime.add(@t0, 120)) == 4
  end

  test "a top-up still adds on top of a subscription", %{user: user} do
    free_plan_fixture()
    subscribe(user)

    top_up =
      plan_fixture(%{validity_unit: nil, validity_count: nil, features: %{"reel_imports" => 1}})

    paid_purchase_fixture(user, top_up, paid_at: DateTime.add(@sub_start, 60))

    assert remaining(user, DateTime.add(@sub_start, 120)) == 16
  end

  test "apps can keep the free plan alongside subscriptions", %{user: user} do
    free_plan_fixture()
    subscribe(user)

    with_env(:free_plan_with_subscription, :keep, fn ->
      assert remaining(user, DateTime.add(@sub_start, 60)) == 18
    end)
  end

  test "a wrong setting fails loudly", %{user: user} do
    free_plan_fixture()
    subscribe(user)

    with_env(:free_plan_with_subscription, :sometimes, fn ->
      assert_raise ArgumentError, ~r/free_plan_with_subscription/, fn ->
        remaining(user, DateTime.add(@sub_start, 60))
      end
    end)
  end
end

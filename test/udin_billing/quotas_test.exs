defmodule UdinBilling.QuotasTest do
  use UdinBilling.DataCase, async: false

  require Ash.Query

  alias UdinBilling.Quotas

  @t0 ~U[2026-11-01 10:00:00.000000Z]

  setup do
    %{user: user_fixture()}
  end

  defp at(minutes), do: DateTime.add(@t0, minutes, :minute)
  defp days(n), do: DateTime.add(@t0, n, :day)
  defp left(user, key, now), do: elem(Quotas.balance(user.id, key, now: now), 1).remaining

  defp bundle(user, rides, days, paid_at \\ @t0) do
    plan =
      plan_fixture(%{validity_unit: :day, validity_count: days, features: %{"rides" => rides}})

    paid_purchase_fixture(user, plan, paid_at: paid_at)
  end

  describe "consume/3" do
    test "spends from the soonest-expiring bundle first", %{user: user} do
      bundle(user, 5, 30)
      short = bundle(user, 5, 1)

      assert {:ok, [usage]} = Quotas.consume(user.id, "rides", reference: "b1", now: at(1))
      assert Ash.get!(Grant, usage.grant_id, authorize?: false).purchase_id == short.id
      assert usage.status == :committed
      assert left(user, "rides", at(2)) == 9
    end

    test "spans bundles when one doesn't cover the amount", %{user: user} do
      bundle(user, 1, 1)
      bundle(user, 5, 30)

      assert {:ok, [a, b]} =
               Quotas.consume(user.id, "rides", reference: "b1", amount: 3, now: at(1))

      assert {a.amount, b.amount} == {1, 2}
      assert left(user, "rides", at(2)) == 3
    end

    test "running out spends nothing", %{user: user} do
      bundle(user, 1, 7)
      {:ok, _} = Quotas.consume(user.id, "rides", reference: "b1", now: at(1))

      assert {:error, :insufficient_quota} =
               Quotas.consume(user.id, "rides", reference: "b2", now: at(2))

      assert [_one] = Ash.read!(Usage, authorize?: false)
    end

    test "expired bundles don't count", %{user: user} do
      bundle(user, 5, 1)
      assert left(user, "rides", days(2)) == 0

      assert {:error, :insufficient_quota} =
               Quotas.consume(user.id, "rides", reference: "b1", now: days(2))
    end

    test "the same reference is charged once", %{user: user} do
      bundle(user, 5, 7)
      {:ok, [first]} = Quotas.consume(user.id, "rides", reference: "booking-9", now: at(1))
      {:ok, [again]} = Quotas.consume(user.id, "rides", reference: "booking-9", now: at(2))

      assert first.id == again.id
      assert left(user, "rides", at(3)) == 4
    end

    test "unknown counters and switches are refused", %{user: user} do
      assert {:error, :unknown_counter} = Quotas.consume(user.id, "seats", reference: "x")
      assert {:error, :unknown_counter} = Quotas.consume(user.id, "share_recipe", reference: "x")
    end

    test "an unlimited plan never runs out", %{user: user} do
      plan_fixture(%{features: %{"rides" => :unlimited}})
      |> then(&paid_purchase_fixture(user, &1, paid_at: @t0))

      for n <- 1..20,
          do: assert({:ok, _} = Quotas.consume(user.id, "rides", reference: "b#{n}", now: at(n)))

      assert left(user, "rides", at(30)) == :unlimited
    end
  end

  describe "free plan cycles" do
    test "start on the user's own date and don't carry over", %{user: user} do
      free_plan_fixture()
      {:ok, _} = UdinBilling.ensure_account(user.id, ~U[2026-10-10 08:00:00.000000Z])

      {:ok, _} =
        Quotas.consume(user.id, "reel_imports", reference: "e1", now: ~U[2026-10-20 00:00:00Z])

      assert left(user, "reel_imports", ~U[2026-11-10 07:59:59Z]) == 2

      # New cycle on the 10th at 08:00: a full 3, the unused 2 are gone.
      assert left(user, "reel_imports", ~U[2026-11-10 08:00:00Z]) == 3

      assert {:ok, balance} =
               Quotas.balance(user.id, "reel_imports", now: ~U[2026-11-10 08:00:00Z])

      assert balance.resets_at == ~U[2026-12-10 08:00:00.000000Z]
    end

    test "a lifetime free plan (no cycle) grants its units once, never resetting", %{user: user} do
      free_plan_fixture(%{cycle_unit: nil, cycle_count: nil})
      {:ok, _} = UdinBilling.ensure_account(user.id, @t0)

      for n <- 1..3,
          do: {:ok, _} = Quotas.consume(user.id, "reel_imports", reference: "e#{n}", now: at(n))

      years_later = DateTime.shift(@t0, year: 3)
      assert left(user, "reel_imports", years_later) == 0

      assert {:error, :insufficient_quota} =
               Quotas.consume(user.id, "reel_imports", reference: "e4", now: years_later)
    end

    test "a weekly free plan resets every week from the user's start", %{user: user} do
      free_plan_fixture(%{cycle_unit: :week, cycle_count: 1})
      {:ok, _} = UdinBilling.ensure_account(user.id, @t0)

      {:ok, _} = Quotas.consume(user.id, "reel_imports", reference: "e1", amount: 3, now: at(1))
      assert left(user, "reel_imports", days(6)) == 0
      assert left(user, "reel_imports", days(7)) == 3
    end

    test "without an account, the first spend anchors the cycle", %{user: user} do
      free_plan_fixture()
      {:ok, _} = Quotas.consume(user.id, "reel_imports", reference: "e1", now: @t0)

      assert %{anchor_at: @t0} = Ash.read_one!(Account, authorize?: false)
      assert left(user, "reel_imports", DateTime.shift(@t0, month: 1)) == 3
    end
  end

  describe "top-ups" do
    test "never expire and are used only after the plan's units", %{user: user} do
      free_plan_fixture()

      top_up =
        plan_fixture(%{
          code: "one_reel",
          price: Decimal.new(15),
          validity_unit: nil,
          validity_count: nil,
          features: %{"reel_imports" => 1}
        })

      {:ok, _} = UdinBilling.ensure_account(user.id, @t0)
      paid_purchase_fixture(user, top_up, paid_at: @t0)

      assert left(user, "reel_imports", at(1)) == 4

      for n <- 1..3,
          do: {:ok, _} = Quotas.consume(user.id, "reel_imports", reference: "e#{n}", now: at(n))

      assert left(user, "reel_imports", at(10)) == 1

      # A year later: a fresh free 3 plus the top-up, still there.
      later = DateTime.shift(@t0, year: 1, day: 3)
      assert left(user, "reel_imports", later) == 4

      for n <- 1..4,
          do:
            {:ok, _} = Quotas.consume(user.id, "reel_imports", reference: "late#{n}", now: later)

      assert {:error, :insufficient_quota} =
               Quotas.consume(user.id, "reel_imports", reference: "late5", now: later)
    end
  end

  describe "holds" do
    setup %{user: user} do
      bundle(user, 2, 7)
      :ok
    end

    test "reserve takes units; commit counts them", %{user: user} do
      assert {:ok, [%{status: :held}]} =
               Quotas.reserve(user.id, "rides", reference: "x1", now: at(1))

      assert left(user, "rides", at(2)) == 1

      assert {:ok, [%{status: :committed}]} =
               Quotas.commit(user.id, "rides", reference: "x1", now: at(3))

      assert {:ok, [%{status: :committed}]} =
               Quotas.commit(user.id, "rides", reference: "x1", now: at(4))

      assert left(user, "rides", at(5)) == 1
    end

    test "release gives units back; releasing a committed spend is refused", %{user: user} do
      {:ok, _} = Quotas.reserve(user.id, "rides", reference: "x1", now: at(1))

      assert {:ok, [%{status: :released}]} =
               Quotas.release(user.id, "rides", reference: "x1", now: at(2))

      assert left(user, "rides", at(3)) == 2
      assert {:ok, []} = Quotas.release(user.id, "rides", reference: "x1", now: at(3))

      {:ok, _} = Quotas.consume(user.id, "rides", reference: "x2", now: at(4))

      assert {:error, :already_committed} =
               Quotas.release(user.id, "rides", reference: "x2", now: at(5))
    end

    test "a reserved unit can't be taken by another request", %{user: user} do
      {:ok, _} = Quotas.reserve(user.id, "rides", reference: "x1", now: at(1))
      {:ok, _} = Quotas.reserve(user.id, "rides", reference: "x2", now: at(1))

      assert {:error, :insufficient_quota} =
               Quotas.reserve(user.id, "rides", reference: "x3", now: at(1))

      assert {:ok, [%{status: :held}]} =
               Quotas.reserve(user.id, "rides", reference: "x1", now: at(2))
    end

    test "a lapsed hold gives its units back", %{user: user} do
      with_env(:hold_ttl, 60, fn ->
        {:ok, _} = Quotas.reserve(user.id, "rides", reference: "x1", now: at(0))
        {:ok, _} = Quotas.reserve(user.id, "rides", reference: "x2", now: at(0))

        assert left(user, "rides", at(0)) == 0
        assert left(user, "rides", at(2)) == 2

        assert {:ok, [%{reference: "x3"}]} =
                 Quotas.reserve(user.id, "rides", reference: "x3", now: at(2))

        assert [%{status: :released}] =
                 Ash.read!(Usage |> Ash.Query.filter(reference == "x1"), authorize?: false)
      end)
    end

    test "committing after the hold lapsed charges again only if units are left", %{user: user} do
      with_env(:hold_ttl, 60, fn ->
        {:ok, _} = Quotas.reserve(user.id, "rides", reference: "slow", now: at(0))
        # Someone else spends after the hold lapsed and takes its unit back.
        {:ok, _} = Quotas.consume(user.id, "rides", reference: "a", now: at(2))
        {:ok, _} = Quotas.consume(user.id, "rides", reference: "b", now: at(2))

        assert {:error, :insufficient_quota} =
                 Quotas.commit(user.id, "rides", reference: "slow", now: at(3))
      end)
    end
  end
end

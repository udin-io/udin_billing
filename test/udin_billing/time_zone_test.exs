defmodule UdinBilling.TimeZoneTest do
  @moduledoc """
  Billing compares moments (expiry, access end, hold timeout, stale checkouts) in SQL.
  They must be right whatever the app's database session time zone (Family-Corp's runs
  in Africa/Cairo) and whatever the app's Ash setup: apps that register
  `AshPostgres.Timestamptz(Usec)` as known types make AshSql compare times as
  `timestamptz`. Billing stores timestamps as `timestamptz`, so a moment is a moment.
  """
  use UdinBilling.DataCase, async: false

  alias UdinBilling.{Access, Purchases}

  setup do
    UdinBilling.TestRepo.query!("SET TIME ZONE 'Africa/Cairo'")

    # Family-Corp's Ash config.
    previous = Application.get_env(:ash, :known_types)

    Application.put_env(:ash, :known_types, [AshPostgres.Timestamptz, AshPostgres.TimestamptzUsec])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:ash, :known_types, previous),
        else: Application.delete_env(:ash, :known_types)
    end)

    %{user: user_fixture()}
  end

  test "a checkout started just now isn't stale", %{user: user} do
    {:ok, checkout} = Purchases.start(user.id, plan_fixture().id, "fake")

    assert {:ok, 0} = Purchases.cancel_stale(3600)
    assert Ash.get!(Purchase, checkout.id, authorize?: false).status == :pending
  end

  test "credits last exactly until their bundle's end, not hours more or less", %{user: user} do
    plan = plan_fixture(%{validity_unit: :day, validity_count: 1, features: %{"rides" => 3}})
    paid_at = DateTime.add(DateTime.utc_now(), -1, :day) |> DateTime.add(30, :minute)
    paid_purchase_fixture(user, plan, paid_at: paid_at)

    # 30 minutes of the day are left: the credits are still there...
    assert Access.remaining(UdinBilling.access(user.id), "rides") == 3

    # ...and gone one hour later.
    later = DateTime.add(DateTime.utc_now(), 1, :hour)
    assert Access.remaining(UdinBilling.access(user.id, now: later), "rides") == 0
  end

  test "times read back are the same moments that were written", %{user: user} do
    paid_at = ~U[2026-10-12 09:00:00.000000Z]
    purchase = paid_purchase_fixture(user, plan_fixture(), paid_at: paid_at)

    stored = Ash.get!(Purchase, purchase.id, authorize?: false)
    assert DateTime.compare(stored.paid_at, paid_at) == :eq
  end
end

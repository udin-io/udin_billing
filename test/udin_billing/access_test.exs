defmodule UdinBilling.AccessTest do
  use UdinBilling.DataCase, async: false

  alias UdinBilling.Access

  @t0 ~U[2026-11-01 10:00:00.000000Z]

  setup do
    user = user_fixture()
    {:ok, _} = UdinBilling.ensure_account(user.id, @t0)
    %{user: user}
  end

  test "the free plan alone: its counter, every switch off", %{user: user} do
    free_plan_fixture()
    access = Access.load(user.id, now: DateTime.add(@t0, 60))

    assert Access.remaining(access, "reel_imports") == 3
    assert Access.remaining(access, "rides") == 0
    refute Access.enabled?(access, "share_recipe")
    refute Access.enabled?(access, "meal_plan")
    refute Access.enabled?(access, "not_in_catalog")
    assert Access.can_spend?(access, "reel_imports", 3)
    refute Access.can_spend?(access, "reel_imports", 4)
  end

  test "switches from any active plan count; counters add up", %{user: user} do
    free_plan_fixture()
    plan = plan_fixture(%{features: %{"reel_imports" => 5, "smart_aggregation" => true}})
    paid_purchase_fixture(user, plan, paid_at: @t0)

    access = Access.load(user.id, now: DateTime.add(@t0, 60))
    assert Access.enabled?(access, "smart_aggregation")
    assert Access.remaining(access, "reel_imports") == 8
    assert %{limit: 8} = access.counters["reel_imports"]
    assert length(access.sources) == 2
  end

  test "enabled?/2 checks one switch without counters", %{user: user} do
    plan = plan_fixture(%{features: %{"share_recipe" => true}})
    refute UdinBilling.enabled?(user.id, "share_recipe")
    paid_purchase_fixture(user, plan)
    assert UdinBilling.enabled?(user.id, "share_recipe")
  end

  test "access ends by date, with no job", %{user: user} do
    plan = plan_fixture(%{features: %{"share_recipe" => true}})
    purchase = paid_purchase_fixture(user, plan, paid_at: @t0)

    assert Access.enabled?(
             Access.load(user.id, now: DateTime.add(purchase.access_expires_at, -1)),
             "share_recipe"
           )

    refute Access.enabled?(Access.load(user.id, now: purchase.access_expires_at), "share_recipe")
  end

  test "a user with no plans gets an empty access", %{user: user} do
    access = Access.load(user.id)
    assert access.sources == []
    assert Access.remaining(access, "reel_imports") == 0
  end
end

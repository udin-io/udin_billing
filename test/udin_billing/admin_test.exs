defmodule UdinBilling.AdminTest do
  use UdinBilling.DataCase, async: false

  alias UdinBilling.Admin

  setup do
    %{admin: user_fixture(%{admin: true}), rider: user_fixture()}
  end

  test "every function refuses non-admins", %{rider: rider} do
    plan = plan_fixture()

    for result <- [
          Admin.list_features(rider),
          Admin.create_feature(%{key: "x", kind: :switch}, rider),
          Admin.list_plans(rider),
          Admin.get_plan(plan.id, rider),
          Admin.create_plan(%{}, rider),
          Admin.update_plan(plan, %{}, rider),
          Admin.deactivate_plan(plan, rider),
          Admin.grant_plan(rider.id, plan.id, "x", rider),
          Admin.user_overview(rider.id, rider),
          Admin.list_purchases(rider),
          Admin.list_subscriptions(rider),
          Admin.list_usages(rider),
          Admin.revenue(rider, ~U[2026-01-01 00:00:00Z], ~U[2027-01-01 00:00:00Z]),
          Admin.sales_by_plan(rider, ~U[2026-01-01 00:00:00Z], ~U[2027-01-01 00:00:00Z])
        ] do
      assert result == {:error, :forbidden}
    end

    assert {:error, :forbidden} = Admin.list_plans(nil)
  end

  test "manage the catalog and plans with feature values", %{admin: admin} do
    assert {:ok, household} =
             Admin.create_feature(
               %{
                 key: "household",
                 kind: :switch,
                 name: %{"en" => "Household", "ar" => "العائلة"}
               },
               admin
             )

    assert {:ok, plan} =
             Admin.create_plan(
               %{
                 code: "plus",
                 name: %{"en" => "Plus", "ar" => "بلس"},
                 kind: :one_time,
                 price: "360",
                 features: %{"reel_imports" => 40, "household" => true}
               },
               admin
             )

    {:ok, catalog} = Admin.list_features(admin)
    row = Admin.plan_row(plan, catalog)
    assert row.features["reel_imports"] == 40
    assert row.features["household"] == true
    assert row.features["share_recipe"] == false
    assert row.features["rides"] == 0

    assert {:error, _} = Admin.delete_feature(household, admin)
    assert {:ok, %{status: :inactive}} = Admin.deactivate_plan(plan, admin)
  end

  test "gift a plan, then see it on the user's panel", %{admin: admin, rider: rider} do
    plan = plan_fixture(%{features: %{"rides" => 10, "share_recipe" => true}})
    assert {:ok, gift} = Admin.grant_plan(rider.id, plan.id, "late bus", admin)
    assert gift.provider == "admin" and Decimal.equal?(gift.amount, 0)
    assert gift.metadata["granted_by"] == admin.id

    {:ok, overview} = Admin.user_overview(rider.id, admin)
    assert %{remaining: 10} = overview.counters["rides"]
    assert overview.switches == ["share_recipe"]
    assert [%{kind: :purchase}] = overview.sources
  end

  test "lists filter and page; unknown filters raise", %{admin: admin, rider: rider} do
    plan = plan_fixture()
    for _ <- 1..3, do: paid_purchase_fixture(rider, plan)
    paid_purchase_fixture(user_fixture(), plan)

    assert {:ok, mine} = Admin.list_purchases(admin, user_id: rider.id, status: :paid)
    assert length(mine) == 3

    assert {:ok, %Ash.Page.Offset{count: 4, results: [_, _]}} =
             Admin.list_purchases(admin, [], page: [limit: 2, count: true])

    assert_raise ArgumentError, fn -> Admin.list_purchases(admin, colour: :blue) end
  end

  test "revenue nets refunds and late payments; sales count per plan", %{
    admin: admin,
    rider: rider
  } do
    plan = plan_fixture(%{price: Decimal.new("100")})
    paid_purchase_fixture(rider, plan)
    refunded = paid_purchase_fixture(rider, plan)
    {:ok, _} = UdinBilling.refund(refunded.id, "chargeback")
    {:ok, late} = UdinBilling.start_purchase(rider.id, plan.id, "fake")
    {:ok, _} = UdinBilling.Purchases.cancel(late.id)
    {:ok, _} = UdinBilling.confirm_payment(late.id, %{amount: "100", currency: "EGP"})

    from = DateTime.add(DateTime.utc_now(), -3600)
    to = DateTime.add(DateTime.utc_now(), 3600)

    assert {:ok, [row]} = Admin.revenue(admin, from, to)

    assert Decimal.equal?(row.gross, 300) and Decimal.equal?(row.refunded, 100) and
             Decimal.equal?(row.awaiting_refund, 100)

    assert Decimal.equal?(row.net, 100)
    assert {:ok, [%{purchases: 2}]} = Admin.sales_by_plan(admin, from, to)
  end
end

defmodule UdinBilling.PlanVersionsTest do
  @moduledoc """
  A sold plan keeps its terms: to change price or contents, create a new version and take
  the old one off sale (buyers keep it until their paid period ends).
  """
  use UdinBilling.DataCase, async: false

  alias UdinBilling.Admin

  defp admin, do: %{admin: true}

  defp sold_plan do
    plan = plan_fixture(%{code: "weekly", features: %{"rides" => 10}})
    paid_purchase_fixture(user_fixture(), plan)
    plan
  end

  defp update(plan, attrs), do: Admin.update_plan(plan, attrs, admin())

  describe "a plan with buyers" do
    test "can't change price, type, periods or features" do
      plan = sold_plan()

      for attrs <- [
            %{price: Decimal.new("175")},
            %{currency: "USD"},
            %{validity_count: 2},
            %{cycle_unit: :day, cycle_count: 1},
            %{features: %{"rides" => 12}}
          ] do
        assert {:error, error} = update(plan, attrs), inspect(attrs)
        assert Exception.message(error) =~ "create a new version"
      end
    end

    test "can still change names, display order, the badge, and go off sale" do
      plan = sold_plan()

      assert {:ok, plan} =
               update(plan, %{
                 name: %{"en" => "Weekly bundle", "ar" => "باقة أسبوعية"},
                 sort_order: 5,
                 metadata: %{"recommended" => true},
                 # Same features and price as before: not a change.
                 features: %{"rides" => 10},
                 price: Decimal.new("150.00")
               })

      assert plan.name["en"] == "Weekly bundle"
      assert {:ok, %{status: :inactive}} = Admin.deactivate_plan(plan, admin())
    end

    test "can't drop or change its store product ids: subscribers' renewals use them" do
      plan = sold_plan()
      {:ok, plan} = update(plan, %{provider_product_ids: %{"fake" => ["weekly_v1"]}})
      paid_purchase_fixture(user_fixture(), plan)

      for ids <- [%{}, %{"fake" => []}, %{"fake" => ["weekly_v2"]}] do
        assert {:error, error} = update(plan, %{provider_product_ids: ids}), inspect(ids)
        assert Exception.message(error) =~ "create a new version"
      end
    end

    test "can add a product id, e.g. the same plan in another store" do
      plan = sold_plan()
      {:ok, plan} = update(plan, %{provider_product_ids: %{"fake" => ["weekly_v1"]}})
      paid_purchase_fixture(user_fixture(), plan)

      assert {:ok, plan} =
               update(plan, %{provider_product_ids: %{"fake" => ["weekly_v1", "weekly:base"]}})

      assert plan.provider_product_ids["fake"] == ["weekly_v1", "weekly:base"]
    end

    test "a new version takes the plan off sale; its subscribers keep renewing it" do
      plan = sold_plan()
      {:ok, plan} = update(plan, %{provider_product_ids: %{"fake" => ["weekly_v1"]}})

      assert {:ok, %{new: new, old: old}} =
               Admin.replace_plan(
                 plan,
                 %{
                   code: "weekly-v2",
                   name: plan.name,
                   kind: :one_time,
                   price: Decimal.new("175"),
                   currency: "EGP",
                   validity_unit: :week,
                   validity_count: 1,
                   features: %{"rides" => 10},
                   provider_product_ids: %{"fake" => ["weekly_v2"]}
                 },
                 admin()
               )

      assert old.status == :inactive and new.status == :active
      # Off sale, but still found by its product id: a store renewal still lands on it.
      assert UdinBilling.Plan.by_product_id("fake", "weekly_v1").id == old.id
      refute Enum.any?(UdinBilling.plans_for_sale(), &(&1.id == old.id))
    end

    test "a plan nobody bought can still change everything" do
      plan = plan_fixture(%{features: %{"rides" => 10}})
      assert {:ok, plan} = update(plan, %{price: Decimal.new("175"), features: %{"rides" => 12}})
      assert plan.features == %{"rides" => 12}
    end
  end

  describe "replace_plan/3" do
    test "creates the new version and takes the old one off sale, together" do
      old = sold_plan()
      buyer_purchase = Ash.read_one!(Purchase, authorize?: false)

      assert {:ok, %{new: new, old: old_after}} =
               Admin.replace_plan(
                 old,
                 %{
                   code: "weekly-v2",
                   name: old.name,
                   kind: :one_time,
                   price: Decimal.new("175"),
                   validity_unit: :week,
                   validity_count: 1,
                   features: %{"rides" => 12}
                 },
                 admin()
               )

      assert new.status == :active
      assert old_after.status == :inactive
      assert Enum.map(UdinBilling.plans_for_sale(), & &1.code) == ["weekly-v2"]

      # The old buyer keeps exactly what they paid for.
      purchase = Ash.get!(Purchase, buyer_purchase.id, authorize?: false)
      assert purchase.plan_id == old.id
      assert purchase.features == %{"rides" => 10}
    end

    test "if the new version is invalid, the old one stays on sale" do
      old = sold_plan()

      assert {:error, _} =
               Admin.replace_plan(
                 old,
                 %{code: "weekly-v2", name: old.name, kind: :one_time},
                 admin()
               )

      assert Ash.get!(Plan, old.id, authorize?: false).status == :active
    end

    test "requires an admin" do
      assert {:error, :forbidden} = Admin.replace_plan(sold_plan(), %{}, %{admin: false})
    end
  end

  describe "store product ids" do
    test "are unique across plans, so a renewal can't land on the wrong version" do
      subscription_plan_fixture(%{
        code: "basic",
        provider_product_ids: %{"fake" => "basic_monthly"}
      })

      assert {:error, error} =
               Ash.create(
                 Plan,
                 %{
                   code: "basic-v2",
                   name: %{"en" => "Basic", "ar" => "أساسي"},
                   kind: :recurring,
                   price: Decimal.new("200"),
                   validity_unit: :month,
                   validity_count: 1,
                   provider_product_ids: %{"fake" => ["basic_monthly_v2", "basic_monthly"]}
                 },
                 authorize?: false
               )

      assert Exception.message(error) =~ "already used by plan basic"
    end

    test "a plan may keep its own ids when edited" do
      plan =
        subscription_plan_fixture(%{
          code: "basic",
          provider_product_ids: %{"fake" => "basic_monthly"}
        })

      assert {:ok, _} =
               update(plan, %{
                 provider_product_ids: %{"fake" => ["basic_monthly", "basic:monthly"]}
               })
    end
  end
end

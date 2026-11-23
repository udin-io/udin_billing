defmodule UdinBilling.Web.PlanFormTest do
  use UdinBilling.DataCase, async: false

  alias UdinBilling.Web.PlanForm

  setup do
    {:ok, catalog} = UdinBilling.Admin.list_features(admin())
    %{catalog: catalog}
  end

  defp admin, do: %{admin: true}

  defp valid_params(catalog, overrides \\ %{}) do
    nil
    |> PlanForm.from_plan(catalog)
    |> PlanForm.merge(%{
      "code" => "plus-monthly",
      "name" => %{"en" => "Plus", "ar" => "بلس"},
      "kind" => "recurring",
      "price" => "350",
      "cycle_mode" => "period"
    })
    |> PlanForm.merge(overrides)
  end

  test "a new form has a field for every language, provider and feature", %{catalog: catalog} do
    params = PlanForm.from_plan(nil, catalog)

    assert params["name"] == %{"en" => "", "ar" => ""}
    assert params["description"] == %{"en" => "", "ar" => ""}
    assert Map.keys(params["product_ids"]) == PlanForm.providers()
    assert params["features"]["rides"] == %{"mode" => "off", "limit" => ""}
    assert params["features"]["share_recipe"] == %{"on" => "false"}
  end

  test "valid params become plan attributes", %{catalog: catalog} do
    params =
      valid_params(catalog, %{
        "description" => %{"en" => " Best value ", "ar" => "أفضل قيمة"},
        "product_ids" => %{"revenuecat" => "plus_monthly, plus:monthly-base", "fake" => " "},
        "features" => %{
          "reel_imports" => %{"mode" => "limited", "limit" => "40"},
          "rides" => %{"mode" => "unlimited"},
          "share_recipe" => %{"on" => "true"}
        }
      })

    assert {:ok, attrs} = PlanForm.to_attrs(params, catalog)
    assert attrs.name == %{"en" => "Plus", "ar" => "بلس"}
    assert attrs.description == %{"en" => "Best value", "ar" => "أفضل قيمة"}
    assert attrs.kind == :recurring
    assert Decimal.equal?(attrs.price, 350)
    assert {attrs.validity_unit, attrs.validity_count} == {:month, 1}
    assert {attrs.cycle_unit, attrs.cycle_count} == {:month, 1}

    assert attrs.features == %{
             "reel_imports" => 40,
             "rides" => "unlimited",
             "share_recipe" => true
           }

    assert attrs.provider_product_ids == %{"revenuecat" => ["plus_monthly", "plus:monthly-base"]}
  end

  test "a missing language is reported on its own field", %{catalog: catalog} do
    params = valid_params(catalog, %{"name" => %{"ar" => ""}, "description" => %{"ar" => "وصف"}})

    assert {:error, errors} = PlanForm.to_attrs(params, catalog)
    assert Map.has_key?(errors, "name.ar")
    refute Map.has_key?(errors, "name.en")
    assert Map.has_key?(errors, "description.en")
  end

  test "bad numbers and periods are reported per field", %{catalog: catalog} do
    params =
      valid_params(catalog, %{
        "price" => "-5",
        "validity_count" => "0",
        "features" => %{"rides" => %{"mode" => "limited", "limit" => "abc"}}
      })

    assert {:error, errors} = PlanForm.to_attrs(params, catalog)
    assert Map.keys(errors) |> Enum.sort() == ["features.rides", "price", "validity"]
  end

  test "\"never ends\" and \"no reset\" clear the periods", %{catalog: catalog} do
    params = valid_params(catalog, %{"validity_mode" => "forever", "cycle_mode" => "none"})

    assert {:ok, attrs} = PlanForm.to_attrs(params, catalog)
    assert {attrs.validity_unit, attrs.validity_count} == {nil, nil}
    assert {attrs.cycle_unit, attrs.cycle_count} == {nil, nil}
  end

  test "an unknown kind or unit never becomes an atom", %{catalog: catalog} do
    params = valid_params(catalog, %{"kind" => "lifetime_vip", "validity_unit" => "fortnight"})

    assert {:error, errors} = PlanForm.to_attrs(params, catalog)
    assert Map.has_key?(errors, "kind")
    assert Map.has_key?(errors, "validity")
  end

  test "a saved plan round-trips through the form", %{catalog: catalog} do
    {:ok, attrs} = PlanForm.to_attrs(valid_params(catalog), catalog)
    {:ok, plan} = UdinBilling.Admin.create_plan(attrs, admin())

    assert {:ok, again} = PlanForm.to_attrs(PlanForm.from_plan(plan, catalog), catalog)
    assert again.name == attrs.name
    assert again.features == attrs.features
    assert {again.cycle_unit, again.validity_unit} == {:month, :month}
  end

  test "included lists what a buyer gets, named in the requested language", %{catalog: catalog} do
    {:ok, rides} = UdinBilling.Admin.list_features(admin())
    rides = Enum.find(rides, &(&1.key == "rides"))

    {:ok, _} =
      UdinBilling.Admin.update_feature(
        rides,
        %{name: %{"en" => "Rides", "ar" => "رحلات"}},
        admin()
      )

    {:ok, catalog_now} = UdinBilling.Admin.list_features(admin())

    params =
      valid_params(catalog, %{
        "features" => %{
          "rides" => %{"mode" => "limited", "limit" => "40"},
          "reel_imports" => %{"mode" => "unlimited"},
          "share_recipe" => %{"on" => "true"}
        }
      })

    {:ok, attrs} = PlanForm.to_attrs(params, catalog_now)

    assert [
             %{key: "reel_imports", value: "unlimited"},
             %{key: "rides", name: "رحلات", value: 40},
             %{key: "share_recipe", value: true}
           ] = PlanForm.included(attrs, catalog_now, "ar")

    assert %{name: "Rides"} =
             Enum.find(PlanForm.included(attrs, catalog_now, "en"), &(&1.key == "rides"))
  end

  test "a free plan costs 0 whatever the price field says, and only free plans are default",
       %{catalog: catalog} do
    assert {:ok, %{price: price, is_default: true}} =
             PlanForm.to_attrs(
               valid_params(catalog, %{"kind" => "free", "price" => "", "is_default" => "true"}),
               catalog
             )

    assert Decimal.equal?(price, 0)

    assert {:ok, %{is_default: false}} =
             PlanForm.to_attrs(valid_params(catalog, %{"is_default" => "true"}), catalog)
  end

  test "parse keeps the valid attributes while reporting errors (for the live preview)",
       %{catalog: catalog} do
    {attrs, errors} = PlanForm.parse(valid_params(catalog, %{"price" => "abc"}), catalog)

    assert attrs.name == %{"en" => "Plus", "ar" => "بلس"}
    assert Map.has_key?(errors, "price")
  end

  test "a copy gets a new code and is never the default plan", %{catalog: catalog} do
    plan = plan_fixture(%{code: "weekly"})
    params = PlanForm.copy_of(plan, catalog)

    assert params["code"] == "weekly-copy"
    assert params["is_default"] == "false"
    assert params["name"] == plan.name
  end

  test "after_subscription is a free-plan choice; paid plans and unknown values continue",
       %{catalog: catalog} do
    free = %{"kind" => "free", "is_default" => "true"}

    assert {:ok, %{after_subscription: :fresh_start}} =
             PlanForm.to_attrs(
               valid_params(catalog, Map.put(free, "after_subscription", "fresh_start")),
               catalog
             )

    assert {:ok, %{after_subscription: :continue}} =
             PlanForm.to_attrs(
               valid_params(catalog, Map.put(free, "after_subscription", "forever")),
               catalog
             )

    assert {:ok, %{after_subscription: :continue}} =
             PlanForm.to_attrs(
               valid_params(catalog, %{"after_subscription" => "fresh_start"}),
               catalog
             )
  end

  test "a new version: next code, on sale, not default, no store product ids", %{catalog: catalog} do
    plan = plan_fixture(%{code: "weekly", provider_product_ids: %{"fake" => "weekly_1"}})
    params = PlanForm.new_version_of(plan, catalog)

    assert params["code"] == "weekly-v2"
    assert params["status"] == "active"
    assert params["is_default"] == "false"
    assert Enum.all?(params["product_ids"], fn {_provider, ids} -> ids == "" end)
    assert PlanForm.next_version_code("weekly-v2") == "weekly-v3"
    assert PlanForm.next_version_code("weekly-v10") == "weekly-v11"
  end

  test "the form's own texts follow the process language", %{catalog: catalog} do
    {_attrs, errors} = PlanForm.parse(valid_params(catalog, %{"price" => "abc"}), catalog)
    assert errors["price"] =~ "number"

    Gettext.with_locale(UdinBilling.Gettext, "ar", fn ->
      {_attrs, errors} = PlanForm.parse(valid_params(catalog, %{"price" => "abc"}), catalog)
      assert errors["price"] =~ ~r/[\x{0600}-\x{06FF}]/u
      assert {"يوم أو أيام", "day"} in PlanForm.unit_options()
      assert {"باقة مجانية", "free"} in PlanForm.kind_options()
    end)

    assert {"day(s)", "day"} in PlanForm.unit_options()
  end
end

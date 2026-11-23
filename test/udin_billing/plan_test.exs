defmodule UdinBilling.PlanTest do
  use UdinBilling.DataCase, async: false

  require Ash.Query

  describe "feature catalog" do
    test "keys must be lowercase snake case and unique; kind is fixed" do
      assert {:error, _} =
               Ash.create(Feature, %{key: "Share-Recipe", kind: :switch}, authorize?: false)

      assert {:error, _} = Ash.create(Feature, %{key: "rides", kind: :counter}, authorize?: false)

      assert {:ok, feature} =
               Ash.create(Feature, %{key: "household", kind: :switch, name: names("Household")},
                 authorize?: false
               )

      assert {:error, _} =
               feature
               |> Ash.Changeset.for_update(:update, %{kind: :counter})
               |> Ash.update(authorize?: false)
    end

    test "a feature used by a plan can't be deleted; an unused one can" do
      plan_fixture()
      [rides] = Ash.read!(Feature |> Ash.Query.filter(key == "rides"), authorize?: false)
      assert {:error, error} = Ash.destroy(rides, authorize?: false)
      assert Exception.message(error) =~ "plan still uses"

      {:ok, unused} =
        Ash.create(Feature, %{key: "household", kind: :switch, name: names("Household")},
          authorize?: false
        )

      assert :ok = Ash.destroy(unused, authorize?: false)
    end
  end

  defp names(text), do: %{"en" => text, "ar" => text}

  describe "feature values" do
    test "are stored on the plan and as normalized rows" do
      plan =
        plan_fixture(%{
          features: %{"rides" => 10, "share_recipe" => true, "reel_imports" => :unlimited}
        })

      assert plan.features == %{
               "rides" => 10,
               "share_recipe" => true,
               "reel_imports" => "unlimited"
             }

      rows =
        PlanFeature
        |> Ash.Query.filter(plan_id == ^plan.id)
        |> Ash.Query.load(:feature)
        |> Ash.read!(authorize?: false)

      by_key = Map.new(rows, &{&1.feature.key, &1})
      assert %{limit: 10, unlimited: false} = by_key["rides"]
      assert %{enabled: true} = by_key["share_recipe"]
      assert %{unlimited: true} = by_key["reel_imports"]
    end

    test "unknown features and wrong value types are refused" do
      assert {:error, error} =
               Ash.create(Plan, attrs(%{features: %{"ridez" => 1}}), authorize?: false)

      assert Exception.message(error) =~ "unknown feature"

      assert {:error, _} =
               Ash.create(Plan, attrs(%{features: %{"rides" => true}}), authorize?: false)

      assert {:error, _} =
               Ash.create(Plan, attrs(%{features: %{"share_recipe" => 3}}), authorize?: false)

      assert {:error, _} =
               Ash.create(Plan, attrs(%{features: %{"rides" => -1}}), authorize?: false)
    end

    test "update replaces all values when given and keeps them when omitted" do
      plan = plan_fixture(%{features: %{"rides" => 10, "share_recipe" => true}})

      kept =
        plan
        |> Ash.Changeset.for_update(:update, %{sort_order: 3})
        |> Ash.update!(authorize?: false)

      assert kept.features == plan.features

      replaced =
        plan
        |> Ash.Changeset.for_update(:update, %{features: %{"rides" => 5}})
        |> Ash.update!(authorize?: false)

      assert replaced.features == %{"rides" => 5}

      assert [_one] =
               PlanFeature
               |> Ash.Query.filter(plan_id == ^plan.id)
               |> Ash.read!(authorize?: false)
    end
  end

  describe "rules" do
    test "plan kinds must be enabled; a plan of a disabled kind can still be deactivated" do
      plan = plan_fixture()

      with_env(:modes, [:free, :recurring], fn ->
        assert {:error, _} = Ash.create(Plan, attrs(%{}), authorize?: false)

        assert {:ok, %{status: :inactive}} =
                 plan |> Ash.Changeset.for_update(:deactivate) |> Ash.update(authorize?: false)
      end)
    end

    test "prices, periods and the single default" do
      assert {:error, _} =
               Ash.create(Plan, attrs(%{kind: :free, price: Decimal.new(5)}), authorize?: false)

      assert {:error, _} = Ash.create(Plan, attrs(%{price: Decimal.new(0)}), authorize?: false)

      assert {:error, _} =
               Ash.create(
                 Plan,
                 attrs(%{kind: :recurring, validity_unit: nil, validity_count: nil}),
                 authorize?: false
               )

      assert {:error, _} = Ash.create(Plan, attrs(%{cycle_unit: :month}), authorize?: false)
      assert {:error, _} = Ash.create(Plan, attrs(%{currency: "egp"}), authorize?: false)
      assert {:error, _} = Ash.create(Plan, attrs(%{is_default: true}), authorize?: false)

      free_plan_fixture()

      assert {:error, _} =
               Ash.create(Plan, attrs(%{code: "free-2", kind: :free, price: 0, is_default: true}),
                 authorize?: false
               )
    end

    test "a subscription plan with no refill refills once per billing period" do
      recurring = %{kind: :recurring, cycle_unit: nil, cycle_count: nil}

      assert {:ok, %{cycle_unit: :month, cycle_count: 1}} =
               Ash.create(
                 Plan,
                 attrs(Map.merge(recurring, %{validity_unit: :month, validity_count: 1})),
                 authorize?: false
               )

      assert {:ok, %{cycle_unit: :year, cycle_count: 1}} =
               Ash.create(
                 Plan,
                 attrs(Map.merge(recurring, %{validity_unit: :year, validity_count: 1})),
                 authorize?: false
               )
    end

    test "a one-time plan with no refill keeps none" do
      assert {:ok, %{cycle_unit: nil}} =
               Ash.create(Plan, attrs(%{validity_unit: :month, validity_count: 1}),
                 authorize?: false
               )
    end

    test "a subscription plan can't refill less often than it's paid" do
      monthly = %{kind: :recurring, validity_unit: :month, validity_count: 1}

      assert {:error, _} =
               Ash.create(Plan, attrs(Map.merge(monthly, %{cycle_unit: :year, cycle_count: 1})),
                 authorize?: false
               )

      assert {:error, _} =
               Ash.create(Plan, attrs(Map.merge(monthly, %{cycle_unit: :week, cycle_count: 5})),
                 authorize?: false
               )

      assert {:ok, _} =
               Ash.create(Plan, attrs(Map.merge(monthly, %{cycle_unit: :week, cycle_count: 1})),
                 authorize?: false
               )
    end

    test "only admins write plans; anyone reads the catalog" do
      admin = user_fixture(%{admin: true})
      rider = user_fixture()

      assert {:ok, _} = Ash.create(Plan, attrs(%{}), actor: admin)
      assert {:error, %Ash.Error.Forbidden{}} = Ash.create(Plan, attrs(%{}), actor: rider)
      assert [_] = Ash.read!(Plan, action: :purchasable, actor: rider)
    end
  end

  describe "sold_ids/1" do
    test "names each plan that was bought, once, however many sales it had" do
      user = user_fixture()
      sold = plan_fixture(%{code: "sold"})
      subscribed = subscription_plan_fixture(%{code: "subscribed"})
      unsold = plan_fixture(%{code: "unsold"})

      for _ <- 1..3, do: paid_purchase_fixture(user, sold)

      {:ok, _} =
        UdinBilling.Subscriptions.apply_state(
          "fake",
          user.id,
          sub_state(%{product_id: "basic_monthly"}),
          now: ~U[2026-10-10 09:01:00.000000Z]
        )

      ids = Plan.sold_ids([sold.id, subscribed.id, unsold.id])

      assert MapSet.equal?(ids, MapSet.new([sold.id, subscribed.id]))
      assert Plan.sold?(sold.id)
      refute Plan.sold?(unsold.id)
      assert Plan.sold_ids([]) == MapSet.new()
    end
  end

  describe "helpers" do
    test "expires_at shifts by calendar month and period_label names the validity" do
      plan = plan_fixture(%{validity_unit: :month})

      assert UdinBilling.Plan.expires_at(plan, ~U[2026-01-31 10:00:00Z]) ==
               ~U[2026-02-28 10:00:00Z]

      assert UdinBilling.Plan.period_label(plan) == :monthly

      assert UdinBilling.Plan.period_label(
               plan_fixture(%{validity_unit: :day, validity_count: 3})
             ) == :custom

      assert UdinBilling.Plan.period_label(
               plan_fixture(%{validity_unit: nil, validity_count: nil})
             ) == :unlimited
    end

    test "localized falls back to English" do
      plan = plan_fixture()
      assert UdinBilling.Plan.localized(plan, :name, "ar") == "أسبوعي"
      assert UdinBilling.Plan.localized(plan, :name, "fr") == "Weekly"
    end
  end

  defp attrs(overrides) do
    Map.merge(
      %{
        code: "plan-#{System.unique_integer([:positive])}",
        name: %{"en" => "Plan", "ar" => "باقة"},
        kind: :one_time,
        price: Decimal.new(10),
        features: %{"rides" => 1}
      },
      overrides
    )
  end

  test "plans_for_sale/0: active paid plans in display order, never the free plan" do
    free_plan_fixture()
    second = plan_fixture(%{code: "monthly", sort_order: 2})
    first = plan_fixture(%{code: "weekly", sort_order: 1})
    plan_fixture(%{code: "old", status: :inactive})

    assert Enum.map(UdinBilling.plans_for_sale(), & &1.id) == [first.id, second.id]
  end
end

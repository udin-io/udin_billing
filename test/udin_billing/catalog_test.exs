defmodule UdinBilling.CatalogTest do
  use UdinBilling.DataCase, async: false

  alias UdinBilling.Catalog

  require Ash.Query

  defp plan_by_code(code),
    do: Plan |> Ash.Query.filter(code == ^code) |> Ash.read_one!(authorize?: false)

  defp feature_by_key(key),
    do: Feature |> Ash.Query.filter(key == ^key) |> Ash.read_one!(authorize?: false)

  # Exports this database, empties it, and returns the exported text: "another environment".
  # Plans have no destroy action (buyers reference them), so the test clears the tables.
  defp export_and_reset do
    json = Catalog.encode(Catalog.export())

    for table <- ~w(billing_plan_features billing_plans billing_features),
        do: UdinBilling.TestRepo.delete_all(table)

    json
  end

  defp import!(json, opts \\ []) do
    {:ok, catalog} = Catalog.decode(json)
    Catalog.apply_catalog(catalog, opts)
  end

  describe "export then import into an empty environment" do
    test "recreates every feature and plan exactly" do
      plan_fixture(%{code: "weekly", features: %{"rides" => 10, "share_recipe" => true}})
      free_plan_fixture(%{after_subscription: :fresh_start})
      before = Catalog.export()

      json = export_and_reset()
      assert Ash.read!(Plan, authorize?: false) == []

      assert {:ok, %{changes: changes}} = import!(json)
      assert Enum.all?(changes, &(&1.action == :create))
      assert Catalog.export() == before

      weekly = plan_by_code("weekly")
      assert weekly.features == %{"rides" => 10, "share_recipe" => true}
      assert plan_by_code("free").after_subscription == :fresh_start
    end

    test "the file is stable: the same setup always exports the same text" do
      plan_fixture(%{code: "weekly"})
      plan_fixture(%{code: "monthly", sort_order: 2})

      assert Catalog.encode(Catalog.export()) == Catalog.encode(Catalog.export())
      assert Catalog.encode(Catalog.export()) =~ ~s("format": "udin_billing.catalog")
    end
  end

  describe "changes/1 (dry run)" do
    test "an identical database has nothing to change" do
      plan_fixture(%{code: "weekly"})
      {:ok, catalog} = Catalog.decode(Catalog.encode(Catalog.export()))

      assert %{errors: [], changes: changes} = Catalog.changes(catalog)
      assert Enum.all?(changes, &(&1.action == :unchanged))
      assert Catalog.describe(Catalog.changes(catalog)) == []
    end

    test "lists exactly the fields that differ, and writes nothing" do
      plan_fixture(%{code: "weekly", features: %{"rides" => 10}})

      json =
        Catalog.export()
        |> update_in(["plans"], fn [plan] ->
          [%{plan | "price" => "175", "features" => %{"rides" => 12}}]
        end)
        |> Catalog.encode()

      {:ok, catalog} = Catalog.decode(json)
      changes = Catalog.changes(catalog)

      assert %{action: :update, fields: [:price, :features]} =
               Enum.find(changes.changes, &(&1.key == "weekly"))

      assert "plan weekly: update price, features" in Catalog.describe(changes)
      assert Decimal.equal?(plan_by_code("weekly").price, 150)
    end

    test "reports what's only in the database without touching it" do
      plan_fixture(%{code: "weekly"})
      json = Catalog.encode(Catalog.export())
      plan_fixture(%{code: "old-promo"})

      {:ok, catalog} = Catalog.decode(json)
      assert %{not_in_file: %{plans: ["old-promo"]}} = Catalog.changes(catalog)
    end
  end

  describe "apply_catalog/2" do
    test "updates existing plans and features in place (same ids, buyers unaffected)" do
      plan = plan_fixture(%{code: "weekly", features: %{"rides" => 10}})

      json =
        Catalog.export()
        |> update_in(["plans"], fn [p] ->
          [%{p | "price" => "175", "features" => %{"rides" => 12}}]
        end)
        |> update_in(["features"], fn features ->
          Enum.map(features, fn
            %{"key" => "rides"} = f -> %{f | "name" => %{"en" => "Ride credits", "ar" => "رصيد"}}
            f -> f
          end)
        end)
        |> Catalog.encode()

      assert {:ok, _} = import!(json)

      updated = plan_by_code("weekly")
      assert updated.id == plan.id
      assert Decimal.equal?(updated.price, 175)
      assert updated.features == %{"rides" => 12}
      assert feature_by_key("rides").name["en"] == "Ride credits"
    end

    test "is all or nothing: one bad plan writes nothing" do
      json =
        Catalog.encode(%{
          "format" => "udin_billing.catalog",
          "version" => 1,
          "features" => [
            %{
              "key" => "household",
              "kind" => "switch",
              "name" => %{"en" => "Household", "ar" => "العائلة"}
            }
          ],
          "plans" => [
            %{
              "code" => "bad",
              "name" => %{"en" => "Bad", "ar" => "سيء"},
              "kind" => "one_time",
              "price" => "-5",
              "currency" => "EGP",
              "validity_unit" => "week",
              "validity_count" => 1
            }
          ]
        })

      assert {:error, _} = import!(json)
      refute feature_by_key("household")
      refute plan_by_code("bad")
    end

    test "a feature's kind can't change" do
      json =
        Catalog.export()
        |> update_in(["features"], fn features ->
          Enum.map(features, fn
            %{"key" => "rides"} = f -> %{f | "kind" => "switch"}
            f -> f
          end)
        end)
        |> Catalog.encode()

      assert {:error, [message]} = import!(json)
      assert message =~ "rides"
      assert feature_by_key("rides").kind == :counter
    end

    test "moving the default to another plan works in one import" do
      free_plan_fixture(%{code: "free-old"})

      json =
        Catalog.export()
        |> update_in(["plans"], fn [old] ->
          [
            %{old | "is_default" => false, "status" => "inactive"},
            %{old | "code" => "free-new", "is_default" => true}
          ]
        end)
        |> Catalog.encode()

      assert {:ok, _} = import!(json)
      assert plan_by_code("free-new").is_default
      refute plan_by_code("free-old").is_default
    end

    test "deactivate_missing takes plans that aren't in the file off sale" do
      plan_fixture(%{code: "weekly"})
      json = Catalog.encode(Catalog.export())
      plan_fixture(%{code: "old-promo"})

      assert {:ok, _} = import!(json)
      assert plan_by_code("old-promo").status == :active

      assert {:ok, _} = import!(json, deactivate_missing: true)
      assert plan_by_code("old-promo").status == :inactive
      assert plan_by_code("weekly").status == :active
    end
  end

  describe "required features" do
    test "an import that would leave a required feature missing is refused" do
      json = export_and_reset()

      without_rides =
        json
        |> Jason.decode!()
        |> update_in(["features"], &Enum.reject(&1, fn f -> f["key"] == "rides" end))
        |> Catalog.encode()

      with_env(:required_features, ["rides"], fn ->
        assert {:error, [message]} = import!(without_rides)
        assert message =~ "rides"
        assert Ash.read!(Feature, authorize?: false) == []

        assert {:ok, _} = import!(json)
        assert Catalog.missing_required() == []
      end)
    end

    test "missing_required/0 lists required features absent from the database" do
      with_env(:required_features, ["rides", "teleport"], fn ->
        assert Catalog.missing_required() == ["teleport"]
      end)
    end

    test "can't be deleted" do
      with_env(:required_features, ["meal_plan"], fn ->
        assert {:error, error} = Ash.destroy(feature_by_key("meal_plan"), authorize?: false)
        assert Exception.message(error) =~ "code uses this feature"
      end)
    end
  end

  describe "decode/1 refuses anything unsafe or malformed, saying where" do
    test "not JSON, or not a catalog" do
      assert {:error, [message]} = Catalog.decode("{nope")
      assert message =~ "JSON"
      assert {:error, [message]} = Catalog.decode(~s({"plans": []}))
      assert message =~ "format"

      assert {:error, [message]} =
               Catalog.decode(~s({"format": "udin_billing.catalog", "version": 9}))

      assert message =~ "version"
    end

    test "unknown values never become atoms; each problem names its item" do
      json =
        Jason.encode!(%{
          "format" => "udin_billing.catalog",
          "version" => 1,
          "features" => [%{"key" => "x", "kind" => "dial", "name" => %{"en" => "X"}}],
          "plans" => [
            %{
              "code" => "weekly",
              "name" => %{"en" => "W"},
              "kind" => "lifetime_vip",
              "price" => "abc",
              "currency" => "EGP",
              "validity_unit" => "fortnight",
              "validity_count" => 1
            }
          ]
        })

      assert {:error, errors} = Catalog.decode(json)
      assert "features[x].kind: missing or not allowed" in errors
      assert "plans[weekly].kind: missing or not allowed" in errors
      assert Enum.any?(errors, &(&1 =~ "plans[weekly].price"))
      assert "plans[weekly].validity_unit: missing or not allowed" in errors
    end

    test "duplicate keys and codes" do
      json =
        Jason.encode!(%{
          "format" => "udin_billing.catalog",
          "version" => 1,
          "features" => [
            %{"key" => "rides", "kind" => "counter", "name" => %{"en" => "R"}},
            %{"key" => "rides", "kind" => "counter", "name" => %{"en" => "R"}}
          ],
          "plans" => []
        })

      assert {:error, [message]} = Catalog.decode(json)
      assert message =~ "appears more than once"
    end
  end

  describe "files" do
    @tag :tmp_dir
    test "export_file/1 and import_file/2 (with dry run)", %{tmp_dir: dir} do
      plan_fixture(%{code: "weekly"})
      path = Path.join([dir, "billing", "catalog.json"])

      assert :ok = Catalog.export_file(path)
      assert {:ok, %{errors: []}} = Catalog.import_file(path, dry_run: true)
      assert {:ok, _} = Catalog.import_file(path)
      assert {:error, [message]} = Catalog.import_file(Path.join(dir, "missing.json"))
      assert message =~ "can't read"
    end
  end

  describe "features-only files (bundles managed by admins)" do
    test "export(only: :features) leaves plans out of the file" do
      plan_fixture(%{code: "weekly"})
      catalog = Catalog.export(only: :features)

      refute Map.has_key?(catalog, "plans")
      assert Enum.any?(catalog["features"], &(&1["key"] == "rides"))
    end

    test "importing one never touches or reports plans, even with deactivate_missing" do
      plan_fixture(%{code: "weekly"})
      json = Catalog.encode(Catalog.export(only: :features))

      {:ok, catalog} = Catalog.decode(json)
      assert %{not_in_file: %{plans: []}} = Catalog.changes(catalog)

      assert {:ok, _} = import!(json, deactivate_missing: true)
      assert plan_by_code("weekly").status == :active
    end
  end
end

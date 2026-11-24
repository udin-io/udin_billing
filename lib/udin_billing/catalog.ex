defmodule UdinBilling.Catalog do
  @moduledoc """
  Moves the billing setup (features and plans) between environments as one file.

  ## Why
  Features and plans are database rows, set up in the dashboard. Doing it again by hand
  on staging and again on production is slow and error-prone, and a missing or renamed
  feature breaks the code that uses it. Instead: set it up once (locally or on staging),
  export it to `priv/billing/catalog.json`, commit the file, and import it on the next
  environment. The file is reviewed like code and the same everywhere.

  ## How it works
    * Features are matched by `key` and plans by `code`, never by database id, so the
      file works in any environment.
    * `changes/1` compares a file with the database and lists what an import would
      create or update (a dry run). `apply_catalog/2` makes exactly those changes in one
      transaction: all or nothing.
    * An import never deletes anything. Plans in the database but not in the file are
      reported; `deactivate_missing: true` takes them off sale (buyers keep them).
    * A **features-only** file (no `plans` key; `export(only: :features)`) is for apps
      where admins manage plans in each environment: importing it never touches or
      reports plans.
    * A feature's kind (switch / counter) can't change, as in the dashboard.
    * Features the app's code needs (`config :udin_billing, required_features: [...]`)
      must exist after an import, or nothing is applied.

  ## Commands
      mix udin_billing.catalog.export                 # writes priv/billing/catalog.json
      mix udin_billing.catalog.import --dry-run       # shows what would change
      mix udin_billing.catalog.import                 # applies it

  In a release (no Mix): `UdinBilling.Catalog.import_file(path, dry_run: true)`.
  """
  alias UdinBilling.{Config, Feature, Plan, PlanFeature, Transaction}
  alias UdinBilling.Catalog.Decoder

  require Ash.Query

  @plan_fields [
    :name,
    :description,
    :kind,
    :price,
    :original_price,
    :currency,
    :validity_unit,
    :validity_count,
    :cycle_unit,
    :cycle_count,
    :provider_product_ids,
    :status,
    :is_default,
    :sort_order,
    :metadata,
    :after_subscription
  ]
  @feature_fields [:name, :description, :sort_order]

  @type change :: %{
          type: :feature | :plan,
          key: String.t(),
          action: :create | :update | :unchanged,
          fields: [atom()]
        }
  @type changes :: %{
          changes: [change()],
          not_in_file: %{features: [String.t()], plans: [String.t()]},
          errors: [String.t()]
        }

  @doc "The default file path in the app: `priv/billing/catalog.json`."
  @spec default_path() :: String.t()
  def default_path, do: Path.join(["priv", "billing", "catalog.json"])

  @doc """
  The current features and plans as a catalog map (string keys, ready for JSON), sorted
  so exports of the same setup are identical and diffs stay small. `only: :features`
  leaves plans out (a features-only file).
  """
  @spec export(keyword()) :: map()
  def export(opts \\ []) do
    catalog = %{
      "format" => Decoder.format(),
      "version" => Decoder.version(),
      "features" => Enum.map(features(), &export_feature/1)
    }

    case opts[:only] do
      :features -> catalog
      nil -> Map.put(catalog, "plans", Enum.map(plans(), &export_plan/1))
    end
  end

  @doc "A catalog map as pretty JSON text, ending with a newline."
  @spec encode(map()) :: String.t()
  def encode(catalog), do: Jason.encode!(catalog, pretty: true) <> "\n"

  @doc "Parses catalog JSON text (see `UdinBilling.Catalog.Decoder`)."
  @spec decode(String.t()) :: {:ok, Decoder.t()} | {:error, [String.t()]}
  defdelegate decode(json), to: Decoder

  @doc "What importing `catalog` would change, without changing anything."
  @spec changes(Decoder.t()) :: changes()
  def changes(catalog) do
    db_features = Map.new(features(), &{&1.key, &1})
    db_plans = Map.new(plans(), &{&1.code, &1})

    feature_changes = Enum.map(catalog.features, &feature_change(&1, db_features))
    plan_changes = Enum.map(catalog.plans || [], &plan_change(&1, db_plans))

    %{
      changes: feature_changes ++ plan_changes,
      not_in_file: %{
        features: Map.keys(db_features) -- Enum.map(catalog.features, & &1.key),
        plans: not_in_file(catalog.plans, db_plans)
      },
      errors: kind_errors(catalog.features, db_features) ++ required_errors(catalog, db_features)
    }
  end

  @doc """
  Applies `catalog` in one transaction. Returns `{:ok, changes}` (what was changed) or
  `{:error, reasons}` with nothing written.

  ## Options
    * `:deactivate_missing` - take plans that aren't in the file off sale (default false).
  """
  @spec apply_catalog(Decoder.t(), keyword()) ::
          {:ok, changes()} | {:error, [String.t()] | term()}
  def apply_catalog(catalog, opts \\ []) do
    case changes(catalog) do
      %{errors: [_ | _] = errors} ->
        {:error, errors}

      planned ->
        Transaction.run([Feature, Plan, PlanFeature], fn ->
          with :ok <- write_features(catalog.features, planned),
               :ok <- write_plans(catalog.plans || [], planned),
               :ok <- deactivate_missing(planned, opts[:deactivate_missing] == true) do
            {:ok, planned}
          end
        end)
    end
  end

  @doc "Writes the current catalog to `path` (creating its folder). Takes `export/1`'s options."
  @spec export_file(String.t(), keyword()) :: :ok | {:error, File.posix()}
  def export_file(path \\ default_path(), opts \\ []) do
    with :ok <- File.mkdir_p(Path.dirname(path)), do: File.write(path, encode(export(opts)))
  end

  @doc """
  Reads the catalog at `path` and applies it, or with `dry_run: true` only returns what
  would change. Takes `apply_catalog/2`'s options.
  """
  @spec import_file(String.t(), keyword()) :: {:ok, changes()} | {:error, [String.t()] | term()}
  def import_file(path \\ default_path(), opts \\ []) do
    with {:ok, json} <- read(path),
         {:ok, catalog} <- decode(json) do
      if opts[:dry_run], do: {:ok, changes(catalog)}, else: apply_catalog(catalog, opts)
    end
  end

  @doc "Required features (`config :udin_billing, :required_features`) missing from the database."
  @spec missing_required() :: [String.t()]
  def missing_required do
    present = MapSet.new(features(), & &1.key)
    Enum.reject(Config.required_features(), &MapSet.member?(present, &1))
  end

  @doc "Plain lines describing `changes`, for terminals and the dashboard."
  @spec describe(changes()) :: [String.t()]
  def describe(%{changes: changes, not_in_file: not_in_file, errors: errors}) do
    Enum.map(errors, &"error: #{&1}") ++
      for(
        %{action: action} = change <- changes,
        action != :unchanged,
        do: describe_change(change)
      ) ++
      Enum.map(not_in_file.plans, &"plan #{&1}: in the database, not in the file (kept)") ++
      Enum.map(not_in_file.features, &"feature #{&1}: in the database, not in the file (kept)")
  end

  # -- export -------------------------------------------------------------------

  defp features do
    Feature |> Ash.Query.sort(sort_order: :asc, key: :asc) |> Ash.read!(authorize?: false)
  end

  defp plans do
    Plan |> Ash.Query.sort(sort_order: :asc, code: :asc) |> Ash.read!(authorize?: false)
  end

  defp export_feature(feature) do
    %{
      "key" => feature.key,
      "kind" => Atom.to_string(feature.kind),
      "name" => feature.name,
      "description" => feature.description,
      "sort_order" => feature.sort_order
    }
  end

  defp export_plan(plan) do
    %{
      "code" => plan.code,
      "name" => plan.name,
      "description" => plan.description,
      "kind" => Atom.to_string(plan.kind),
      "price" => Decimal.to_string(plan.price, :normal),
      "original_price" => plan.original_price && Decimal.to_string(plan.original_price, :normal),
      "currency" => plan.currency,
      "validity_unit" => atom_text(plan.validity_unit),
      "validity_count" => plan.validity_count,
      "cycle_unit" => atom_text(plan.cycle_unit),
      "cycle_count" => plan.cycle_count,
      "status" => Atom.to_string(plan.status),
      "is_default" => plan.is_default,
      "sort_order" => plan.sort_order,
      "after_subscription" => Atom.to_string(plan.after_subscription),
      "provider_product_ids" => plan.provider_product_ids,
      "metadata" => plan.metadata,
      "features" => included(plan.features)
    }
  end

  defp atom_text(nil), do: nil
  defp atom_text(atom), do: Atom.to_string(atom)

  # Off switches and zero counters mean "not included": leave them out of the file.
  defp included(values),
    do: values |> Enum.reject(fn {_key, v} -> v in [false, 0] end) |> Map.new()

  # -- compare --------------------------------------------------------------------

  defp feature_change(feature, db) do
    case Map.fetch(db, feature.key) do
      {:ok, existing} -> diff(:feature, feature.key, feature, existing, @feature_fields)
      :error -> %{type: :feature, key: feature.key, action: :create, fields: []}
    end
  end

  defp plan_change(plan, db) do
    case Map.fetch(db, plan.code) do
      {:ok, existing} ->
        change = diff(:plan, plan.code, plan, existing, @plan_fields)

        if included(plan.features) == included(existing.features),
          do: change,
          else: %{change | action: :update, fields: change.fields ++ [:features]}

      :error ->
        %{type: :plan, key: plan.code, action: :create, fields: []}
    end
  end

  defp diff(type, key, wanted, existing, fields) do
    changed = Enum.reject(fields, &same?(Map.fetch!(wanted, &1), Map.fetch!(existing, &1)))

    %{
      type: type,
      key: key,
      action: if(changed == [], do: :unchanged, else: :update),
      fields: changed
    }
  end

  defp same?(%Decimal{} = a, %Decimal{} = b), do: Decimal.equal?(a, b)
  defp same?(a, b), do: a == b

  defp kind_errors(features, db) do
    for feature <- features,
        {:ok, existing} <- [Map.fetch(db, feature.key)],
        existing.kind != feature.kind,
        do: "feature #{feature.key}: kind is #{existing.kind} and can't change to #{feature.kind}"
  end

  defp required_errors(catalog, db) do
    present = MapSet.new(Map.keys(db) ++ Enum.map(catalog.features, & &1.key))

    for key <- Config.required_features(),
        not MapSet.member?(present, key),
        do:
          "feature #{key} is required by the app's code but is in neither the file nor the database"
  end

  # A features-only file says nothing about plans, so no plan is "missing" from it.
  defp not_in_file(nil, _db_plans), do: []
  defp not_in_file(plans, db_plans), do: Map.keys(db_plans) -- Enum.map(plans, & &1.code)

  # -- write ------------------------------------------------------------------------

  defp write_features(features, planned) do
    actions = actions_by_key(planned, :feature)

    Enum.reduce_while(features, :ok, fn feature, :ok ->
      case write_feature(actions[feature.key], feature) do
        {:ok, _} -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp write_feature(:unchanged, feature), do: {:ok, feature}
  defp write_feature(:create, feature), do: Ash.create(Feature, feature, authorize?: false)

  defp write_feature(:update, feature) do
    Feature
    |> Ash.get!(%{key: feature.key}, authorize?: false)
    |> Ash.Changeset.for_update(:update, Map.take(feature, @feature_fields))
    |> Ash.update(authorize?: false)
  end

  # Plans that stop being the default go first, so a new default never meets the old one.
  defp write_plans(plans, planned) do
    actions = actions_by_key(planned, :plan)

    plans
    |> Enum.sort_by(& &1.is_default)
    |> Enum.reduce_while(:ok, fn plan, :ok ->
      case write_plan(actions[plan.code], plan) do
        {:ok, _} -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp write_plan(:unchanged, plan), do: {:ok, plan}
  defp write_plan(:create, plan), do: Ash.create(Plan, plan, authorize?: false)

  defp write_plan(:update, plan) do
    Plan
    |> Ash.get!(%{code: plan.code}, authorize?: false)
    |> Ash.Changeset.for_update(:update, Map.delete(plan, :code))
    |> Ash.update(authorize?: false)
  end

  defp deactivate_missing(_planned, false), do: :ok

  defp deactivate_missing(%{not_in_file: %{plans: codes}}, true) do
    Plan
    |> Ash.Query.filter(code in ^codes and status == :active)
    |> Ash.read!(authorize?: false)
    |> Enum.reduce_while(:ok, fn plan, :ok ->
      case plan |> Ash.Changeset.for_update(:deactivate, %{}) |> Ash.update(authorize?: false) do
        {:ok, _} -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp actions_by_key(%{changes: changes}, type),
    do: for(%{type: ^type, key: key, action: action} <- changes, into: %{}, do: {key, action})

  # -- misc -------------------------------------------------------------------------

  defp read(path) do
    case File.read(path) do
      {:ok, json} -> {:ok, json}
      {:error, reason} -> {:error, ["can't read #{path}: #{:file.format_error(reason)}"]}
    end
  end

  defp describe_change(%{type: type, key: key, action: :create}), do: "#{type} #{key}: create"

  defp describe_change(%{type: type, key: key, action: :update, fields: fields}),
    do: "#{type} #{key}: update #{Enum.join(fields, ", ")}"
end

defmodule UdinBilling.Feature do
  @moduledoc """
  One entry in an app's feature catalog: a **switch** (on/off) or a **counter** (units
  per cycle).

  ## Why
  Each app decides its own features (`share_recipe`, `smart_aggregation`, `reel_imports`,
  `rides`, ...) and which plans include them. Keeping the catalog in the database lets an
  admin add a feature, even one not built yet, and switch it on per plan without a code
  change. Plans store a value per feature in `UdinBilling.PlanFeature`.

  `key` is what code checks (`UdinBilling.enabled?(user_id, "share_recipe")`), so it's
  fixed once created: lowercase letters, digits and underscores. `kind` is fixed too,
  because plan values depend on it. A feature can only be deleted when no plan uses it.
  """
  use Ash.Resource,
    domain: UdinBilling.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  require Ash.Query

  @type kind :: :switch | :counter

  postgres do
    # timestamptz columns: `now()` is already an absolute time. AshPostgres' default
    # ("now() AT TIME ZONE 'utc'") is meant for columns without a time zone and is read back
    # shifted when the database session isn't UTC (Family-Corp's is Africa/Cairo).
    migration_defaults inserted_at: "fragment(\"now()\")", updated_at: "fragment(\"now()\")"
    table "billing_features"
    repo Application.compile_env!(:udin_billing, :repo)
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:key, :kind, :name, :description, :sort_order]
    end

    update :update do
      primary? true
      accept [:name, :description, :sort_order]
      require_atomic? false
    end

    destroy :destroy do
      primary? true
      require_atomic? false
      validate UdinBilling.Validations.FeatureNotRequired
      validate UdinBilling.Validations.FeatureUnused
    end

    read :by_keys do
      argument :keys, {:array, :string}, allow_nil?: false
      filter expr(key in ^arg(:keys))
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if always()
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if UdinBilling.Checks.Admin
    end
  end

  validations do
    validate {UdinBilling.Validations.Translations, attribute: :name, required: true}
    validate {UdinBilling.Validations.Translations, attribute: :description}

    validate match(:key, ~r/\A[a-z][a-z0-9_]{0,62}\z/),
      message: "use lowercase letters, digits and underscores, starting with a letter"
  end

  attributes do
    uuid_primary_key :id

    attribute :key, :string, allow_nil?: false, public?: true

    attribute :kind, :atom,
      allow_nil?: false,
      constraints: [one_of: [:switch, :counter]],
      public?: true

    attribute :name, :map, allow_nil?: false, default: %{}, public?: true
    attribute :description, :map, allow_nil?: false, default: %{}, public?: true
    attribute :sort_order, :integer, allow_nil?: false, default: 0, public?: true

    timestamps(public?: true, type: AshPostgres.TimestamptzUsec)
  end

  identities do
    identity :unique_key, [:key]
  end

  @doc "Catalog rows for `keys`, keyed by key. Unknown keys are simply absent."
  @spec fetch_by_keys([String.t()]) :: %{String.t() => struct()}
  def fetch_by_keys([]), do: %{}

  def fetch_by_keys(keys) do
    __MODULE__
    |> Ash.Query.for_read(:by_keys, %{keys: keys})
    |> Ash.read!(authorize?: false)
    |> Map.new(&{&1.key, &1})
  end
end

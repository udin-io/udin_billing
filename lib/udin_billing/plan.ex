defmodule UdinBilling.Plan do
  @moduledoc """
  Something sold or given: its price, how long it lasts, how often its counters reset,
  and which features it includes.

  ## Fields
    * `kind` - `:free` (the single default plan everyone has), `:one_time` or
      `:recurring`. Only kinds in `config :udin_billing, :modes` can be created.
    * `validity_unit` / `validity_count` - how long access lasts: a one-time bundle's
      length, or a subscription's billing period. Both nil = never ends.
    * `cycle_unit` / `cycle_count` - how often counters reset, from each user's own start
      date. Both nil = counters are granted once for the whole validity. A yearly plan
      with monthly counters: validity 1 year, cycle 1 month.
    * `features` - the plan's value per catalog feature, e.g.
      `%{"reel_imports" => 15, "share_recipe" => true}`. Set it through the `features`
      argument of create/update; it's validated against `UdinBilling.Feature` and stored
      both normalized (`UdinBilling.PlanFeature`) and here for fast reads.
    * `provider_product_ids` - the id(s) each provider knows the plan by, a string or a
      list, e.g. `%{"revenuecat" => ["basic_monthly", "basic_monthly:monthly"]}` (App
      Store id and Google Play `product:base_plan` id).
    * `metadata` - display data the billing logic never reads (e.g. `"recommended" => true`).

  ## Editing and deactivating
  Purchases and subscriptions copy the plan's terms when they start, so editing a plan
  never changes what a buyer has. Deactivating only takes a plan off sale.

  Examples:

      # ReelsChef Basic, yearly with monthly counters
      %{code: "basic_yearly", kind: :recurring, price: 1980, validity_unit: :year,
        validity_count: 1, cycle_unit: :month, cycle_count: 1,
        features: %{"reel_imports" => 15, "share_recipe" => true}}

      # ReelsChef single reel (never expires)
      %{code: "one_reel", kind: :one_time, price: 15, features: %{"reel_imports" => 1}}

      # Family-Corp weekly bundle
      %{code: "weekly", kind: :one_time, price: 150, validity_unit: :week,
        validity_count: 1, features: %{"rides" => 10}}
  """
  use Ash.Resource,
    domain: UdinBilling.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  require Ash.Query

  @type unit :: :day | :week | :month | :year
  @type period_label :: :daily | :weekly | :monthly | :yearly | :custom | :unlimited

  @units [:day, :week, :month, :year]

  @editable_fields [
    :code,
    :name,
    :description,
    :kind,
    :price,
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
    :after_subscription,
    :original_price
  ]

  postgres do
    # timestamptz columns: `now()` is already an absolute time. AshPostgres' default
    # ("now() AT TIME ZONE 'utc'") is meant for columns without a time zone and is read back
    # shifted when the database session isn't UTC (Family-Corp's is Africa/Cairo).
    migration_defaults inserted_at: "fragment(\"now()\")", updated_at: "fragment(\"now()\")"
    table "billing_plans"
    repo Application.compile_env!(:udin_billing, :repo)

    identity_wheres_to_sql single_default: "is_default = true"
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept @editable_fields
      argument :features, :map, default: %{}
      change UdinBilling.Changes.SyncPlanFeatures
    end

    update :update do
      primary? true
      accept @editable_fields
      argument :features, :map
      require_atomic? false
      change UdinBilling.Changes.SyncPlanFeatures
    end

    update :activate do
      require_atomic? false
      change set_attribute(:status, :active)
    end

    update :deactivate do
      require_atomic? false
      change set_attribute(:status, :inactive)
    end

    read :purchasable do
      description "Active paid plans for sale, in display order."
      filter expr(status == :active and kind != :free)
      prepare build(sort: [sort_order: :asc, price: :asc])
    end

    read :default_plan do
      get? true
      filter expr(is_default == true and status == :active)
    end

    read :with_provider_products do
      description "Plans that list product ids for a provider."
      argument :provider, :string, allow_nil?: false
      filter expr(not is_nil(get_path(provider_product_ids, [^arg(:provider)])))
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if always()
    end

    policy action_type([:create, :update]) do
      authorize_if UdinBilling.Checks.Admin
    end
  end

  validations do
    # Only when the kind is set or changed, so a plan whose kind was later disabled can
    # still be edited or deactivated.
    validate UdinBilling.Validations.EnabledMode, where: [changing(:kind)]
    validate UdinBilling.Validations.UniqueProductIds, where: [changing(:provider_product_ids)]
    validate {UdinBilling.Validations.Translations, attribute: :name, required: true}
    validate {UdinBilling.Validations.Translations, attribute: :description}

    validate match(:currency, ~r/\A[A-Z]{3}\z/),
      message: "currency must be an uppercase ISO 4217 code, e.g. EGP"

    validate UdinBilling.Validations.CurrencyAllowed, where: [changing(:currency)]

    validate present(:validity_count), where: [present(:validity_unit)]
    validate present(:validity_unit), where: [present(:validity_count)]
    validate present(:cycle_count), where: [present(:cycle_unit)]
    validate present(:cycle_unit), where: [present(:cycle_count)]

    validate present([:validity_unit, :validity_count]),
      where: [attribute_equals(:kind, :recurring)],
      message: "recurring plans need a billing period"

    validate compare(:price, less_than_or_equal_to: 0),
      where: [attribute_equals(:kind, :free)],
      message: "free plans must cost 0"

    validate compare(:price, greater_than: 0),
      where: [attribute_does_not_equal(:kind, :free)],
      message: "paid plans must have a price"

    validate UdinBilling.Validations.OriginalPriceAbovePrice

    validate attribute_equals(:kind, :free),
      where: [attribute_equals(:is_default, true)],
      message: "only a free plan can be the default"
  end

  attributes do
    uuid_primary_key :id

    attribute :code, :string, allow_nil?: false, public?: true
    attribute :name, :map, allow_nil?: false, public?: true, description: "Locale => text"
    attribute :description, :map, allow_nil?: false, default: %{}, public?: true

    attribute :kind, :atom,
      allow_nil?: false,
      constraints: [one_of: [:free, :one_time, :recurring]],
      public?: true

    attribute :original_price, :decimal,
      public?: true,
      description: """
      The price before a sale, shown crossed out next to `price`. Display only: buyers
      always pay `price`. Higher than `price` when set; may change on a plan with buyers.
      """

    attribute :price, :decimal,
      allow_nil?: false,
      default: Decimal.new(0),
      constraints: [min: 0],
      public?: true

    attribute :currency, :string,
      allow_nil?: false,
      default: &UdinBilling.Config.default_currency/0,
      public?: true

    attribute :validity_unit, :atom, constraints: [one_of: @units], public?: true
    attribute :validity_count, :integer, constraints: [min: 1], public?: true
    attribute :cycle_unit, :atom, constraints: [one_of: @units], public?: true
    attribute :cycle_count, :integer, constraints: [min: 1], public?: true

    attribute :features, :map,
      allow_nil?: false,
      default: %{},
      public?: true,
      writable?: false,
      description: "Derived from plan_features: key => true/false/limit/\"unlimited\""

    attribute :provider_product_ids, :map, allow_nil?: false, default: %{}, public?: true

    attribute :status, :atom,
      allow_nil?: false,
      default: :active,
      constraints: [one_of: [:active, :inactive]],
      public?: true

    attribute :is_default, :boolean, allow_nil?: false, default: false, public?: true

    attribute :after_subscription, :atom,
      allow_nil?: false,
      default: :continue,
      constraints: [one_of: [:continue, :fresh_start]],
      public?: true,
      description: """
      Free plan only: what a user gets back on the free plan after a subscription ends.
      `:continue` - the free allowance carries on: units used before stay used and a
      lifetime allowance is never given again. `:fresh_start` - a new free allowance
      each time a subscription ends (lifetime units again, or a new cycle from that day).
      """

    attribute :sort_order, :integer, allow_nil?: false, default: 0, public?: true
    attribute :metadata, :map, allow_nil?: false, default: %{}, public?: true

    timestamps(public?: true, type: AshPostgres.TimestamptzUsec)
  end

  relationships do
    has_many :feature_values, UdinBilling.PlanFeature, public?: true
  end

  identities do
    identity :unique_code, [:code]
    identity :single_default, [:is_default], where: expr(is_default == true)
  end

  @doc """
  When access bought at `from` ends under `terms` (a plan, purchase or subscription), or
  nil if it never does. Calendar-aware: a month from Jan 31 ends Feb 28/29.
  """
  @spec expires_at(map(), DateTime.t()) :: DateTime.t() | nil
  def expires_at(%{validity_unit: nil}, _from), do: nil

  def expires_at(%{validity_unit: unit, validity_count: count}, %DateTime{} = from),
    do: DateTime.shift(from, [{unit, count}])

  @doc """
  Display label of the validity: `:daily`, `:weekly`, `:monthly`, `:yearly` for one unit,
  `:custom` otherwise, `:unlimited` when it never ends.
  """
  @spec period_label(map()) :: period_label()
  def period_label(%{validity_unit: nil}), do: :unlimited
  def period_label(%{validity_unit: :day, validity_count: 1}), do: :daily
  def period_label(%{validity_unit: :week, validity_count: 1}), do: :weekly
  def period_label(%{validity_unit: :month, validity_count: 1}), do: :monthly
  def period_label(%{validity_unit: :year, validity_count: 1}), do: :yearly
  def period_label(%{}), do: :custom

  @doc """
  A translated field (`:name`, `:description`) of a plan or feature for `locale`, falling
  back to the default locale, then any translation (`UdinBilling.Translations.get/2`).
  """
  @spec localized(map(), :name | :description, String.t() | nil) :: String.t() | nil
  def localized(record, field, locale) when field in [:name, :description],
    do: UdinBilling.Translations.get(Map.fetch!(record, field), locale)

  @doc """
  The plan (active or not) a provider product id belongs to, or nil. Inactive plans count:
  a store keeps renewing a product until it's removed from sale there.
  """
  @spec by_product_id(String.t(), String.t()) :: struct() | nil
  def by_product_id(provider, product_id) do
    __MODULE__
    |> Ash.Query.for_read(:with_provider_products, %{provider: provider})
    |> Ash.read!(authorize?: false)
    |> Enum.find(&(product_id in List.wrap(&1.provider_product_ids[provider])))
  end

  @doc "The active default (free) plan, or nil."
  @spec default_plan() :: struct() | nil
  def default_plan do
    __MODULE__ |> Ash.Query.for_read(:default_plan) |> Ash.read_one!(authorize?: false)
  end
end

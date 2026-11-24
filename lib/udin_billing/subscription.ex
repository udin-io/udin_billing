defmodule UdinBilling.Subscription do
  @moduledoc """
  A user's auto-renewing plan, as reported by a store or provider.

  ## Why the provider drives it
  Stores (App Store, Google Play) own billing, renewals, retries and refunds. This row is
  our copy of the latest state they report (`UdinBilling.Subscriptions.apply_state/4`),
  and access is computed from its dates, so a missed message can never extend access.

  ## Dates
    * `period_starts_at` / `period_ends_at` - the paid period now. A renewal starts a new
      period, which starts new counter cycles (no carry over).
    * `grace_ends_at` - the end of the store's billing-retry grace period, as reported.
      Whether it extends access is `config :udin_billing, :grace_access`, read at access
      time (the `active` read with `include_grace`).
    * `access_ends_at` - when **paid** access ends: the refund time if refunded, otherwise
      the period end.
    * `auto_renew` - false after the user cancels; access still lasts until the period end.

  `features`, validity and cycle are copied from the plan at each paid period, so a plan
  edit applies from the next renewal and never mid-period.
  """
  use Ash.Resource,
    domain: UdinBilling.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @user_resource Application.compile_env!(:udin_billing, :user_resource)
  @units [:day, :week, :month, :year]

  postgres do
    # timestamptz columns: `now()` is already an absolute time. AshPostgres' default
    # ("now() AT TIME ZONE 'utc'") is meant for columns without a time zone and is read back
    # shifted when the database session isn't UTC (Family-Corp's is Africa/Cairo).
    migration_defaults inserted_at: "fragment(\"now()\")", updated_at: "fragment(\"now()\")"
    table "billing_subscriptions"
    repo Application.compile_env!(:udin_billing, :repo)

    references do
      reference :plan, on_delete: :restrict
      reference :user, on_delete: :restrict
    end

    custom_indexes do
      index [:user_id, :access_ends_at]
    end
  end

  actions do
    read :read do
      primary? true

      pagination offset?: true,
                 keyset?: true,
                 required?: false,
                 countable: true,
                 default_limit: 50
    end

    create :create do
      primary? true

      accept [
        :user_id,
        :plan_id,
        :provider,
        :provider_ref,
        :store,
        :status,
        :auto_renew,
        :period_starts_at,
        :period_ends_at,
        :grace_ends_at,
        :access_ends_at,
        :refunded_at,
        :features,
        :validity_unit,
        :validity_count,
        :cycle_unit,
        :cycle_count
      ]
    end

    update :update do
      primary? true

      accept [
        :store,
        :status,
        :auto_renew,
        :period_starts_at,
        :period_ends_at,
        :grace_ends_at,
        :access_ends_at,
        :refunded_at,
        :features,
        :validity_unit,
        :validity_count,
        :cycle_unit,
        :cycle_count
      ]
    end

    read :active do
      description """
      Subscriptions granting access at `at`, judged by dates: of `user_ids`, or of everyone
      when it's nil. The one place that decides "active", for a user's access and for lists.
      """

      argument :user_ids, {:array, :uuid}
      argument :at, AshPostgres.TimestamptzUsec, allow_nil?: false
      argument :include_grace, :boolean, allow_nil?: false, default: false

      filter expr(
               (is_nil(^arg(:user_ids)) or user_id in ^arg(:user_ids)) and status != :refunded and
                 period_starts_at <= ^arg(:at) and
                 (access_ends_at > ^arg(:at) or
                    (^arg(:include_grace) and is_nil(refunded_at) and not is_nil(grace_ends_at) and
                       grace_ends_at > ^arg(:at)))
             )

      prepare build(sort: [period_starts_at: :asc])
    end

    read :by_provider_ref do
      argument :provider, :string, allow_nil?: false
      argument :provider_ref, :string, allow_nil?: false
      get? true
      filter expr(provider == ^arg(:provider) and provider_ref == ^arg(:provider_ref))
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if UdinBilling.Checks.Admin
      authorize_if relates_to_actor_via(:user)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :provider, :string, allow_nil?: false, public?: true
    attribute :provider_ref, :string, allow_nil?: false, public?: true

    attribute :store, :string do
      public? true

      description """
      Where it was bought, as the provider reports it (RevenueCat: `app_store`,
      `play_store`...). An app needs it to change the plan in that store: a subscription
      can only be upgraded in the store that bills it.
      """
    end

    attribute :status, :atom,
      allow_nil?: false,
      default: :active,
      constraints: [one_of: [:active, :grace, :expired, :refunded]],
      public?: true

    attribute :auto_renew, :boolean, allow_nil?: false, default: true, public?: true
    attribute :period_starts_at, AshPostgres.TimestamptzUsec, allow_nil?: false, public?: true
    attribute :period_ends_at, AshPostgres.TimestamptzUsec, allow_nil?: false, public?: true
    attribute :grace_ends_at, AshPostgres.TimestamptzUsec, public?: true
    attribute :access_ends_at, AshPostgres.TimestamptzUsec, allow_nil?: false, public?: true
    attribute :refunded_at, AshPostgres.TimestamptzUsec, public?: true

    attribute :features, :map, allow_nil?: false, default: %{}, public?: true
    attribute :validity_unit, :atom, constraints: [one_of: @units], public?: true
    attribute :validity_count, :integer, constraints: [min: 1], public?: true
    attribute :cycle_unit, :atom, constraints: [one_of: @units], public?: true
    attribute :cycle_count, :integer, constraints: [min: 1], public?: true

    timestamps(public?: true, type: AshPostgres.TimestamptzUsec)
  end

  relationships do
    belongs_to :user, @user_resource, allow_nil?: false, attribute_writable?: true, public?: true

    belongs_to :plan, UdinBilling.Plan,
      allow_nil?: false,
      attribute_writable?: true,
      public?: true
  end

  identities do
    identity :unique_provider_ref, [:provider, :provider_ref]
  end
end

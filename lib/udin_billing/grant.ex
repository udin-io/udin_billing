defmodule UdinBilling.Grant do
  @moduledoc """
  A lot of units of one counter for one cycle of one source, e.g. "15 reel_imports from
  Basic, Oct 10 to Nov 10" or "1 reel_imports from a top-up, never expires".

  ## Why lots
  Each source (the free plan, a purchase, a subscription) and each cycle keeps its own
  units and expiry, so units expire at their cycle end (no carry over) and spending can
  take from the soonest-expiring lot first. A balance is always the sum of valid lots.

  ## Fields
    * `amount` / `remaining` - nil on both means unlimited.
    * `source_key` - which source and cycle created it, e.g. `"purchase:<id>:0"`. Unique
      per user and feature, so concurrent requests create a lot once.
    * `revoked_at` - set when the source's access is withdrawn (refund, plan change).

  A database check keeps `remaining >= 0` even if application code were wrong.
  Lots are created by `UdinBilling.Quotas` when needed, never by hand.
  """
  use Ash.Resource,
    domain: UdinBilling.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @user_resource Application.compile_env!(:udin_billing, :user_resource)

  postgres do
    # timestamptz columns: `now()` is already an absolute time. AshPostgres' default
    # ("now() AT TIME ZONE 'utc'") is meant for columns without a time zone and is read back
    # shifted when the database session isn't UTC (Family-Corp's is Africa/Cairo).
    migration_defaults inserted_at: "fragment(\"now()\")", updated_at: "fragment(\"now()\")"
    table "billing_grants"
    repo Application.compile_env!(:udin_billing, :repo)

    references do
      reference :user, on_delete: :restrict
      reference :plan, on_delete: :restrict
      reference :purchase, on_delete: :restrict
      reference :subscription, on_delete: :restrict
    end

    check_constraints do
      check_constraint :remaining, "remaining_not_negative",
        check: "remaining IS NULL OR remaining >= 0",
        message: "remaining units can't be negative"
    end

    custom_indexes do
      index [:user_id, :feature_key, :expires_at]
      index [:purchase_id]
      index [:subscription_id]
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

    create :ensure do
      description "Creates the lot once; on a duplicate returns the existing lot unchanged."

      accept [
        :user_id,
        :plan_id,
        :purchase_id,
        :subscription_id,
        :feature_key,
        :source_key,
        :amount,
        :remaining,
        :starts_at,
        :expires_at
      ]

      upsert? true
      upsert_identity :unique_source
      upsert_fields [:updated_at]
    end

    update :debit do
      argument :units, :integer, allow_nil?: false, constraints: [min: 1]
      require_atomic? false
      validate {UdinBilling.Validations.EnoughRemaining, []}
      change atomic_update(:remaining, expr(remaining - ^arg(:units)))
    end

    update :credit do
      argument :units, :integer, allow_nil?: false, constraints: [min: 1]

      change atomic_update(
               :remaining,
               expr(if is_nil(remaining), do: nil, else: remaining + ^arg(:units))
             )
    end

    update :revoke do
      change set_attribute(:revoked_at, &DateTime.utc_now/0)
    end

    read :spendable do
      description """
      Lots a user can spend at `at`, soonest-expiring first. Without `feature_key`, lots of
      every feature (for whole-account balances).
      """

      argument :user_id, :uuid, allow_nil?: false
      argument :feature_key, :string
      argument :at, AshPostgres.TimestamptzUsec, allow_nil?: false

      filter expr(
               user_id == ^arg(:user_id) and
                 (is_nil(^arg(:feature_key)) or feature_key == ^arg(:feature_key)) and
                 is_nil(revoked_at) and starts_at <= ^arg(:at) and
                 (is_nil(expires_at) or expires_at > ^arg(:at))
             )

      prepare build(sort: [expires_at: :asc_nils_last, inserted_at: :asc])
    end

    read :for_sources do
      description "A user's lots for the given source keys (any feature)."
      argument :user_id, :uuid, allow_nil?: false
      argument :source_keys, {:array, :string}, allow_nil?: false
      filter expr(user_id == ^arg(:user_id) and source_key in ^arg(:source_keys))
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

    attribute :feature_key, :string, allow_nil?: false, public?: true
    attribute :source_key, :string, allow_nil?: false, public?: true
    attribute :amount, :integer, constraints: [min: 0], public?: true
    attribute :remaining, :integer, constraints: [min: 0], public?: true
    attribute :starts_at, AshPostgres.TimestamptzUsec, allow_nil?: false, public?: true
    attribute :expires_at, AshPostgres.TimestamptzUsec, public?: true
    attribute :revoked_at, AshPostgres.TimestamptzUsec, public?: true

    timestamps(public?: true, type: AshPostgres.TimestamptzUsec)
  end

  relationships do
    belongs_to :user, @user_resource, allow_nil?: false, attribute_writable?: true, public?: true

    belongs_to :plan, UdinBilling.Plan,
      allow_nil?: false,
      attribute_writable?: true,
      public?: true

    belongs_to :purchase, UdinBilling.Purchase, attribute_writable?: true, public?: true
    belongs_to :subscription, UdinBilling.Subscription, attribute_writable?: true, public?: true
  end

  identities do
    identity :unique_source, [:user_id, :source_key, :feature_key]
  end

  @doc "True when the lot has no limit."
  @spec unlimited?(struct()) :: boolean()
  def unlimited?(%{remaining: nil}), do: true
  def unlimited?(%{}), do: false
end

defmodule UdinBilling.Usage do
  @moduledoc """
  One spend of units from one lot, keyed by the app's `reference` (booking id,
  extraction id). It's both the history and the reservation.

  ## States
    * `:held` - reserved at the start of work (e.g. a reel extraction). The lot's units are
      already taken, so a parallel request can't use them. Lapses at `hold_expires_at`.
    * `:committed` - the work succeeded; the units are used.
    * `:released` - the work failed or the hold lapsed; the units went back to the lot.

  Only one live (held or committed) row per lot and reference may exist, so a reference is
  never charged twice. Users with usage history can't be hard-deleted.
  """
  use Ash.Resource,
    domain: UdinBilling.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @user_resource Application.compile_env!(:udin_billing, :user_resource)

  postgres do
    # timestamptz column: `now()` is already an absolute time (see `UdinBilling.Account`).
    migration_defaults inserted_at: "fragment(\"now()\")"
    table "billing_usages"
    repo Application.compile_env!(:udin_billing, :repo)

    identity_wheres_to_sql live_reference: "status <> 'released'"

    references do
      reference :user, on_delete: :restrict
      reference :grant, on_delete: :restrict
    end

    custom_indexes do
      index [:user_id, :feature_key, :reference]
      index [:user_id, :feature_key, :status, :hold_expires_at]
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
      accept [:user_id, :grant_id, :feature_key, :amount, :reference, :status, :hold_expires_at]

      change set_attribute(:committed_at, &DateTime.utc_now/0),
        where: [attribute_equals(:status, :committed)]
    end

    update :commit do
      change set_attribute(:status, :committed)
      change set_attribute(:committed_at, &DateTime.utc_now/0)
    end

    update :release do
      change set_attribute(:status, :released)
      change set_attribute(:released_at, &DateTime.utc_now/0)
    end

    read :live_for_reference do
      description "Held or committed usage of a reference."
      argument :user_id, :uuid, allow_nil?: false
      argument :feature_key, :string, allow_nil?: false
      argument :reference, :string, allow_nil?: false

      filter expr(
               user_id == ^arg(:user_id) and feature_key == ^arg(:feature_key) and
                 reference == ^arg(:reference) and status != :released
             )
    end

    read :lapsed_holds do
      description "A user's holds that lapsed by `at`; without `feature_key`, of every feature."
      argument :user_id, :uuid, allow_nil?: false
      argument :feature_key, :string
      argument :at, AshPostgres.TimestamptzUsec, allow_nil?: false

      filter expr(
               user_id == ^arg(:user_id) and
                 (is_nil(^arg(:feature_key)) or feature_key == ^arg(:feature_key)) and
                 status == :held and hold_expires_at <= ^arg(:at)
             )
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
    attribute :amount, :integer, allow_nil?: false, constraints: [min: 1], public?: true
    attribute :reference, :string, allow_nil?: false, public?: true

    attribute :status, :atom,
      allow_nil?: false,
      constraints: [one_of: [:held, :committed, :released]],
      public?: true

    attribute :hold_expires_at, AshPostgres.TimestamptzUsec, public?: true
    attribute :committed_at, AshPostgres.TimestamptzUsec, public?: true
    attribute :released_at, AshPostgres.TimestamptzUsec, public?: true

    create_timestamp :inserted_at, public?: true, type: AshPostgres.TimestamptzUsec
  end

  relationships do
    belongs_to :user, @user_resource, allow_nil?: false, attribute_writable?: true, public?: true

    belongs_to :grant, UdinBilling.Grant,
      allow_nil?: false,
      attribute_writable?: true,
      public?: true
  end

  identities do
    identity :live_reference, [:grant_id, :reference], where: expr(status != :released)
  end
end

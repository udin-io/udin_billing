defmodule UdinBilling.ProviderEvent do
  @moduledoc """
  Every verified provider message, stored before it's applied.

  ## Why
  Providers retry and sometimes send the same message twice at once. Storing each under a
  unique `(provider, event_id)` and locking it while applying means a message changes
  billing exactly once. Refused messages stay with their reason so an admin can review and
  replay them (`UdinBilling.Webhooks.replay/1`).

  `event` is the message as verified on arrival; replays use it as is, so a provider that
  authenticates with a header secret (never stored) can still be replayed. Only the app
  writes this table and only admins can replay.

  ## Status
    * `:received` - stored, not applied yet (or applying failed and will be retried).
    * `:processed` - applied.  * `:ignored` - nothing to do.
    * `:failed` - refused for a business reason (wrong amount, unknown purchase); needs a human.
  """
  use Ash.Resource,
    domain: UdinBilling.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    # timestamptz columns: `now()` is already an absolute time. AshPostgres' default
    # ("now() AT TIME ZONE 'utc'") is meant for columns without a time zone and is read back
    # shifted when the database session isn't UTC (Family-Corp's is Africa/Cairo).
    migration_defaults inserted_at: "fragment(\"now()\")", updated_at: "fragment(\"now()\")"
    table "billing_provider_events"
    repo Application.compile_env!(:udin_billing, :repo)

    custom_indexes do
      index [:status, :inserted_at]
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

    create :receive do
      description "Stores a message; on a duplicate returns the existing row unchanged."
      accept [:provider, :event_id, :event_type, :reference, :event, :payload]
      upsert? true
      upsert_identity :unique_event
      upsert_fields [:updated_at]
    end

    update :mark_processed do
      change set_attribute(:status, :processed)
      change set_attribute(:processed_at, &DateTime.utc_now/0)
      change set_attribute(:error, nil)
      change atomic_update(:attempts, expr(attempts + 1))
    end

    update :mark_ignored do
      change set_attribute(:status, :ignored)
      change set_attribute(:processed_at, &DateTime.utc_now/0)
      change atomic_update(:attempts, expr(attempts + 1))
    end

    update :mark_failed do
      accept [:error]
      change set_attribute(:status, :failed)
      change atomic_update(:attempts, expr(attempts + 1))
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if UdinBilling.Checks.Admin
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :provider, :string, allow_nil?: false, public?: true
    attribute :event_id, :string, allow_nil?: false, public?: true

    attribute :event_type, :atom,
      allow_nil?: false,
      constraints: [
        one_of: [:payment_succeeded, :payment_failed, :refunded, :customer_changed, :ignored]
      ],
      public?: true

    attribute :reference, :string,
      public?: true,
      description: "Purchase or customer the message is about"

    attribute :status, :atom,
      allow_nil?: false,
      default: :received,
      constraints: [one_of: [:received, :processed, :ignored, :failed]],
      public?: true

    attribute :error, :string, public?: true
    attribute :attempts, :integer, allow_nil?: false, default: 0, public?: true

    attribute :event, :map,
      allow_nil?: false,
      default: %{},
      public?: true,
      description: "The verified, normalized message; replays use it without re-verifying"

    attribute :payload, :map, allow_nil?: false, default: %{}, public?: true
    attribute :processed_at, AshPostgres.TimestamptzUsec, public?: true

    timestamps(public?: true, type: AshPostgres.TimestamptzUsec)
  end

  identities do
    identity :unique_event, [:provider, :event_id]
  end
end

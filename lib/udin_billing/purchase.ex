defmodule UdinBilling.Purchase do
  @moduledoc """
  One purchase of a one-time plan: a Family-Corp bundle, a ReelsChef single reel, or a plan
  an admin gave as a gift.

  ## Lifecycle
  `:pending` (checkout started) → `:paid`, or `:failed` / `:cancelled`.
    * `:failed` can still become `:paid` when the provider later confirms success.
    * Money that arrives for a `:cancelled` checkout is accepted (`:paid`) when it's for
      that same checkout (its provider reference) and the full amount, under the `:stack`
      policy. Otherwise it becomes `:refund_required`: kept, nothing granted, waiting for a
      refund.
    * `:paid` / `:refund_required` → `:refunded` ends access immediately and revokes the
      purchase's unused units.

  ## Paid twice for one order
  `payment_ref` is the provider's id of the transaction that paid the purchase. When a
  second, different transaction succeeds for an order that's already paid (a double
  submit, card then wallet), it becomes its own purchase with `:record_second_payment`:
  `:refund_required`, nothing granted, linked to the first by `duplicate_of_id`. It shows
  among the payments to refund and in revenue as awaiting a refund.

  Purchases the store already completed (in-app top-ups) or admin gifts are created
  directly as `:paid` with `:record_paid`.

  ## Copied terms
  At creation the plan's price, currency, features, validity and cycle are copied here
  (`UdinBilling.Terms`). Payment must match the copied price exactly; units, expiry and
  switches all come from the copy, so later plan edits change nothing for this buyer.

  Users can't be hard-deleted while they have purchases (`on_delete: :restrict`): payment
  history is kept for accounting. Apps soft-delete users, which is unaffected.

  Use `UdinBilling.Purchases` instead of these actions directly: it adds the row locks.
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
    table "billing_purchases"
    repo Application.compile_env!(:udin_billing, :repo)

    references do
      reference :plan, on_delete: :restrict
      reference :user, on_delete: :restrict
      reference :duplicate_of, on_delete: :restrict
    end

    custom_indexes do
      index [:user_id, :status, :access_expires_at]
      index [:status, :inserted_at]
      index [:duplicate_of_id]
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

    create :start do
      description "A pending checkout, priced from the plan."
      accept [:user_id, :plan_id, :provider, :metadata]
      change UdinBilling.Changes.SnapshotPlan
      change UdinBilling.Changes.EnforcePurchasePolicy
    end

    create :record_paid do
      description "A purchase already paid elsewhere (store top-up) or given by an admin."
      accept [:user_id, :plan_id, :provider, :provider_ref, :metadata]
      argument :paid_at, AshPostgres.TimestamptzUsec
      argument :amount, :decimal, description: "Overrides the plan price, e.g. 0 for a gift"
      change UdinBilling.Changes.SnapshotPlan
      change UdinBilling.Changes.RecordPaid
    end

    create :record_second_payment do
      description """
      Money from a second transaction on an order whose purchase is already paid. Copies
      the first purchase's terms, grants nothing and waits for a refund.
      """

      accept [
        :user_id,
        :plan_id,
        :provider,
        :amount,
        :currency,
        :features,
        :validity_unit,
        :validity_count,
        :cycle_unit,
        :cycle_count,
        :payment_ref,
        :paid_at,
        :duplicate_of_id,
        :metadata
      ]

      change set_attribute(:status, :refund_required)

      change set_attribute(
               :failure_reason,
               "Paid twice for the same order. Refund this second payment."
             )
    end

    update :attach_provider_ref do
      accept [:provider_ref, :metadata]
    end

    update :mark_paid do
      argument :paid_amount, :decimal, allow_nil?: false
      argument :paid_currency, :string, allow_nil?: false
      argument :provider_ref, :string
      argument :payment_ref, :string
      argument :paid_at, AshPostgres.TimestamptzUsec
      require_atomic? false
      change {UdinBilling.Changes.MarkPaid, from: [:pending, :failed]}
    end

    update :mark_paid_late do
      description """
      Accepts money received for a cancelled checkout and gives the plan.
      `UdinBilling.Purchases` calls it only for the same checkout (its provider reference)
      and the full amount, under `:stack`.
      """

      argument :paid_amount, :decimal, allow_nil?: false
      argument :paid_currency, :string, allow_nil?: false
      argument :provider_ref, :string
      argument :payment_ref, :string
      argument :paid_at, AshPostgres.TimestamptzUsec
      require_atomic? false
      change {UdinBilling.Changes.MarkPaid, from: [:cancelled]}
    end

    update :mark_refund_required do
      description "Records money received for a cancelled checkout; grants nothing."
      argument :paid_amount, :decimal, allow_nil?: false
      argument :paid_currency, :string, allow_nil?: false
      argument :provider_ref, :string
      argument :payment_ref, :string
      argument :paid_at, AshPostgres.TimestamptzUsec
      argument :reason, :string, description: "Why it couldn't be accepted, for admins"
      require_atomic? false
      validate attribute_equals(:status, :cancelled)
      change UdinBilling.Changes.RecordLatePayment
    end

    update :mark_failed do
      accept [:failure_reason]
      validate attribute_equals(:status, :pending), message: "only pending purchases can fail"
      change set_attribute(:status, :failed)
    end

    update :mark_refunded do
      accept [:refund_reason]
      require_atomic? false

      validate attribute_in(:status, [:paid, :refund_required]),
        message: "only paid purchases can be refunded"

      change set_attribute(:status, :refunded)
      change set_attribute(:refunded_at, &DateTime.utc_now/0)
    end

    update :cancel do
      # A declined checkout can still be retried on the provider's page, so it's open too.
      validate attribute_in(:status, [:pending, :failed]),
        message: "only open checkouts can be cancelled"

      change set_attribute(:status, :cancelled)
    end

    read :by_provider_ref do
      argument :provider, :string, allow_nil?: false
      argument :provider_ref, :string, allow_nil?: false
      get? true
      filter expr(provider == ^arg(:provider) and provider_ref == ^arg(:provider_ref))
    end

    read :active_for_user do
      description "Paid purchases whose access hasn't ended at `at`."
      argument :user_id, :uuid, allow_nil?: false
      argument :at, AshPostgres.TimestamptzUsec, allow_nil?: false

      filter expr(
               user_id == ^arg(:user_id) and status == :paid and paid_at <= ^arg(:at) and
                 (is_nil(access_expires_at) or access_expires_at > ^arg(:at))
             )

      prepare build(sort: [paid_at: :asc])
    end

    read :open_checkouts do
      description """
      A user's checkouts still open since `since`, newest first. A declined one counts:
      the provider can still confirm a later retry on it.
      """

      argument :user_id, :uuid, allow_nil?: false
      argument :since, AshPostgres.TimestamptzUsec, allow_nil?: false

      filter expr(
               user_id == ^arg(:user_id) and status in [:pending, :failed] and
                 inserted_at >= ^arg(:since)
             )

      prepare build(sort: [inserted_at: :desc])
    end

    read :stale_pending do
      description """
      Checkouts still open (pending, or declined and retryable) created before `before`:
      abandoned checkouts.
      """

      argument :before, AshPostgres.TimestamptzUsec, allow_nil?: false
      filter expr(status in [:pending, :failed] and inserted_at < ^arg(:before))
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
    attribute :provider_ref, :string, public?: true

    attribute :payment_ref, :string,
      public?: true,
      description: "The provider's id of the transaction that paid this purchase."

    attribute :amount, :decimal, allow_nil?: false, public?: true
    attribute :currency, :string, allow_nil?: false, public?: true

    attribute :status, :atom,
      allow_nil?: false,
      default: :pending,
      constraints: [one_of: [:pending, :paid, :failed, :cancelled, :refund_required, :refunded]],
      public?: true

    attribute :features, :map, allow_nil?: false, default: %{}, public?: true
    attribute :validity_unit, :atom, constraints: [one_of: @units], public?: true
    attribute :validity_count, :integer, constraints: [min: 1], public?: true
    attribute :cycle_unit, :atom, constraints: [one_of: @units], public?: true
    attribute :cycle_count, :integer, constraints: [min: 1], public?: true

    attribute :paid_at, AshPostgres.TimestamptzUsec, public?: true
    attribute :access_expires_at, AshPostgres.TimestamptzUsec, public?: true
    attribute :failure_reason, :string, public?: true
    attribute :refunded_at, AshPostgres.TimestamptzUsec, public?: true
    attribute :refund_reason, :string, public?: true
    attribute :metadata, :map, allow_nil?: false, default: %{}, public?: true

    timestamps(public?: true, type: AshPostgres.TimestamptzUsec)
  end

  relationships do
    belongs_to :user, @user_resource, allow_nil?: false, attribute_writable?: true, public?: true

    belongs_to :plan, UdinBilling.Plan,
      allow_nil?: false,
      attribute_writable?: true,
      public?: true

    belongs_to :duplicate_of, __MODULE__,
      attribute_writable?: true,
      public?: true,
      description: "For a second payment on an already paid order: the first purchase."
  end

  identities do
    identity :unique_provider_ref, [:provider, :provider_ref]
    # One record per provider transaction: a second payment is never recorded twice.
    identity :unique_payment_ref, [:provider, :payment_ref]
  end
end

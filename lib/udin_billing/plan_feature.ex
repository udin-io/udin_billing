defmodule UdinBilling.PlanFeature do
  @moduledoc """
  A plan's value for one catalog feature: a switch's on/off, or a counter's units per
  cycle (`limit`, or `unlimited`).

  ## Why a table
  This is the normalized source of truth for "what does plan X include", so features and
  plans stay independent and admins can edit either. Plans also keep a derived copy of
  these values in `UdinBilling.Plan.features` (written in the same transaction by
  `UdinBilling.Changes.SyncPlanFeatures`), so access checks read one row instead of a join.

  Rows are written only through the plan's `features` argument, never directly.
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
    table "billing_plan_features"
    repo Application.compile_env!(:udin_billing, :repo)

    references do
      reference :plan, on_delete: :delete
      reference :feature, on_delete: :restrict
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:plan_id, :feature_id, :enabled, :limit, :unlimited]
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if always()
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :enabled, :boolean, allow_nil?: false, default: false, public?: true
    attribute :limit, :integer, constraints: [min: 0], public?: true
    attribute :unlimited, :boolean, allow_nil?: false, default: false, public?: true

    timestamps(public?: true, type: AshPostgres.TimestamptzUsec)
  end

  relationships do
    belongs_to :plan, UdinBilling.Plan,
      allow_nil?: false,
      attribute_writable?: true,
      public?: true

    belongs_to :feature, UdinBilling.Feature,
      allow_nil?: false,
      attribute_writable?: true,
      public?: true
  end

  identities do
    identity :unique_plan_feature, [:plan_id, :feature_id]
  end
end

defmodule UdinBilling.Account do
  @moduledoc """
  A user's billing start date, which anchors the free plan's cycles: with a monthly free
  plan, a user who started on the 10th gets their allowance from the 10th to the 9th.

  Created on the user's first billing activity, or earlier by the app calling
  `UdinBilling.ensure_account/1` at signup. Created once; the anchor never moves.
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
    table "billing_accounts"
    repo Application.compile_env!(:udin_billing, :repo)

    references do
      reference :user, on_delete: :restrict
    end
  end

  actions do
    defaults [:read]

    create :ensure do
      description "Creates the account; on a duplicate returns the existing one unchanged."
      accept [:user_id, :anchor_at]
      upsert? true
      upsert_identity :unique_user
      upsert_fields [:updated_at]
    end

    read :for_user do
      argument :user_id, :uuid, allow_nil?: false
      get? true
      filter expr(user_id == ^arg(:user_id))
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
    attribute :anchor_at, AshPostgres.TimestamptzUsec, allow_nil?: false, public?: true
    timestamps(public?: true, type: AshPostgres.TimestamptzUsec)
  end

  relationships do
    belongs_to :user, @user_resource, allow_nil?: false, attribute_writable?: true, public?: true
  end

  identities do
    identity :unique_user, [:user_id]
  end
end

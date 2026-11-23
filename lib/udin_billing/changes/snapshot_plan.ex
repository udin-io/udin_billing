defmodule UdinBilling.Changes.SnapshotPlan do
  @moduledoc """
  When a purchase is created: checks the plan can be bought (active, one-time, kind
  enabled) and copies its terms onto the purchase (`UdinBilling.Terms`).
  """
  use Ash.Resource.Change

  alias UdinBilling.{Config, Plan, Terms}

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &snapshot/1)
  end

  defp snapshot(changeset) do
    plan_id = Ash.Changeset.get_attribute(changeset, :plan_id)

    # A checkout needs a plan on sale. A purchase already paid in a store (or an admin
    # gift) is recorded even if the plan was taken off sale since: the money was taken.
    for_sale_only? = changeset.action.name == :start

    case Ash.get(Plan, plan_id, authorize?: false) do
      {:ok, %Plan{kind: :one_time, status: status} = plan}
      when status == :active or not for_sale_only? ->
        copy(changeset, plan)

      {:ok, %Plan{}} ->
        refuse(changeset, "plan is not for sale as a one-time purchase")

      {:error, _} ->
        refuse(changeset, "plan not found")
    end
  end

  defp copy(changeset, plan) do
    if Config.mode_enabled?(:one_time) do
      Ash.Changeset.force_change_attributes(changeset, Terms.from_plan(plan))
    else
      refuse(changeset, "one-time purchases are disabled")
    end
  end

  defp refuse(changeset, message),
    do: Ash.Changeset.add_error(changeset, field: :plan_id, message: message)
end

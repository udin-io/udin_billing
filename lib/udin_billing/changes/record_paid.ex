defmodule UdinBilling.Changes.RecordPaid do
  @moduledoc """
  For a purchase that's already paid (store top-up) or free (admin gift): marks it paid at
  `paid_at` (default now), computes its expiry from the copied validity, and applies an
  `amount` override when given. Runs after `UdinBilling.Changes.SnapshotPlan`.
  """
  use Ash.Resource.Change

  alias UdinBilling.Plan

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      paid_at = Ash.Changeset.get_argument(changeset, :paid_at) || DateTime.utc_now()
      validity = Map.take(changeset.attributes, [:validity_unit, :validity_count])

      changeset
      |> Ash.Changeset.force_change_attributes(
        status: :paid,
        paid_at: paid_at,
        access_expires_at: Plan.expires_at(Map.merge(%{validity_unit: nil}, validity), paid_at)
      )
      |> override_amount(Ash.Changeset.get_argument(changeset, :amount))
    end)
  end

  defp override_amount(changeset, nil), do: changeset

  defp override_amount(changeset, amount),
    do: Ash.Changeset.force_change_attribute(changeset, :amount, amount)
end

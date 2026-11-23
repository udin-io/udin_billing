defmodule UdinBilling.Changes.DefaultCycle do
  @moduledoc """
  Gives a subscription (recurring) plan with no refill cycle one equal to its billing
  period: "monthly, no refill" is saved as "monthly, refills every month".

  ## Why
  For a subscription, "no refill" and "refills once per period" give the user the same
  units, but only the second has a cycle end. Plan switches and period extensions need
  that end, so a plan without one could break them. Filling it in when the plan is saved
  covers the dashboard, the catalog import and code in one place.

  ## How it works
  Only when the kind, the period or the cycle is being set: editing the name of a plan
  that is already sold never touches its terms (`TermsLockedWhenSold`).
  """
  use Ash.Resource.Change

  @terms [:kind, :validity_unit, :validity_count, :cycle_unit, :cycle_count]

  @impl true
  def change(changeset, _opts, _context) do
    if Enum.any?(@terms, &Ash.Changeset.changing_attribute?(changeset, &1)),
      do: fill_cycle(changeset),
      else: changeset
  end

  defp fill_cycle(changeset) do
    get = &Ash.Changeset.get_attribute(changeset, &1)

    case {get.(:kind), get.(:cycle_unit), get.(:validity_unit)} do
      {:recurring, nil, unit} when not is_nil(unit) ->
        Ash.Changeset.force_change_attributes(changeset,
          cycle_unit: unit,
          cycle_count: get.(:validity_count)
        )

      _unchanged ->
        changeset
    end
  end
end

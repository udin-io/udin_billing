defmodule UdinBilling.Validations.CycleWithinPeriod do
  @moduledoc """
  A subscription plan must refill at least once per billing period: "monthly, refills
  every year" would never refill, since each payment starts a new period.

  ## How it works
  Both lengths are laid from the same fixed date and compared, so mixed units compare
  by the calendar (1 month holds 4 weeks, not 5).
  """
  use Ash.Resource.Validation

  @reference ~U[2001-01-01 00:00:00Z]

  @impl true
  def validate(changeset, _opts, _context) do
    get = &Ash.Changeset.get_attribute(changeset, &1)

    with :recurring <- get.(:kind),
         cycle when not is_nil(cycle) <- span(get.(:cycle_unit), get.(:cycle_count)),
         period when not is_nil(period) <- span(get.(:validity_unit), get.(:validity_count)),
         :gt <- DateTime.compare(cycle, period) do
      {:error, field: :cycle_unit, message: "the refill can't be longer than the billing period"}
    else
      _fits -> :ok
    end
  end

  defp span(unit, count) when is_atom(unit) and not is_nil(unit) and is_integer(count),
    do: DateTime.shift(@reference, [{unit, count}])

  defp span(_unit, _count), do: nil
end

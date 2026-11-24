defmodule UdinBilling.Validations.EnoughRemaining do
  @moduledoc "Refuses debiting more units than a limited lot has left (unlimited lots pass)."
  use Ash.Resource.Validation

  @impl true
  def validate(%{data: %{remaining: nil}}, _opts, _context), do: :ok

  def validate(%{data: %{remaining: remaining}} = changeset, _opts, _context) do
    if remaining >= Ash.Changeset.get_argument(changeset, :units),
      do: :ok,
      else: {:error, field: :remaining, message: "not enough units left"}
  end
end

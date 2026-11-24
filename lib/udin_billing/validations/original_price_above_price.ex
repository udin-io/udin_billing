defmodule UdinBilling.Validations.OriginalPriceAbovePrice do
  @moduledoc """
  A sale's original price must be higher than the price (otherwise there's no sale to
  show). Optional: nil means the plan isn't on sale.
  """
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    original = Ash.Changeset.get_attribute(changeset, :original_price)
    price = Ash.Changeset.get_attribute(changeset, :price)

    cond do
      is_nil(original) or is_nil(price) -> :ok
      Decimal.compare(original, price) == :gt -> :ok
      true -> {:error, field: :original_price, message: "must be higher than the price"}
    end
  end
end

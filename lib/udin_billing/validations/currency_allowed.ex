defmodule UdinBilling.Validations.CurrencyAllowed do
  @moduledoc """
  A plan's currency must be one the app configures (`UdinBilling.Config.currencies/0`),
  so a typo or a currency the app can't charge in never reaches buyers.
  """
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    currency = Ash.Changeset.get_attribute(changeset, :currency)
    allowed = UdinBilling.Config.currencies()

    if is_nil(currency) or currency in allowed do
      :ok
    else
      {:error, field: :currency, message: "currency must be one of #{Enum.join(allowed, ", ")}"}
    end
  end
end

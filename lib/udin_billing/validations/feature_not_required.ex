defmodule UdinBilling.Validations.FeatureNotRequired do
  @moduledoc """
  Refuses deleting a feature the app's code depends on
  (`config :udin_billing, required_features: [...]`), so a dashboard click can't break
  the code that spends or checks it.
  """
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    if changeset.data.key in UdinBilling.Config.required_features() do
      {:error, field: :key, message: "the app's code uses this feature, so it can't be deleted"}
    else
      :ok
    end
  end
end

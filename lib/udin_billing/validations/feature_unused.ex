defmodule UdinBilling.Validations.FeatureUnused do
  @moduledoc "Refuses deleting a feature that a plan still sets a value for."
  use Ash.Resource.Validation

  require Ash.Query

  @impl true
  def validate(changeset, _opts, _context) do
    feature_id = changeset.data.id

    UdinBilling.PlanFeature
    |> Ash.Query.filter(feature_id == ^feature_id)
    |> Ash.exists?(authorize?: false)
    |> case do
      false ->
        :ok

      true ->
        {:error,
         field: :key, message: "a plan still uses this feature. Remove it from plans first"}
    end
  end
end

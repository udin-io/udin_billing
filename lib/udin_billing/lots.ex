defmodule UdinBilling.Lots do
  @moduledoc "Revoking a source's lots when its access is withdrawn (refund, plan change)."
  require Ash.Query

  alias UdinBilling.Grant

  @doc """
  Revokes the unrevoked lots of one purchase (`purchase_id: id`) or one subscription
  (`subscription_id: id`), optionally only those whose source key starts with `prefix`.
  """
  @spec revoke(keyword()) :: :ok | {:error, term()}
  def revoke(filter) do
    Grant
    |> Ash.Query.filter(is_nil(revoked_at))
    |> scope(filter)
    |> Ash.bulk_update(:revoke, %{}, strategy: [:atomic], authorize?: false, return_errors?: true)
    |> case do
      %Ash.BulkResult{status: :success} -> :ok
      %Ash.BulkResult{errors: errors} -> {:error, errors}
    end
  end

  defp scope(query, purchase_id: id), do: Ash.Query.filter(query, purchase_id == ^id)
  defp scope(query, subscription_id: id), do: Ash.Query.filter(query, subscription_id == ^id)

  defp scope(query, source_keys: keys), do: Ash.Query.filter(query, source_key in ^keys)
end

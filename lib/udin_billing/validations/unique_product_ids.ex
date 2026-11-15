defmodule UdinBilling.Validations.UniqueProductIds do
  @moduledoc """
  Refuses a store / provider product id that another plan already lists.

  ## Why
  Store messages name the product, and the library finds the plan by that id. Two plans
  with the same id (e.g. an old and a new version of "Basic") would make a renewal land
  on whichever is found first. A new version therefore needs its own store product.
  """
  use Ash.Resource.Validation

  require Ash.Query

  @impl true
  def validate(changeset, _opts, _context) do
    wanted = ids(Ash.Changeset.get_attribute(changeset, :provider_product_ids))

    case taken(wanted, changeset.data.id) do
      [] ->
        :ok

      [{provider, id, code} | _] ->
        {:error,
         field: :provider_product_ids,
         message: "#{provider} product #{id} is already used by plan #{code}"}
    end
  end

  defp taken([], _plan_id), do: []

  defp taken(wanted, plan_id) do
    UdinBilling.Plan
    |> other_plans(plan_id)
    |> Ash.Query.select([:code, :provider_product_ids])
    |> Ash.read!(authorize?: false)
    |> Enum.flat_map(fn plan ->
      Enum.map(ids(plan.provider_product_ids), fn {provider, id} -> {provider, id, plan.code} end)
    end)
    |> Enum.filter(fn {provider, id, _code} -> {provider, id} in wanted end)
  end

  # A new plan has no id yet: every plan is "another" plan.
  defp other_plans(query, nil), do: query
  defp other_plans(query, plan_id), do: Ash.Query.filter(query, id != ^plan_id)

  defp ids(nil), do: []

  defp ids(map) do
    for {provider, value} <- map, id <- List.wrap(value), do: {to_string(provider), id}
  end
end

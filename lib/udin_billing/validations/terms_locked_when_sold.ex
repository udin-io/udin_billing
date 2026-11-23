defmodule UdinBilling.Validations.TermsLockedWhenSold do
  @moduledoc """
  Refuses changing what a plan sells (type, price, currency, periods, features) once it
  has buyers, and removing or replacing its store product ids (adding one, e.g. the same
  plan in another store, stays allowed).

  ## Why
  Buyers keep the terms they paid for either way (terms are copied at purchase), but a
  plan whose price or contents change under the same code makes reports, store products
  and support confusing ("which Weekly did this rider buy?"). The rule is simple: to
  change a sold plan, create a new version and take the old one off sale
  (`UdinBilling.Admin.replace_plan/3`; "Create new version" in the dashboard). Names,
  descriptions, display order, the recommended badge and on/off sale stay editable.

  Product ids matter most: a store keeps renewing existing subscribers with the product id
  they bought. Dropping it from the plan would make their next renewal unknown and cut
  their access while they still pay. A new version takes the old plan off sale (it no
  longer appears) but keeps its ids, so its subscribers keep renewing it until they stop.
  """
  use Ash.Resource.Validation

  @terms [:kind, :price, :currency, :validity_unit, :validity_count, :cycle_unit, :cycle_count]

  @doc "The plan fields that can't change once a plan has buyers (plus its features)."
  @spec terms() :: [atom()]
  def terms, do: @terms

  @impl true
  def validate(changeset, _opts, _context) do
    case changed_terms(changeset) do
      [] ->
        :ok

      changed ->
        if UdinBilling.Plan.sold?(changeset.data.id) do
          {:error,
           field: hd(changed),
           message:
             "this plan has buyers, so #{Enum.join(changed, ", ")} can't change: " <>
               "create a new version and take this one off sale"}
        else
          :ok
        end
    end
  end

  defp changed_terms(changeset) do
    attributes =
      Enum.filter(@terms, fn field ->
        Ash.Changeset.changing_attribute?(changeset, field) and
          not same?(Ash.Changeset.get_attribute(changeset, field), Map.get(changeset.data, field))
      end)

    attributes ++ features_change(changeset) ++ product_ids_change(changeset)
  end

  # Every id the plan had must still be there, under the same provider.
  defp product_ids_change(changeset) do
    if Ash.Changeset.changing_attribute?(changeset, :provider_product_ids) do
      new = Ash.Changeset.get_attribute(changeset, :provider_product_ids) || %{}
      old = changeset.data.provider_product_ids || %{}

      kept? =
        Enum.all?(old, fn {provider, ids} ->
          List.wrap(ids) -- List.wrap(Map.get(new, provider)) == []
        end)

      if kept?, do: [], else: [:provider_product_ids]
    else
      []
    end
  end

  defp features_change(changeset) do
    case Ash.Changeset.fetch_argument(changeset, :features) do
      {:ok, features} when is_map(features) ->
        if included(features) == included(changeset.data.features), do: [], else: [:features]

      _ ->
        []
    end
  end

  # Off switches and zero counters mean "not included"; `:unlimited` is stored as text.
  defp included(values) do
    values
    |> Enum.reject(fn {_key, value} -> value in [false, 0, "false", "0"] end)
    |> Map.new(fn
      {key, :unlimited} -> {to_string(key), "unlimited"}
      {key, value} -> {to_string(key), value}
    end)
  end

  defp same?(%Decimal{} = a, %Decimal{} = b), do: Decimal.equal?(a, b)
  defp same?(a, b), do: a == b
end

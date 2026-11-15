defmodule UdinBilling.Changes.SyncPlanFeatures do
  @moduledoc """
  Writes a plan's `features` argument: checks every key against the feature catalog and
  its kind, replaces the plan's `UdinBilling.PlanFeature` rows, and stores the same values
  in `plan.features` for fast reads, all in the plan's transaction.

  Omitting the argument on update leaves features unchanged. Passing a map replaces them
  all, so a feature left out is off for that plan.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias UdinBilling.{Feature, FeatureValue, PlanFeature}

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.fetch_argument(changeset, :features) do
      {:ok, features} when is_map(features) -> apply_features(changeset, features)
      _ -> changeset
    end
  end

  defp apply_features(changeset, features) do
    raw = Map.new(features, fn {key, value} -> {to_string(key), value} end)
    catalog = Feature.fetch_by_keys(Map.keys(raw))

    case normalize(raw, catalog) do
      {:ok, normalized} ->
        changeset
        |> Ash.Changeset.force_change_attribute(:features, normalized)
        |> Ash.Changeset.after_action(fn _changeset, plan ->
          write_rows(plan, normalized, catalog)
        end)

      {:error, message} ->
        Ash.Changeset.add_error(changeset, field: :features, message: message)
    end
  end

  defp normalize(raw, catalog) do
    Enum.reduce_while(raw, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      with {:ok, feature} <- known(catalog, key),
           {:ok, stored} <- FeatureValue.normalize(feature.kind, value) do
        {:cont, {:ok, Map.put(acc, key, stored)}}
      else
        {:error, message} -> {:halt, {:error, "#{key}: #{message}"}}
      end
    end)
  end

  defp known(catalog, key) do
    case Map.fetch(catalog, key) do
      {:ok, feature} -> {:ok, feature}
      :error -> {:error, "unknown feature; add it to the feature catalog first"}
    end
  end

  defp write_rows(plan, normalized, catalog) do
    plan_id = plan.id

    with %Ash.BulkResult{status: :success} <-
           PlanFeature
           |> Ash.Query.filter(plan_id == ^plan_id)
           |> Ash.bulk_destroy(:destroy, %{}, authorize?: false, return_errors?: true),
         %Ash.BulkResult{status: :success} <-
           Ash.bulk_create(rows(plan_id, normalized, catalog), PlanFeature, :create,
             authorize?: false,
             return_errors?: true
           ) do
      {:ok, plan}
    else
      %Ash.BulkResult{errors: errors} -> {:error, errors}
    end
  end

  defp rows(plan_id, normalized, catalog) do
    for {key, value} <- normalized do
      value
      |> FeatureValue.to_row()
      |> Map.merge(%{plan_id: plan_id, feature_id: Map.fetch!(catalog, key).id})
    end
  end
end

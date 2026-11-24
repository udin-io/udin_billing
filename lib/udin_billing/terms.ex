defmodule UdinBilling.Terms do
  @moduledoc """
  The copy of a plan's terms that a purchase or subscription keeps from the moment it
  starts: price, features, validity and cycle.

  ## Why
  "Editing a plan never changes what a buyer has" needs one definition of what is copied.
  Purchases, subscriptions and access checks all use this module.
  """
  alias UdinBilling.Plan

  @fields [:features, :validity_unit, :validity_count, :cycle_unit, :cycle_count]

  @doc "Attributes to copy from `plan` onto a purchase or subscription."
  @spec from_plan(struct()) :: map()
  def from_plan(%Plan{} = plan) do
    plan
    |> Map.take(@fields)
    |> Map.merge(%{amount: plan.price, currency: plan.currency})
  end

  @doc "The copied fields (without price), for subscriptions which are priced by the store."
  @spec access_terms(struct()) :: map()
  def access_terms(%Plan{} = plan), do: Map.take(plan, @fields)
end

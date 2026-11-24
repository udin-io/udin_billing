defmodule UdinBilling.Domain do
  @moduledoc """
  Ash domain holding every billing resource.

  Apps add `UdinBilling.Domain` to their `:ash_domains` so `mix ash.codegen` generates the
  billing tables in the app's own migrations and repo.
  """
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource UdinBilling.Feature
    resource UdinBilling.Plan
    resource UdinBilling.PlanFeature
    resource UdinBilling.Account
    resource UdinBilling.Purchase
    resource UdinBilling.Subscription
    resource UdinBilling.Grant
    resource UdinBilling.Usage
    resource UdinBilling.ProviderEvent
  end
end

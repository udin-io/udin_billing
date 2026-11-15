defmodule UdinBilling do
  @moduledoc """
  Public API of the shared billing library (Family-Corp, ReelsChef, and future apps).

  ## What it does
  Sells plans and turns them into access:
    * **switches** - on/off features (`share_recipe`, `smart_aggregation`, ...);
    * **counters** - units per cycle (`reel_imports`, `rides`), each user's cycle starting
      on their own date, no carry over.

  Features, plans and their values are data; each app's differences are config (see
  `UdinBilling.Config`). Nothing here is app-specific. A catalog of features and plans can
  be exported and imported between environments (`UdinBilling.Catalog`).

  Everything here runs server-side with authorization bypassed; the app decides who may
  call it.
  """

  @doc "Plans on sale (active, not the default plan), in display order."
  @spec plans_for_sale() :: [struct()]
  def plans_for_sale, do: Ash.read!(UdinBilling.Plan, action: :purchasable, authorize?: false)
end

defmodule UdinBilling.Checks.Admin do
  @moduledoc """
  Policy check that passes when the host's configured `:admin_check` accepts the actor.

  Each host models admins differently (`admin?` flag in ReelsChef, `role` in Family-Corp),
  so the decision is delegated to `UdinBilling.Config.admin?/1`.
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "actor is a billing admin"

  @impl true
  def match?(nil, _context, _opts), do: false
  def match?(actor, _context, _opts), do: UdinBilling.Config.admin?(actor)
end

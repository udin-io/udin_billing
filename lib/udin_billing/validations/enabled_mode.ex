defmodule UdinBilling.Validations.EnabledMode do
  @moduledoc """
  Refuses plans whose `kind` isn't in `config :udin_billing, :modes`: the one-time /
  recurring feature flag.
  """
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    kind = Ash.Changeset.get_attribute(changeset, :kind)

    if is_nil(kind) or UdinBilling.Config.mode_enabled?(kind) do
      :ok
    else
      {:error,
       field: :kind,
       message: "%{kind} plans are disabled, enabled: %{modes}",
       vars: [kind: kind, modes: Enum.map_join(UdinBilling.Config.modes(), ", ", &to_string/1)]}
    end
  end
end

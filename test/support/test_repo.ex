defmodule UdinBilling.TestRepo do
  @moduledoc "Repo used only by this package's own test suite."
  use AshPostgres.Repo, otp_app: :udin_billing

  @impl true
  def installed_extensions, do: ["ash-functions", "uuid-ossp", "citext"]

  @impl true
  def min_pg_version, do: %Version{major: 16, minor: 0, patch: 0}
end

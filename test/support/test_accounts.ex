defmodule UdinBilling.Test.Accounts do
  @moduledoc "Stand-in for a host's accounts domain in the package's tests."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource UdinBilling.Test.User
  end
end

defmodule UdinBilling.Test.User do
  @moduledoc "Stand-in for a host's user resource: UUID primary key and an admin flag."
  use Ash.Resource, domain: UdinBilling.Test.Accounts, data_layer: AshPostgres.DataLayer

  postgres do
    table "users"
    repo UdinBilling.TestRepo
  end

  actions do
    defaults [:read, :destroy, create: [:email, :admin]]
  end

  attributes do
    uuid_primary_key :id
    attribute :email, :string, allow_nil?: false, public?: true
    attribute :admin, :boolean, allow_nil?: false, default: false, public?: true
  end

  @doc "Admin check wired through `config :udin_billing, :admin_check`."
  @spec admin?(term()) :: boolean()
  def admin?(%{admin: true}), do: true
  def admin?(_), do: false

  @doc """
  The admin's language for tests, wired through `config :udin_billing, :admin_locale` in
  the tests that need it: an email ending `@ar.example.com` means Arabic.
  """
  @spec locale(term()) :: String.t() | nil
  def locale(%{email: email}) when is_binary(email) do
    if String.ends_with?(email, "@ar.example.com"), do: "ar"
  end

  def locale(_actor), do: nil
end

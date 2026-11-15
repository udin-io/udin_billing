# Library-local config: used only when running this package's own dev/test.
# Host applications configure :udin_billing in their own config files.
import Config

config :udin_billing,
  ecto_repos: [UdinBilling.TestRepo],
  ash_domains: [UdinBilling.Domain, UdinBilling.Test.Accounts],
  repo: UdinBilling.TestRepo,
  user_resource: UdinBilling.Test.User,
  admin_check: {UdinBilling.Test.User, :admin?},
  # Plan kinds allowed, any of :free, :one_time, :recurring (default [:free, :one_time])
  modes: [:free, :one_time, :recurring],
  default_currency: "EGP",
  locales: ["en", "ar"]

config :udin_billing, UdinBilling.TestRepo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "udin_billing_#{config_env()}#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :ash, :disable_async?, true

# Required from Ash 3.3x on (each app sets it too); older Ash ignores it.
config :ash, default_string_length_count: :codepoints
config :logger, level: :warning

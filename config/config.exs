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
  # :stack (default) buy while a plan is active, each purchase keeps its own expiry
  # :single_active one active one-time purchase at a time
  purchase_policy: :stack,
  # Mid-cycle plan switch:
  # :fresh (default) new plan's full counters
  # :shift new plan's counters minus this cycle's use
  upgrade_policy: :fresh,
  default_currency: "EGP",
  locales: ["en", "ar"],
  # Accept store sandbox purchases, true or false (default). Never true in production
  allow_sandbox: false,
  providers: %{
    "fake" => {UdinBilling.Providers.Fake, secret: "a-long-test-secret-value"},
    # Paymob talking to a stub server (UdinBilling.Test.PaymobStub): wallet configured,
    # card only enabled, like production today.
    "paymob" =>
      {UdinBilling.Providers.Paymob,
       secret_key: "test_secret_key",
       public_key: "test_public_key",
       hmac_secret: "test-hmac-secret",
       integrations: %{card: 4_097_558, wallet: 4_097_559},
       enabled_methods: [:card],
       notification_url: "https://app.example/billing/webhooks/paymob",
       redirection_url: "https://app.example/billing/return",
       http_client: UdinBilling.Test.PaymobStub},
    # RevenueCat talking to a Req.Test stub (UdinBilling.Test.RevenueCatStub).
    "revenuecat" =>
      {UdinBilling.Providers.RevenueCat,
       api_key: "sk_test_key",
       webhook_auth: "Bearer a-long-webhook-secret",
       req_options: [plug: {Req.Test, UdinBilling.Test.RevenueCatStub}, retry: false]}
  }

config :udin_billing, UdinBilling.TestRepo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "udin_billing_#{config_env()}#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

# The dashboard's test host (test/support/web.ex).
config :udin_billing, UdinBilling.Test.Web.Endpoint,
  url: [host: "localhost"],
  secret_key_base: String.duplicate("udin-billing-test-secret-", 4),
  live_view: [signing_salt: "udin-billing-lv"],
  render_errors: [formats: [html: UdinBilling.Test.Web.ErrorHTML]],
  server: false

config :phoenix, :json_library, Jason

config :ash, :disable_async?, true

# Required from Ash 3.3x on (each app sets it too); older Ash ignores it.
config :ash, default_string_length_count: :codepoints
config :logger, level: :warning

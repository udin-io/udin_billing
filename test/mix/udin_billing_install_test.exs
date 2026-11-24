defmodule Mix.Tasks.UdinBilling.InstallTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  @args [
    "--repo",
    "Test.Repo",
    "--user",
    "Test.Accounts.User",
    "--admin-check",
    "Test.Accounts.billing_admin?",
    "--modes",
    "free,one_time,recurring",
    "--locales",
    "en,ar"
  ]

  test "configures the library and registers the domain" do
    test_project()
    |> Igniter.compose_task("udin_billing.install", @args)
    |> assert_creates("config/config.exs", """
    import Config

    config :test, ash_domains: [UdinBilling.Domain]

    config :udin_billing,
      repo: Test.Repo,
      user_resource: Test.Accounts.User,
      modes: [:free, :one_time, :recurring],
      purchase_policy: :stack,
      upgrade_policy: :fresh,
      default_currency: "EGP",
      locales: ["en", "ar"],
      admin_check: {Test.Accounts, :billing_admin?}
    """)
  end

  test "keeps existing settings and domains when run again" do
    test_project(
      files: %{
        "config/config.exs" => """
        import Config
        config :test, ash_domains: [Test.Accounts]
        config :udin_billing, modes: [:free], purchase_policy: :single_active
        """
      }
    )
    |> Igniter.compose_task("udin_billing.install", @args)
    |> assert_has_patch("config/config.exs", """
    + |config :test, ash_domains: [Test.Accounts, UdinBilling.Domain]
    """)
    |> then(fn igniter ->
      config =
        igniter.rewrite |> Rewrite.source!("config/config.exs") |> Rewrite.Source.get(:content)

      assert config =~ "modes: [:free]"
      assert config =~ "purchase_policy: :single_active"
      refute config =~ ":recurring"
    end)
  end

  test "rejects a language code that isn't a short lowercase code" do
    assert_raise Mix.Error, ~r/locale/, fn ->
      Igniter.compose_task(test_project(), "udin_billing.install", [
        "--repo",
        "Test.Repo",
        "--locales",
        "en,Arabic"
      ])
    end
  end

  test "rejects unknown modes" do
    assert_raise Mix.Error, ~r/unknown mode/, fn ->
      Igniter.compose_task(test_project(), "udin_billing.install", [
        "--repo",
        "Test.Repo",
        "--modes",
        "monthly"
      ])
    end
  end
end

defmodule UdinBilling.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :udin_billing,
      version: @version,
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      consolidate_protocols: Mix.env() != :test,
      # Keeps the .po files free of line numbers, so moving code doesn't churn them.
      gettext: [write_reference_line_numbers: false]
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto]]
  end

  defp elixirc_paths(env) when env in [:dev, :test], do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:gettext, "~> 1.0"},
      {:ash, "~> 3.12"},
      {:ash_postgres, "~> 2.6"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.0"},
      {:plug, "~> 1.16"},
      {:ex_paymob, "~> 0.1.1"},
      {:req, "~> 0.5"},
      {:igniter, "~> 0.7", optional: true},
      # Admin dashboard (UdinBilling.Web): only needed by apps that mount it.
      {:phoenix, "~> 1.7", optional: true},
      {:phoenix_live_view, "~> 1.0", optional: true},
      {:phoenix_html, "~> 4.0", optional: true},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:picosat_elixir, "~> 0.2", only: [:dev, :test]}
    ]
  end

  defp aliases do
    [
      test: ["ash.setup --quiet", "test"]
    ]
  end
end

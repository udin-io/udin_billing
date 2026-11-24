defmodule Mix.Tasks.UdinBilling.Catalog.Export do
  @shortdoc "Writes the billing features and plans to priv/billing/catalog.json"

  @moduledoc """
  #{@shortdoc}.

  Run it where the setup is right (locally or on staging), commit the file, and import it
  elsewhere with `mix udin_billing.catalog.import`. See `UdinBilling.Catalog`.

  ## Options
    * `--out PATH` - where to write (default `priv/billing/catalog.json`).
    * `--features-only` - leave plans out: for apps where admins manage plans in each
      environment (importing the file then never touches plans).
    * `--dry-run` - print the catalog instead of writing the file.
  """
  use Mix.Task

  @switches [out: :string, dry_run: :boolean, features_only: :boolean]

  @impl Mix.Task
  def run(argv) do
    {opts, _args} = OptionParser.parse!(argv, strict: @switches)
    Mix.Task.run("app.start")

    path = opts[:out] || UdinBilling.Catalog.default_path()
    export_opts = if opts[:features_only], do: [only: :features], else: []
    catalog = UdinBilling.Catalog.export(export_opts)
    summary = "#{length(catalog["features"])} features, #{plan_count(catalog)}"

    if opts[:dry_run] do
      Mix.shell().info(UdinBilling.Catalog.encode(catalog))
      Mix.shell().info("Dry run: #{summary}; nothing written.")
    else
      case UdinBilling.Catalog.export_file(path, export_opts) do
        :ok -> Mix.shell().info("Wrote #{path}: #{summary}.")
        {:error, reason} -> Mix.raise("can't write #{path}: #{:file.format_error(reason)}")
      end
    end
  end

  defp plan_count(%{"plans" => plans}), do: "#{length(plans)} plans"
  defp plan_count(_catalog), do: "no plans (features only)"
end

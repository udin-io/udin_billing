defmodule Mix.Tasks.UdinBilling.Catalog.Import do
  @shortdoc "Applies priv/billing/catalog.json to the database (features and plans)"

  @moduledoc """
  #{@shortdoc}.

  Creates and updates features (by key) and plans (by code) in one transaction; never
  deletes. Run with `--dry-run` first to see the changes. See `UdinBilling.Catalog`.

  ## Options
    * `--file PATH` - the catalog to read (default `priv/billing/catalog.json`).
    * `--dry-run` - only show what would change.
    * `--deactivate-missing` - take plans that aren't in the file off sale.
  """
  use Mix.Task

  @switches [file: :string, dry_run: :boolean, deactivate_missing: :boolean]

  @impl Mix.Task
  def run(argv) do
    {opts, _args} = OptionParser.parse!(argv, strict: @switches)
    Mix.Task.run("app.start")

    path = opts[:file] || UdinBilling.Catalog.default_path()

    case UdinBilling.Catalog.import_file(
           path,
           Keyword.take(opts, [:dry_run, :deactivate_missing])
         ) do
      {:ok, changes} ->
        report(changes, opts[:dry_run] == true)

      {:error, reasons} when is_list(reasons) ->
        Mix.raise("catalog not imported:\n  " <> Enum.join(reasons, "\n  "))

      {:error, error} ->
        Mix.raise("catalog not imported: #{inspect(error)}")
    end
  end

  defp report(changes, dry_run?) do
    case UdinBilling.Catalog.describe(changes) do
      [] -> Mix.shell().info("The database already matches the catalog.")
      lines -> Enum.each(lines, &Mix.shell().info/1)
    end

    if dry_run?, do: Mix.shell().info("Dry run: nothing changed.")
  end
end

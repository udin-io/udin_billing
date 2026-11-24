if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.UdinBilling.Install do
    @example "mix udin_billing.install --user MyApp.Accounts.User --admin-check MyApp.Accounts.billing_admin?"

    @shortdoc "Sets up UdinBilling in a Phoenix/Ash app"

    @moduledoc """
    #{@shortdoc}

    Adds the billing config, registers `UdinBilling.Domain` in `:ash_domains`, and prints
    the remaining steps (webhook route, migrations, admin check, catalog).

    Run it again any time: settings already present are kept.

    ## Example

    ```bash
    #{@example}
    ```

    ## Options

      * `--user` - the app's user resource (UUID primary key). Default `<App>.Accounts.User`.
      * `--repo` - the app's repo. Default: the only repo, or asks.
      * `--admin-check` - `Module.function` returning true for admins (called with the actor).
      * `--modes` - comma-separated plan kinds: `free,one_time,recurring`. Default `free,one_time`.
      * `--locales` - comma-separated languages of the texts users see, default first:
        `en,ar`. Default `en`.
    """
    use Igniter.Mix.Task

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :udin_billing,
        example: @example,
        schema: [
          user: :string,
          repo: :string,
          admin_check: :string,
          modes: :string,
          locales: :string
        ],
        defaults: [modes: "free,one_time", locales: "en"]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      app = Igniter.Project.Application.app_name(igniter)
      opts = igniter.args.options
      {igniter, repo} = repo(igniter, opts[:repo])
      user = module(opts[:user]) || Igniter.Project.Module.module_name(igniter, "Accounts.User")

      igniter
      |> configure(app, [:udin_billing, :repo], repo)
      |> configure(app, [:udin_billing, :user_resource], user)
      |> configure(app, [:udin_billing, :modes], modes(opts[:modes]))
      |> configure(app, [:udin_billing, :purchase_policy], :stack)
      |> configure(app, [:udin_billing, :upgrade_policy], :fresh)
      |> configure(app, [:udin_billing, :default_currency], "EGP")
      |> configure(app, [:udin_billing, :locales], locales(opts[:locales]))
      |> admin_check(opts[:admin_check])
      |> register_domain(app)
      |> Igniter.add_notice(next_steps(app))
    end

    defp configure(igniter, _app, [:udin_billing, _key], nil), do: igniter

    defp configure(igniter, _app, [:udin_billing, key], value) do
      # Existing values win: re-running the installer never overwrites a decision.
      Igniter.Project.Config.configure(igniter, "config.exs", :udin_billing, [key], value,
        updater: fn zipper -> {:ok, zipper} end
      )
    end

    defp admin_check(igniter, nil), do: igniter

    defp admin_check(igniter, mf) do
      case String.split(mf, ".") |> Enum.split(-1) do
        {[_ | _] = module_parts, [function]} ->
          configure(
            igniter,
            nil,
            [:udin_billing, :admin_check],
            {Module.concat(module_parts), String.to_atom(function)}
          )

        _ ->
          Igniter.add_issue(igniter, "--admin-check must look like MyApp.Accounts.billing_admin?")
      end
    end

    defp register_domain(igniter, app) do
      Igniter.Project.Config.configure(
        igniter,
        "config.exs",
        app,
        [:ash_domains],
        [UdinBilling.Domain],
        updater: &Igniter.Code.List.append_new_to_list(&1, UdinBilling.Domain)
      )
    end

    defp repo(igniter, nil), do: Igniter.Libs.Ecto.select_repo(igniter)
    defp repo(igniter, name), do: {igniter, module(name)}

    defp module(nil), do: nil
    defp module(name), do: Module.concat([name])

    defp modes(list) do
      list
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.map(fn
        "free" -> :free
        "one_time" -> :one_time
        "recurring" -> :recurring
        other -> Mix.raise("unknown mode #{inspect(other)}; use free, one_time, recurring")
      end)
    end

    # Short lowercase codes ("en", "ar", "pt-br"), as stored in plan and feature texts.
    defp locales(list) do
      list
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.map(fn locale ->
        if locale =~ ~r/^[a-z]{2,3}(-[a-z0-9]{2,8})?$/,
          do: locale,
          else: Mix.raise("invalid locale #{inspect(locale)}; use codes like en,ar")
      end)
    end

    defp next_steps(app) do
      """
      UdinBilling is configured. Next:

      1. Generate and run the billing migrations:
           mix ash.codegen add_billing && mix ash.migrate

      2. Make sure `:admin_check` points to a function returning true for admins.

      3. Payment providers go in runtime.exs (secrets from env), e.g.
           config :udin_billing, :providers, %{"paymob" => {Adapter, secret_key: System.fetch_env!("...")}}
         and their webhook routes in the router, outside session/CSRF pipelines:
           forward "/billing/webhooks/paymob", UdinBilling.WebhookPlug, provider: "paymob"

      4. Create the feature catalog and plans (admin screen or seeds):
           UdinBilling.Admin.create_feature(%{key: "share_recipe", kind: :switch}, admin)
           UdinBilling.Admin.create_plan(%{code: "free", kind: :free, is_default: true, ...}, admin)

      5. Optional: call UdinBilling.ensure_account(user.id) at signup to start free-plan
         cycles on the signup date, and schedule UdinBilling.Purchases.cancel_stale/0 hourly.

      App: #{inspect(app)}. Full guide: billing/README.md.
      """
    end
  end
else
  defmodule Mix.Tasks.UdinBilling.Install do
    @shortdoc "Sets up UdinBilling in a Phoenix/Ash app (requires igniter)"
    @moduledoc "#{@shortdoc}. Add `{:igniter, \"~> 0.7\"}` to your deps to use it."
    use Mix.Task

    @impl Mix.Task
    def run(_argv) do
      Mix.raise("mix udin_billing.install needs igniter: add {:igniter, \"~> 0.7\"} to your deps")
    end
  end
end

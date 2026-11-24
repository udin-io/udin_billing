if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule UdinBilling.Web.Router do
    @moduledoc """
    Mounts the billing dashboard in a host app's router.

    ## Usage
        # router.ex
        import UdinBilling.Web.Router

        scope "/admin" do
          pipe_through [:browser, :require_admin]

          udin_billing_dashboard "/billing",
            on_mount: [{MyAppWeb.UserAuth, :mount_current_user}]
        end

    ## Options
      * `:on_mount` - the host's hooks that put the signed-in user in assigns. They run
        first; the dashboard's own admin check (`config :udin_billing, :admin_check`) runs
        after them on every mount, so a page is never shown to a non-admin even if the
        pipeline forgets to check.
      * `:actor` - the assign holding the signed-in user (default `:current_user`;
        `:current_scope` style apps can pass a hook that assigns the user under a key).
      * `:unauthorized_redirect` - where non-admins go (default `"/"`).
      * `:as` - the live session name (default `:udin_billing`), to mount it twice.
      * `:root_layout` / `:layout` - passed to `live_session` when the host wants its own
        chrome around the dashboard. The dashboard brings its own scoped styles either way.
      * `:session` - passed to `live_session`. Apps on AshAuthentication pass the result of
        `AshAuthentication.Phoenix.LiveSession.opts/1`, which supplies `:on_mount` and
        `:session` together:

            udin_billing_dashboard "/billing",
              AshAuthentication.Phoenix.LiveSession.opts(
                on_mount: [{MyAppWeb.LiveUserAuth, :live_user_required}]
              )

    ## Pages
    `/` plans, `/plans/new`, `/plans/:id/edit`, `/features`, `/features/new`,
    `/features/:id/edit`, `/users`, `/webhooks`, `/catalog`.
    """

    @doc "Defines the dashboard's routes under `path`. See the module docs for options."
    defmacro udin_billing_dashboard(path, opts \\ []) do
      quote bind_quoted: [path: path, opts: opts] do
        base = Phoenix.Router.scoped_path(__MODULE__, path)
        {session_name, session_opts} = UdinBilling.Web.Router.__session__(base, opts)

        scope path, alias: false, as: false do
          import Phoenix.LiveView.Router, only: [live: 4, live_session: 3]

          live_session session_name, session_opts do
            live("/", UdinBilling.Web.PlansLive, :index, as: :udin_billing_plans)
            live("/plans/new", UdinBilling.Web.PlanFormLive, :new, as: :udin_billing_plan_new)

            live("/plans/:id/edit", UdinBilling.Web.PlanFormLive, :edit,
              as: :udin_billing_plan_edit
            )

            live("/features", UdinBilling.Web.FeaturesLive, :index, as: :udin_billing_features)

            live("/features/new", UdinBilling.Web.FeaturesLive, :new,
              as: :udin_billing_feature_new
            )

            live("/features/:id/edit", UdinBilling.Web.FeaturesLive, :edit,
              as: :udin_billing_feature_edit
            )

            live("/users", UdinBilling.Web.UsersLive, :index, as: :udin_billing_users)
            live("/payments", UdinBilling.Web.PaymentsLive, :index, as: :udin_billing_payments)
            live("/webhooks", UdinBilling.Web.WebhooksLive, :index, as: :udin_billing_webhooks)
            live("/catalog", UdinBilling.Web.CatalogLive, :index, as: :udin_billing_catalog)
          end
        end
      end
    end

    @doc false
    @spec __session__(String.t(), keyword()) :: {atom(), keyword()}
    def __session__(base, opts) do
      auth =
        {UdinBilling.Web.Auth,
         %{
           actor: Keyword.get(opts, :actor, :current_user),
           base: base,
           unauthorized_redirect: Keyword.get(opts, :unauthorized_redirect, "/")
         }}

      session_opts =
        opts
        |> Keyword.take([:root_layout, :layout, :session])
        |> Keyword.put(:on_mount, List.wrap(opts[:on_mount]) ++ [auth])

      {Keyword.get(opts, :as, :udin_billing), session_opts}
    end
  end
end

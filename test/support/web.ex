defmodule UdinBilling.Test.Web do
  @moduledoc """
  A minimal host app for the dashboard's tests: an endpoint and a router that mount
  `UdinBilling.Web` the way Family-Corp and ReelsChef do, behind a "current user" hook.
  """

  defmodule Hooks do
    @moduledoc "Stand-in for a host's auth hook: puts the session's user in `:current_user`."
    import Phoenix.Component, only: [assign: 3]

    @doc "Assigns the user whose id is in the session, or nil."
    def on_mount(:current_user, _params, session, socket) do
      user =
        case session["user_id"] do
          nil -> nil
          id -> Ash.get!(UdinBilling.Test.User, id, authorize?: false)
        end

      {:cont, assign(socket, :current_user, user)}
    end
  end

  defmodule ErrorHTML do
    @moduledoc false
    def render(template, _assigns), do: Phoenix.Controller.status_message_from_template(template)
  end

  defmodule Router do
    @moduledoc false
    use Phoenix.Router
    import Phoenix.LiveView.Router
    import UdinBilling.Web.Router

    pipeline :browser do
      plug :fetch_session
      plug :fetch_live_flash
    end

    scope "/admin" do
      pipe_through :browser

      udin_billing_dashboard("/billing",
        on_mount: [{UdinBilling.Test.Web.Hooks, :current_user}],
        unauthorized_redirect: "/login"
      )
    end
  end

  defmodule Endpoint do
    @moduledoc false
    use Phoenix.Endpoint, otp_app: :udin_billing

    @session_options [store: :cookie, key: "_udin_billing_test", signing_salt: "ubtest01"]

    socket "/live", Phoenix.LiveView.Socket,
      websocket: [connect_info: [session: @session_options]]

    plug Plug.Session, @session_options
    plug UdinBilling.Test.Web.Router
  end
end

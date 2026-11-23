defmodule UdinBilling.ConnCase do
  @moduledoc """
  Test case for the dashboard: `UdinBilling.DataCase` plus LiveView testing against
  `UdinBilling.Test.Web.Endpoint`, and helpers to sign in as an admin or a regular user.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      use UdinBilling.DataCase, async: false

      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import UdinBilling.ConnCase

      @endpoint UdinBilling.Test.Web.Endpoint
    end
  end

  @doc "A connection signed in as `user`."
  @spec log_in(Plug.Conn.t(), struct()) :: Plug.Conn.t()
  def log_in(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  @doc "A connection signed in as a new admin."
  @spec admin_conn() :: Plug.Conn.t()
  def admin_conn,
    do: log_in(Phoenix.ConnTest.build_conn(), UdinBilling.DataCase.user_fixture(%{admin: true}))
end

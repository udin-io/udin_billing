defmodule UdinBilling.Web.DashboardAccessTest do
  use UdinBilling.ConnCase

  @pages ~w(/ /plans/new /features /features/new /users /webhooks)

  test "admins can open every page" do
    conn = admin_conn()
    plan = plan_fixture()

    for page <- @pages ++ ["/plans/#{plan.id}/edit"] do
      assert {:ok, _view, _html} = live(conn, "/admin/billing" <> page), page
    end
  end

  test "signed-in users who aren't admins are sent away from every page" do
    conn = log_in(build_conn(), user_fixture())

    for page <- @pages do
      assert {:error, {:redirect, %{to: "/login", flash: flash}}} =
               live(conn, "/admin/billing" <> page)

      assert flash["error"] =~ "access"
    end
  end

  test "anonymous visitors are sent away" do
    assert {:error, {:redirect, %{to: "/login"}}} = live(build_conn(), "/admin/billing")
  end

  test "an unknown plan id goes back to the plans list" do
    assert {:error, {:live_redirect, %{to: "/admin/billing?lang=en"}}} =
             live(admin_conn(), "/admin/billing/plans/#{Ecto.UUID.generate()}/edit")
  end

  test "the host's live session settings pass through (e.g. AshAuthentication's session)" do
    session = {AshAuthentication.Phoenix.LiveSession, :generate_session, [:my_app, []]}
    hook = {MyAppWeb.LiveUserAuth, :live_user_required}

    {name, opts} =
      UdinBilling.Web.Router.__session__("/billing",
        on_mount: [hook],
        session: session,
        as: :billing
      )

    assert name == :billing
    assert opts[:session] == session
    assert [^hook, {UdinBilling.Web.Auth, %{base: "/billing"}}] = opts[:on_mount]
  end

  test "the dashboard stays left to right inside a right-to-left app; Arabic fields stay right to left" do
    {:ok, view, _html} = live(admin_conn(), "/admin/billing/plans/new")

    assert has_element?(view, ~s(.ub[dir="ltr"][lang="en"]))
    assert has_element?(view, ~s(#plan-name-ar[dir="rtl"]))
  end

  test "when the app turns the dashboard off, even admins are sent away" do
    with_env(:dashboard, false, fn ->
      assert {:error, {:redirect, %{to: "/login", flash: flash}}} =
               live(admin_conn(), "/admin/billing")

      assert flash["error"] =~ "turned off"
    end)
  end
end

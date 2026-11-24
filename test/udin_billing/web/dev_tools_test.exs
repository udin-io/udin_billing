defmodule UdinBilling.Web.DevToolsTest do
  @moduledoc """
  The `developer_tools` switch: when on (default), the dashboard shows the developer pages
  (Features, Catalog, Webhooks) and "Give a plan"; when off, admins see only Plans and
  Users, so they manage bundles and view credits without touching developer tools.
  """
  use UdinBilling.ConnCase

  defp tools_off(fun), do: with_env(:developer_tools, false, fun)

  test "on by default: every page and tab is there" do
    conn = admin_conn()
    {:ok, view, _html} = live(conn, "/admin/billing")

    for tab <- ~w(Plans Features Users Webhooks Catalog),
        do: assert(has_element?(view, ".ub-nav a", tab), tab)

    assert {:ok, _view, _html} = live(conn, "/admin/billing/catalog")
  end

  test "off: admins see Plans and Users only" do
    tools_off(fn ->
      {:ok, view, _html} = live(admin_conn(), "/admin/billing")

      assert has_element?(view, ".ub-nav a", "Plans")
      assert has_element?(view, ".ub-nav a", "Users")
      refute has_element?(view, ".ub-nav a", "Features")
      refute has_element?(view, ".ub-nav a", "Catalog")
      refute has_element?(view, ".ub-nav a", "Webhooks")
    end)
  end

  test "off: developer pages send admins back to the plans" do
    tools_off(fn ->
      for page <- ~w(/features /features/new /catalog /webhooks) do
        assert {:error, {:live_redirect, %{to: "/admin/billing", flash: flash}}} =
                 live(admin_conn(), "/admin/billing" <> page),
               page

        assert flash["error"] =~ "turned off"
      end
    end)
  end

  test "off: admins still create and edit bundles" do
    tools_off(fn ->
      {:ok, view, _html} = live(admin_conn(), "/admin/billing/plans/new")
      refute has_element?(view, "a", "Manage features")

      view
      |> form("#plan-form", plan: %{features: %{rides: %{mode: "limited"}}})
      |> render_change()

      view
      |> form("#plan-form",
        plan: %{
          code: "daily",
          name: %{en: "Daily", ar: "يومي"},
          price: "40",
          validity_count: "1",
          validity_unit: "day",
          features: %{rides: %{mode: "limited", limit: "2"}}
        }
      )
      |> render_submit()

      assert_redirect(view, "/admin/billing?lang=en")
    end)
  end

  test "off: admins see riders' credits but can't give a plan" do
    tools_off(fn ->
      plan_fixture()
      user = user_fixture()
      {:ok, view, _html} = live(admin_conn(), "/admin/billing/users?user_id=#{user.id}")

      assert has_element?(view, "#user-counters")
      refute has_element?(view, "#gift-form")
    end)
  end
end

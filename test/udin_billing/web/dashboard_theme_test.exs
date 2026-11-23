defmodule UdinBilling.Web.DashboardThemeTest do
  @moduledoc """
  `:dashboard_theme` lets a host app pin the dashboard to light or dark, so it matches the
  app's own pages instead of following the operating system's setting.
  """
  use UdinBilling.ConnCase

  alias UdinBilling.Config

  test "by default the dashboard follows the system setting" do
    {:ok, view, _html} = live(admin_conn(), "/admin/billing")

    assert Config.dashboard_theme() == :system
    refute has_element?(view, ".ub[data-ub-theme]")
  end

  test "a light theme marks every page light" do
    with_env(:dashboard_theme, :light, fn ->
      {:ok, view, _html} = live(admin_conn(), "/admin/billing/payments")
      assert has_element?(view, ~s(.ub[data-ub-theme="light"]))
    end)
  end

  test "a dark theme marks every page dark" do
    with_env(:dashboard_theme, :dark, fn ->
      {:ok, view, _html} = live(admin_conn(), "/admin/billing")
      assert has_element?(view, ~s(.ub[data-ub-theme="dark"]))
    end)
  end

  test "an unknown theme fails loudly" do
    with_env(:dashboard_theme, :sepia, fn ->
      assert_raise ArgumentError, ~r/dashboard_theme/, fn -> Config.dashboard_theme() end
    end)
  end
end

defmodule UdinBilling.Web.DashboardLanguageTest do
  @moduledoc """
  The dashboard's own language: the admin's own locale first, `?lang=` to switch, the
  app's default otherwise. Separate from the plan preview language.
  """
  use UdinBilling.ConnCase

  alias UdinBilling.Config

  @arabic_admin "admin@ar.example.com"

  setup do
    %{conn: admin_conn()}
  end

  defp arabic_admin_conn,
    do: log_in(build_conn(), user_fixture(%{admin: true, email: @arabic_admin}))

  defp with_admin_locale(fun), do: with_env(:admin_locale, {UdinBilling.Test.User, :locale}, fun)

  test "English is the default", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/admin/billing/users")

    assert has_element?(view, ".ub[dir=ltr][lang=en]")
    assert has_element?(view, "nav a", "Plans")
  end

  test "?lang=ar shows the whole shell in Arabic, right to left", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/admin/billing/users?lang=ar")

    assert has_element?(view, ".ub[dir=rtl][lang=ar]")
    assert has_element?(view, "nav a", "الباقات")
    refute has_element?(view, "nav a", "Plans")
  end

  test "an unknown language falls back to the default", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/admin/billing/users?lang=zz")
    assert has_element?(view, ".ub[lang=en]")
  end

  describe "the admin's own locale" do
    test "is used when the page doesn't ask for a language" do
      with_admin_locale(fn ->
        {:ok, view, _html} = live(arabic_admin_conn(), "/admin/billing/users")

        assert has_element?(view, ".ub[dir=rtl][lang=ar]")
        assert has_element?(view, "nav a", "الباقات")
      end)
    end

    test "gives way to ?lang= so an admin can still switch" do
      with_admin_locale(fn ->
        {:ok, view, _html} = live(arabic_admin_conn(), "/admin/billing/users?lang=en")
        assert has_element?(view, ".ub[lang=en]")
      end)
    end

    test "a locale the app doesn't offer falls back to the default" do
      with_admin_locale(fn ->
        with_env(:locales, ["en"], fn ->
          {:ok, view, _html} = live(arabic_admin_conn(), "/admin/billing/users")
          assert has_element?(view, ".ub[lang=en]")
        end)
      end)
    end

    test "defaults to the user's own locale field when the app sets no hook" do
      assert Config.admin_locale(%{locale: :ar}) == "ar"
      assert Config.admin_locale(%{locale: "en"}) == "en"
      assert Config.admin_locale(%{locale: :fr}) == nil
      assert Config.admin_locale(%{}) == nil
      assert Config.admin_locale(nil) == nil
    end

    test "even the message for someone who can't open the dashboard uses it" do
      conn = log_in(build_conn(), user_fixture(%{email: "rider@ar.example.com"}))

      with_admin_locale(fn ->
        assert {:error, {:redirect, %{flash: flash}}} = live(conn, "/admin/billing/users")
        assert flash["error"] =~ ~r/[\x{0600}-\x{06FF}]/u
      end)
    end
  end

  describe "switching the language is for this visit only" do
    # The first, connected mount removes `?lang=` from the address with a patch that the
    # browser applies as it joins (the test client doesn't report that one). Every later
    # patch carrying `lang` is reported, so those are tested here.

    test "the page remembers the choice, and the address goes back to clean", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/billing/users")
      assert has_element?(view, ".ub[lang=en]")

      render_patch(view, "/admin/billing/users?lang=ar")

      assert_patch(view, "/admin/billing/users")
      assert has_element?(view, ".ub[lang=ar]")

      # The clean address the browser now shows keeps the choice for this visit.
      render_patch(view, "/admin/billing/users")
      assert has_element?(view, ".ub[lang=ar]")
    end

    test "a choice over the admin's own language works the same way" do
      with_admin_locale(fn ->
        {:ok, view, _html} = live(arabic_admin_conn(), "/admin/billing/users")
        assert has_element?(view, ".ub[lang=ar]")

        render_patch(view, "/admin/billing/users?lang=en")

        assert_patch(view, "/admin/billing/users")
        assert has_element?(view, ".ub[lang=en]")
      end)
    end

    test "the other things in the address are kept", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/billing")

      render_patch(view, "/admin/billing?view=cards&lang=ar")

      assert_patch(view, "/admin/billing?view=cards")
    end

    test "opening or reloading the address is the user's own language again" do
      with_admin_locale(fn ->
        conn = arabic_admin_conn()

        {:ok, chosen, _html} = live(conn, "/admin/billing/users?lang=en")
        assert has_element?(chosen, ".ub[lang=en]")

        {:ok, reloaded, _html} = live(conn, "/admin/billing/users")
        assert has_element?(reloaded, ".ub[lang=ar]")
      end)
    end

    test "the menu carries the choice to the next page", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/billing/users?lang=ar")

      assert {:error, {:live_redirect, %{to: to}}} =
               view |> element("nav a", "المدفوعات") |> render_click()

      assert to =~ "/payments"
      assert to =~ "lang=ar"

      {:ok, payments, _html} = live(conn, to)
      assert has_element?(payments, ".ub[lang=ar]")
    end

    test "an unknown language is ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/billing/users?lang=zz")
      assert has_element?(view, ".ub[lang=en]")
    end
  end

  test "the language switch is on every page and keeps where you are", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/admin/billing/users")

    assert has_element?(view, "#ub-lang-switch a", "العربية")
    assert has_element?(view, "#ub-lang-switch a[href*='/users'][href*='lang=ar']")
  end

  test "the Arabic page keeps Arabic when moving to another page", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/admin/billing/users?lang=ar")

    assert has_element?(view, "nav a[href*='lang=ar']")
    assert has_element?(view, "#ub-lang-switch a[href*='lang=en']", "English")
  end

  test "switching language reloads the page, so every text changes", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/admin/billing/users")

    # A normal link, not a live patch: texts are translated when the page mounts.
    refute has_element?(view, "#ub-lang-switch a[data-phx-link]")

    {:ok, arabic, _html} = live(conn, "/admin/billing/users?lang=ar")
    assert has_element?(arabic, ".ub[lang=ar]")
    assert has_element?(arabic, "nav a", "الباقات")
  end
end

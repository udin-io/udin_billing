defmodule UdinBilling.Web.UsersLiveTest do
  use UdinBilling.ConnCase

  setup do
    %{conn: admin_conn()}
  end

  test "shows a user's counters, switches and what grants them", %{conn: conn} do
    user = user_fixture()
    plan = plan_fixture(%{features: %{"rides" => 10, "share_recipe" => true}})
    {:ok, _} = UdinBilling.Purchases.record_paid(user.id, plan.id, "fake", "ref-1")

    {:ok, view, _html} = live(conn, "/admin/billing/users?user_id=#{user.id}")

    assert has_element?(view, "#user-counters tr", "10")
    assert has_element?(view, ".ub-badge", "share_recipe")
    assert has_element?(view, "#user-sources", "Weekly")
  end

  test "the lookup form opens the user", %{conn: conn} do
    user = user_fixture()
    {:ok, view, _html} = live(conn, "/admin/billing/users")

    view |> form("#user-lookup", user_id: " #{user.id} ") |> render_submit()
    assert_patch(view, "/admin/billing/users?user_id=#{user.id}")
    assert has_element?(view, "#user-counters")
  end

  test "an invalid id is explained", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/admin/billing/users?user_id=not-a-uuid")
    assert html =~ "valid user id"
  end

  test "giving a plan adds its units, recorded with the reason", %{conn: conn} do
    user = user_fixture()
    plan = plan_fixture(%{features: %{"rides" => 5}})
    {:ok, view, _html} = live(conn, "/admin/billing/users?user_id=#{user.id}")

    view
    |> form("#gift-form", gift: %{plan_id: plan.id, reason: "Driver cancelled"})
    |> render_submit()

    assert UdinBilling.Access.remaining(UdinBilling.access(user.id), "rides") == 5
    assert render(view) =~ "Gave #{plan.code}"

    [purchase] = Ash.read!(Purchase, authorize?: false)
    assert purchase.provider == "admin"
    assert purchase.metadata["reason"] == "Driver cancelled"
  end

  test "a gift needs a reason", %{conn: conn} do
    user = user_fixture()
    plan = plan_fixture()
    {:ok, view, _html} = live(conn, "/admin/billing/users?user_id=#{user.id}")

    html = view |> form("#gift-form", gift: %{plan_id: plan.id, reason: " "}) |> render_submit()

    assert html =~ "Write why you are giving"
    assert Ash.read!(Purchase, authorize?: false) == []
  end

  describe "language" do
    test "renders in English by default", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/billing/users")

      assert has_element?(view, "h1", "Users")
      assert has_element?(view, "#users-intro", "Look up one user")
      assert has_element?(view, "#user-id ~ .ub-hint", "Paste the user's id")
      assert has_element?(view, "button", "Look up")
    end

    test "renders in Arabic with ?lang=ar", %{conn: conn} do
      user = user_fixture()
      plan_fixture()
      {:ok, view, _html} = live(conn, "/admin/billing/users?lang=ar&user_id=#{user.id}")

      assert has_element?(view, "h1", "المستخدمون")
      assert has_element?(view, "#users-intro", "ابحث")
      assert has_element?(view, "#user-id ~ .ub-hint", "المعرّف")
      assert has_element?(view, "#user-id[dir=ltr]")
      assert has_element?(view, "#user-counters th", "المتبقي")
      assert has_element?(view, "button", "بحث")
      assert has_element?(view, "button", "منح الباقة")
      refute has_element?(view, "#user-counters th", "Left")
    end

    test "the gift form's plan help uses the catalog's own plan name", %{conn: conn} do
      user = user_fixture()
      plan_fixture()

      with_env(:dashboard_examples, %{plan_name: "Starter"}, fn ->
        {:ok, view, _html} = live(conn, "/admin/billing/users?user_id=#{user.id}")
        assert has_element?(view, "#gift-plan ~ .ub-hint", "Starter")
      end)
    end

    test "sources and dates are translated", %{conn: conn} do
      user = user_fixture()
      plan = plan_fixture(%{features: %{"rides" => 10}})
      {:ok, _} = UdinBilling.Purchases.record_paid(user.id, plan.id, "fake", "ref-ar")

      {:ok, view, _html} = live(conn, "/admin/billing/users?lang=ar&user_id=#{user.id}")

      assert has_element?(view, "#user-sources .ub-badge", "عملية شراء")
      assert has_element?(view, "#user-sources td", "UTC")
      refute has_element?(view, "#user-sources", "Purchase")
    end

    test "an invalid id is explained in Arabic", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/billing/users?lang=ar&user_id=not-a-uuid")
      assert html =~ "المعرّف غير صالح"
    end

    test "the gift flash and its reason error use the chosen language", %{conn: conn} do
      user = user_fixture()
      plan = plan_fixture(%{features: %{"rides" => 5}})
      {:ok, view, _html} = live(conn, "/admin/billing/users?lang=ar&user_id=#{user.id}")

      html = view |> form("#gift-form", gift: %{plan_id: plan.id, reason: " "}) |> render_submit()
      assert html =~ "اكتب سبب"

      view |> form("#gift-form", gift: %{plan_id: plan.id, reason: "x"}) |> render_submit()
      assert render(view) =~ "تم منح #{plan.code}"
    end

    test "the lookup keeps the language", %{conn: conn} do
      user = user_fixture()
      {:ok, view, _html} = live(conn, "/admin/billing/users?lang=ar")

      view |> form("#user-lookup", user_id: user.id) |> render_submit()
      assert_patch(view, "/admin/billing/users?user_id=#{user.id}")
    end
  end
end

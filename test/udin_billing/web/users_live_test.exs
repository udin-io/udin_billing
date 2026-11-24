defmodule UdinBilling.Web.UsersLiveTest.Search do
  @moduledoc "The app side of `:user_search` for these tests: finds users by email prefix."
  require Ash.Query

  def by_email(query) do
    UdinBilling.Test.User
    |> Ash.Query.filter(contains(email, ^query))
    |> Ash.Query.sort(:email)
    |> Ash.read!(authorize?: false)
    |> Enum.map(&%{id: &1.id, label: to_string(&1.email)})
  end

  def broken(_query), do: :not_a_list
end

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

    view |> form("#user-lookup", query: " #{user.id} ") |> render_submit()
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
      assert has_element?(view, "#user-query ~ .ub-hint", "Paste the user's id")
      assert has_element?(view, "button", "Look up")
    end

    test "renders in Arabic with ?lang=ar", %{conn: conn} do
      user = user_fixture()
      plan_fixture()
      {:ok, view, _html} = live(conn, "/admin/billing/users?lang=ar&user_id=#{user.id}")

      assert has_element?(view, "h1", "المستخدمون")
      assert has_element?(view, "#users-intro", "ابحث")
      assert has_element?(view, "#user-query ~ .ub-hint", "المعرّف")
      assert has_element?(view, "#user-query[dir=ltr]")
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

      view |> form("#user-lookup", query: user.id) |> render_submit()
      assert_patch(view, "/admin/billing/users?user_id=#{user.id}")
    end
  end

  describe "searching with the app's :user_search" do
    defp search(fun), do: {UdinBilling.Web.UsersLiveTest.Search, fun}

    test "without it, only an id works and the form asks for one", %{conn: conn} do
      {:ok, view, html} = live(conn, "/admin/billing/users")
      assert html =~ "User id"

      view |> form("#user-lookup", query: "someone@example.com") |> render_submit()
      assert render(view) =~ "valid user id"
    end

    test "an id still opens the user directly", %{conn: conn} do
      user = user_fixture()

      with_env(:user_search, search(:by_email), fn ->
        {:ok, view, _html} = live(conn, "/admin/billing/users")
        view |> form("#user-lookup", query: user.id) |> render_submit()
        assert_patch(view, "/admin/billing/users?user_id=#{user.id}")
      end)
    end

    test "one match opens that user", %{conn: conn} do
      user = user_fixture(%{email: "rider-one@example.com"})
      plan = plan_fixture(%{features: %{"rides" => 7}})
      {:ok, _} = UdinBilling.Purchases.record_paid(user.id, plan.id, "fake", "ref-7")

      with_env(:user_search, search(:by_email), fn ->
        {:ok, view, html} = live(conn, "/admin/billing/users")
        assert html =~ "Find a user"

        view |> form("#user-lookup", query: " rider-one ") |> render_submit()
        assert_patch(view, "/admin/billing/users?q=rider-one")
        assert has_element?(view, "#user-counters tr", "7")
      end)
    end

    test "several matches are listed to choose from", %{conn: conn} do
      first = user_fixture(%{email: "twin-a@example.com"})
      second = user_fixture(%{email: "twin-b@example.com"})

      with_env(:user_search, search(:by_email), fn ->
        {:ok, view, _html} = live(conn, "/admin/billing/users?q=twin")

        refute has_element?(view, "#user-counters")
        assert has_element?(view, "#user-matches a", "twin-a@example.com")
        assert has_element?(view, "#user-matches a", "twin-b@example.com")

        view |> element("#user-matches a", "twin-b@example.com") |> render_click()
        assert_patch(view, "/admin/billing/users?user_id=#{second.id}")
        assert has_element?(view, "#user-counters")
        refute first.id == second.id
      end)
    end

    test "no match says so", %{conn: conn} do
      with_env(:user_search, search(:by_email), fn ->
        {:ok, _view, html} = live(conn, "/admin/billing/users?q=nobody")
        assert html =~ "No user found"
      end)
    end

    test "no match is explained in Arabic", %{conn: conn} do
      with_env(:user_search, search(:by_email), fn ->
        {:ok, _view, html} = live(conn, "/admin/billing/users?lang=ar&q=nobody")
        assert html =~ "لا يوجد مستخدم"
      end)
    end

    test "a wrong setting or a wrong answer from the app fails loudly" do
      with_env(:user_search, "by_email", fn ->
        assert_raise ArgumentError, ~r/user_search/, fn -> UdinBilling.Config.user_search() end
      end)

      with_env(:user_search, search(:broken), fn ->
        admin = user_fixture(%{admin: true})

        assert_raise ArgumentError, ~r/user_search/, fn ->
          UdinBilling.Admin.search_users("x", admin)
        end
      end)
    end

    test "only admins can search" do
      with_env(:user_search, search(:by_email), fn ->
        assert {:error, :forbidden} = UdinBilling.Admin.search_users("x", user_fixture())
      end)
    end
  end

  describe "the found user's label" do
    test "shows above the counters when the app labels users", %{conn: conn} do
      user = user_fixture(%{email: "labelled@example.com"})

      with_env(:user_labels, {UdinBilling.Test.UserLabels, :by_email}, fn ->
        {:ok, view, _html} = live(conn, "/admin/billing/users?user_id=#{user.id}")
        assert has_element?(view, "#user-label", "label labelled@example.com")
      end)
    end

    test "is left out without the setting", %{conn: conn} do
      user = user_fixture()
      {:ok, view, _html} = live(conn, "/admin/billing/users?user_id=#{user.id}")
      refute has_element?(view, "#user-label")
    end
  end
end

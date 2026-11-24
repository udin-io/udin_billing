defmodule UdinBilling.Web.PlansLiveTest do
  use UdinBilling.ConnCase

  setup do
    %{conn: admin_conn()}
  end

  test "plans are grouped by type with price, period and what they include", %{conn: conn} do
    plan_fixture(%{
      name: %{"en" => "Weekly bundle", "ar" => "باقة أسبوعية"},
      features: %{"rides" => 10}
    })

    subscription_plan_fixture(%{
      name: %{"en" => "Basic", "ar" => "أساسي"},
      features: %{"reel_imports" => 15, "share_recipe" => true}
    })

    {:ok, _view, html} = live(conn, "/admin/billing")

    assert html =~ "Subscription plans"
    assert html =~ "One-time plans"
    assert html =~ "Weekly bundle"
    assert html =~ "150 EGP"
    assert html =~ "valid 1 week"
    assert html =~ "/ month"
    assert html =~ "share_recipe"
    assert html =~ "Created #{Calendar.strftime(Date.utc_today(), "%Y-%m-%d")}, updated"
  end

  test "the language switch shows every name in that language, right to left", %{conn: conn} do
    plan_fixture(%{name: %{"en" => "Weekly bundle", "ar" => "باقة أسبوعية"}})

    {:ok, view, _html} = live(conn, "/admin/billing")
    html = view |> element("a", "العربية (Arabic)") |> render_click()

    assert html =~ "باقة أسبوعية"
    refute has_element?(view, ".ub-plan", "Weekly bundle")
    assert has_element?(view, ~s([dir="rtl"]), "باقة أسبوعية")
  end

  test "a language added to the config is flagged on plans that lack it", %{conn: conn} do
    plan_fixture()

    with_env(:locales, ["en", "ar", "fr"], fn ->
      {:ok, _view, html} = live(conn, "/admin/billing")
      assert html =~ "Missing fr"
    end)
  end

  test "taking a plan off sale and back", %{conn: conn} do
    plan = plan_fixture()
    {:ok, view, _html} = live(conn, "/admin/billing")

    view |> element("#plan-#{plan.id} button", "Take off sale") |> render_click()
    assert Ash.get!(Plan, plan.id, authorize?: false).status == :inactive
    assert render(view) =~ "Off sale"

    view |> element("#plan-#{plan.id} button", "Put on sale") |> render_click()
    assert Ash.get!(Plan, plan.id, authorize?: false).status == :active
  end

  test "the compare view is a plans × features table", %{conn: conn} do
    plan_fixture(%{features: %{"rides" => 10}})
    plan_fixture(%{features: %{"rides" => :unlimited, "share_recipe" => true}})

    {:ok, view, _html} = live(conn, "/admin/billing?view=compare")

    assert has_element?(view, "#plans-compare td", "10")
    assert has_element?(view, "#plans-compare td", "Unlimited")
    assert has_element?(view, "#plans-compare td", "✓")
  end

  test "an empty catalog invites creating the first plan", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/admin/billing")
    assert html =~ "No plans yet"
  end

  describe "dashboard language" do
    defp own_catalog do
      for table <- ~w(billing_plan_features billing_plans billing_features),
          do: UdinBilling.TestRepo.delete_all(table)

      Ash.create!(
        Feature,
        %{key: "tokens", kind: :counter, name: %{"en" => "Tokens", "ar" => "رموز"}},
        authorize?: false
      )

      plan_fixture(%{
        code: "gold",
        name: %{"en" => "Gold", "ar" => "ذهبية"},
        price: Decimal.new(75),
        features: %{"tokens" => 40}
      })
    end

    test "is English by default", %{conn: conn} do
      own_catalog()
      {:ok, view, _html} = live(conn, "/admin/billing")

      assert has_element?(view, "h1", "Plans")
      assert has_element?(view, ".ub-note", "See every plan")
      assert has_element?(view, "a", "New plan")
      assert has_element?(view, "div", "Preview language")
    end

    test "?lang=ar shows heading, intro, help and buttons in Arabic", %{conn: conn} do
      own_catalog()
      {:ok, view, html} = live(conn, "/admin/billing?lang=ar")

      assert has_element?(view, "h1", "الباقات")
      assert has_element?(view, ".ub-note", "شاهد كل باقة")
      assert has_element?(view, "a", "باقة جديدة")
      assert has_element?(view, "div", "لغة المعاينة")
      assert has_element?(view, "button", "إيقاف البيع")
      assert html =~ "لا تغيّر لغة هذه اللوحة"
      assert has_element?(view, "h2", "باقات لمرة واحدة")
    end

    test "help examples come from the catalog, never fixed words", %{conn: conn} do
      own_catalog()

      {:ok, _view, html} = live(conn, "/admin/billing")
      assert html =~ "which plans include Tokens"
      assert html =~ "the plan Gold reads well"

      {:ok, _view, html} = live(conn, "/admin/billing?lang=ar")
      assert html =~ "تشمل رموز"
      assert html =~ "الباقة ذهبية"
      refute html =~ ~r/reel|ride|recipe|bundle/i
    end

    test "compare view has Arabic header and help", %{conn: conn} do
      own_catalog()
      {:ok, view, _html} = live(conn, "/admin/billing?view=compare&lang=ar")

      assert has_element?(view, "#plans-compare th", "الميزة")
      assert render(view) =~ "كل صف هو ميزة"
    end

    test "links keep the dashboard language and the preview language", %{conn: conn} do
      plan = plan_fixture()
      {:ok, view, _html} = live(conn, "/admin/billing?lang=ar&locale=en")

      assert has_element?(view, ~s(a[href*="/plans/new"][href*="lang=ar"]))
      assert has_element?(view, ~s(#plan-#{plan.id} a[href*="/edit"][href*="lang=ar"]))
      assert has_element?(view, ~s(a[href*="view=compare"][href*="locale=en"][href*="lang=ar"]))
      assert has_element?(view, ~s(a[href*="locale=ar"][href*="view=cards"][href*="lang=ar"]))
    end

    test "preview language is independent of the dashboard language", %{conn: conn} do
      plan_fixture(%{name: %{"en" => "Weekly bundle", "ar" => "باقة أسبوعية"}})
      {:ok, view, _html} = live(conn, "/admin/billing?lang=en&locale=ar")

      assert has_element?(view, "h1", "Plans")
      assert has_element?(view, ~s([dir="rtl"]), "باقة أسبوعية")
    end

    test "flash messages follow the chosen language", %{conn: conn} do
      plan = plan_fixture(%{code: "gold-flash"})
      {:ok, view, _html} = live(conn, "/admin/billing?lang=ar")

      html = view |> element("#plan-#{plan.id} button", "إيقاف البيع") |> render_click()
      assert html =~ "gold-flash موقوفة عن البيع"

      html = view |> element("#plan-#{plan.id} button", "عرض للبيع") |> render_click()
      assert html =~ "gold-flash معروضة للبيع"
    end

    test "English flash message", %{conn: conn} do
      plan = plan_fixture(%{code: "gold-flash"})
      {:ok, view, _html} = live(conn, "/admin/billing")

      html = view |> element("#plan-#{plan.id} button", "Take off sale") |> render_click()
      assert html =~ "gold-flash is off sale."
    end
  end
end

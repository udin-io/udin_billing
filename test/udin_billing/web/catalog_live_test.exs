defmodule UdinBilling.Web.CatalogLiveTest do
  use UdinBilling.ConnCase

  require Ash.Query

  setup do
    %{conn: admin_conn()}
  end

  defp plan_by_code(code),
    do: Plan |> Ash.Query.filter(code == ^code) |> Ash.read_one!(authorize?: false)

  # A catalog from "staging": this database's setup plus one more plan.
  defp staging_catalog do
    UdinBilling.Catalog.export()
    |> update_in(["plans"], fn plans ->
      plans ++
        [
          %{
            "code" => "monthly",
            "name" => %{"en" => "Monthly", "ar" => "شهري"},
            "kind" => "one_time",
            "price" => "500",
            "currency" => "EGP",
            "validity_unit" => "month",
            "validity_count" => 1,
            "features" => %{"rides" => 44}
          }
        ]
    end)
    |> UdinBilling.Catalog.encode()
  end

  test "shows this environment's catalog to copy", %{conn: conn} do
    plan_fixture(%{code: "weekly"})
    {:ok, view, _html} = live(conn, "/admin/billing/catalog")

    assert has_element?(view, "#catalog-export", "udin_billing.catalog")
    assert has_element?(view, "#catalog-export", "weekly")
  end

  test "preview lists the changes and writes nothing; apply makes them", %{conn: conn} do
    plan_fixture(%{code: "weekly"})
    {:ok, view, _html} = live(conn, "/admin/billing/catalog")

    view |> form("#catalog-import", catalog: %{json: staging_catalog()}) |> render_submit()

    assert has_element?(view, "#catalog-preview tr", "monthly")
    assert has_element?(view, "#catalog-preview .ub-badge", "create")
    refute plan_by_code("monthly")

    view |> element("#catalog-preview button", "Apply changes") |> render_click()

    assert plan_by_code("monthly").features == %{"rides" => 44}
    assert render(view) =~ "Catalog applied: 1 change."
    assert has_element?(view, "#catalog-export", "monthly")
  end

  test "problems are listed and nothing can be applied", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/admin/billing/catalog")

    html = view |> form("#catalog-import", catalog: %{json: "{not json"}) |> render_submit()

    assert html =~ "Nothing can be applied"
    refute has_element?(view, "button", "Apply changes")
  end

  test "an identical file has nothing to apply", %{conn: conn} do
    plan_fixture(%{code: "weekly"})
    {:ok, view, _html} = live(conn, "/admin/billing/catalog")

    json = UdinBilling.Catalog.encode(UdinBilling.Catalog.export())
    html = view |> form("#catalog-import", catalog: %{json: json}) |> render_submit()

    assert html =~ "already matches"
    refute has_element?(view, "button", "Apply changes")
  end

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

  describe "dashboard language" do
    test "English by default", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/billing/catalog")

      assert has_element?(view, "h1", "Catalog")
      assert has_element?(view, ".ub-note", "Set up features and plans once")
      assert has_element?(view, "button", "Preview changes")
      assert render(view) =~ "dry run"
    end

    test "?lang=ar shows heading, intro, help and button in Arabic", %{conn: conn} do
      {:ok, view, html} = live(conn, "/admin/billing/catalog?lang=ar")

      assert has_element?(view, "h1", "الكتالوج")
      assert has_element?(view, ".ub-note", "جهّز الميزات والباقات")
      assert has_element?(view, "button", "معاينة التغييرات")
      assert has_element?(view, "h2", "استيراد")
      assert has_element?(view, "h2", "تصدير")
      assert html =~ "المعاينة تجربة بلا حفظ"
      assert has_element?(view, "textarea[dir=ltr]#catalog-export")
    end

    test "help examples come from the catalog", %{conn: conn} do
      own_catalog()
      {:ok, _view, html} = live(conn, "/admin/billing/catalog")
      assert html =~ "a file with the plan gold"
      refute html =~ ~r/reel|ride|recipe|bundle/i

      {:ok, _view, html} = live(conn, "/admin/billing/catalog?lang=ar")
      assert html =~ "ملف فيه الباقة gold"
    end

    test "preview, problems and apply flash are in Arabic", %{conn: conn} do
      plan_fixture(%{code: "weekly"})
      {:ok, view, _html} = live(conn, "/admin/billing/catalog?lang=ar")

      html = view |> form("#catalog-import", catalog: %{json: "{not json"}) |> render_submit()
      assert html =~ "لا يمكن تطبيق شيء قبل إصلاح هذه المشكلات"
      assert html =~ "الملف ليس JSON صالحًا"

      view |> form("#catalog-import", catalog: %{json: staging_catalog()}) |> render_submit()
      assert has_element?(view, "#catalog-preview .ub-badge", "إنشاء")
      assert has_element?(view, "#catalog-preview", "ما الذي سيتغير")

      view |> element("#catalog-preview button", "تطبيق التغييرات") |> render_click()
      assert render(view) =~ "تم تطبيق الكتالوج: تغيير واحد"
    end

    test "English apply flash uses the singular", %{conn: conn} do
      plan_fixture(%{code: "weekly"})
      {:ok, view, _html} = live(conn, "/admin/billing/catalog")

      view |> form("#catalog-import", catalog: %{json: staging_catalog()}) |> render_submit()
      view |> element("#catalog-preview button", "Apply changes") |> render_click()
      assert render(view) =~ "Catalog applied: 1 change."
    end

    test "unknown file problems are shown as they are", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/billing/catalog?lang=ar")
      json = ~s({"format": "other"})
      html = view |> form("#catalog-import", catalog: %{json: json}) |> render_submit()
      assert html =~ "هذا ليس ملف كتالوج فوترة"
    end
  end
end

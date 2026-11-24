defmodule UdinBilling.Web.FeaturesLiveTest do
  use UdinBilling.ConnCase

  require Ash.Query

  setup do
    %{conn: admin_conn()}
  end

  defp feature(key) do
    Feature |> Ash.Query.filter(key == ^key) |> Ash.read_one!(authorize?: false)
  end

  test "adds a feature with its name in English and Arabic", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/admin/billing/features/new")

    view
    |> form("#feature-form",
      feature: %{
        key: "household",
        kind: "switch",
        name: %{en: "Household sharing", ar: "مشاركة العائلة"}
      }
    )
    |> render_submit()

    assert_patch(view, "/admin/billing/features")
    assert feature("household").name == %{"en" => "Household sharing", "ar" => "مشاركة العائلة"}
    assert has_element?(view, "#feature-household", "مشاركة العائلة")
  end

  test "a missing language is shown on its field and nothing is saved", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/admin/billing/features/new")

    view
    |> form("#feature-form",
      feature: %{key: "household", kind: "switch", name: %{en: "Household", ar: ""}}
    )
    |> render_submit()

    assert has_element?(view, "#feature-name-ar ~ .ub-error", "required")
    refute feature("household")
  end

  test "a bad key is reported by the catalog's own rules", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/admin/billing/features/new")

    html =
      view
      |> form("#feature-form",
        feature: %{key: "Bad-Key", kind: "switch", name: %{en: "B", ar: "ب"}}
      )
      |> render_submit()

    assert html =~ "ub-flash-error" or has_element?(view, "#feature-key ~ .ub-error")
    refute feature("Bad-Key")
  end

  test "renaming keeps the key and kind fixed", %{conn: conn} do
    rides = feature("rides")
    {:ok, view, _html} = live(conn, "/admin/billing/features/#{rides.id}/edit")

    assert has_element?(view, "#feature-key[readonly]")
    assert has_element?(view, "#feature-kind[disabled]")

    view
    |> form("#feature-form", feature: %{name: %{en: "Ride credits", ar: "رصيد الرحلات"}})
    |> render_submit()

    assert %{
             key: "rides",
             kind: :counter,
             name: %{"en" => "Ride credits", "ar" => "رصيد الرحلات"}
           } =
             feature("rides")
  end

  test "only features no plan includes can be deleted", %{conn: conn} do
    plan_fixture(%{features: %{"rides" => 10}})
    {:ok, view, _html} = live(conn, "/admin/billing/features")

    refute has_element?(view, "#feature-rides button", "Delete")
    assert has_element?(view, "#feature-rides", "Weekly")

    view |> element("#feature-meal_plan button", "Delete") |> render_click()
    refute feature("meal_plan")
    refute has_element?(view, "#feature-meal_plan")
  end

  test "features the code uses are marked and can't be deleted", %{conn: conn} do
    with_env(:required_features, ["meal_plan"], fn ->
      {:ok, view, _html} = live(conn, "/admin/billing/features")

      assert has_element?(view, "#feature-meal_plan .ub-badge", "Used by code")
      refute has_element?(view, "#feature-meal_plan button", "Delete")
      assert has_element?(view, "#feature-share_recipe button", "Delete")
    end)
  end

  describe "language" do
    test "renders in English by default", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/billing/features")

      assert has_element?(view, "h1", "Features")
      assert has_element?(view, "#features-intro", "switch")
      assert has_element?(view, "#features th", "Included in")
      assert has_element?(view, "a", "New feature")
    end

    test "renders in Arabic with ?lang=ar", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/billing/features?lang=ar")

      assert has_element?(view, "h1", "الميزات")
      assert has_element?(view, "#features-intro", "رصيد")
      assert has_element?(view, "#features th", "المفتاح")
      assert has_element?(view, "a", "ميزة جديدة")
      refute has_element?(view, "#features th", "Included in")
    end

    test "the form's help texts are built from the catalog's own names", %{conn: conn} do
      with_env(:dashboard_examples, %{feature: "Tokens", feature_key: "tokens"}, fn ->
        {:ok, view, _html} = live(conn, "/admin/billing/features/new?lang=ar")

        assert has_element?(view, "#feature-key ~ .ub-hint", "tokens")
        assert has_element?(view, "#feature-kind ~ .ub-hint", "Tokens")
        assert has_element?(view, "label", "المفتاح")
        assert has_element?(view, "#feature-key[dir=ltr]")
        assert has_element?(view, "button", "إضافة ميزة")
      end)
    end

    test "the saved flash uses the chosen language", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/billing/features/new?lang=ar")

      view
      |> form("#feature-form",
        feature: %{key: "household", kind: "switch", name: %{en: "Household", ar: "العائلة"}}
      )
      |> render_submit()

      assert_patch(view, "/admin/billing/features")
      assert render(view) =~ "تم حفظ household"
    end

    test "a missing language error is in Arabic", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/billing/features/new?lang=ar")

      view
      |> form("#feature-form",
        feature: %{key: "household", kind: "switch", name: %{en: "Household", ar: ""}}
      )
      |> render_submit()

      assert has_element?(view, "#feature-name-ar ~ .ub-error", "مطلوب")
    end

    test "deleting flashes in the chosen language", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/billing/features?lang=ar")

      view |> element("#feature-meal_plan button", "حذف") |> render_click()
      assert render(view) =~ "تم حذف meal_plan"
    end

    test "links keep the language", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/billing/features?lang=ar")

      assert has_element?(view, "a[href='/admin/billing/features/new?lang=ar']")
      assert has_element?(view, "#features a[href*='/edit?lang=ar']")
    end
  end
end

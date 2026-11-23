defmodule UdinBilling.Web.PlanFormLiveTest do
  use UdinBilling.ConnCase

  require Ash.Query

  setup do
    %{conn: admin_conn()}
  end

  defp plan_by_code(code) do
    Plan |> Ash.Query.filter(code == ^code) |> Ash.read_one!(authorize?: false)
  end

  test "creates a subscription with names in both languages, a monthly reset and features",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/admin/billing/plans/new")

    # Choosing "limited" reveals the number field, as an admin would see it.
    view
    |> form("#plan-form",
      plan: %{kind: "recurring", features: %{reel_imports: %{mode: "limited"}}}
    )
    |> render_change()

    view
    |> form("#plan-form",
      plan: %{
        code: "plus-monthly",
        name: %{en: "Plus", ar: "بلس"},
        description: %{en: "Best value", ar: "أفضل قيمة"},
        price: "350",
        cycle_mode: "period",
        recommended: "true",
        product_ids: %{revenuecat: "plus_monthly, plus:monthly"},
        features: %{reel_imports: %{mode: "limited", limit: "40"}, share_recipe: %{on: "true"}}
      }
    )
    |> render_submit()

    assert_redirect(view, "/admin/billing?lang=en")

    plan = plan_by_code("plus-monthly")
    assert plan.kind == :recurring
    assert plan.name == %{"en" => "Plus", "ar" => "بلس"}
    assert plan.description == %{"en" => "Best value", "ar" => "أفضل قيمة"}
    assert Decimal.equal?(plan.price, 350)
    assert {plan.validity_unit, plan.cycle_unit} == {:month, :month}
    assert plan.features == %{"reel_imports" => 40, "share_recipe" => true}
    assert plan.metadata["recommended"] == true
    assert plan.provider_product_ids["revenuecat"] == ["plus_monthly", "plus:monthly"]
  end

  test "a missing Arabic name is shown on its field and nothing is saved", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/admin/billing/plans/new")

    html =
      view
      |> form("#plan-form", plan: %{code: "half", name: %{en: "Half", ar: ""}, price: "10"})
      |> render_submit()

    assert has_element?(view, "#plan-name-ar ~ .ub-error", "required")
    refute has_element?(view, "#plan-name-en ~ .ub-error")
    assert html =~ "Fix the highlighted fields"
    refute plan_by_code("half")
  end

  test "an Arabic name field is right to left", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/admin/billing/plans/new")

    assert has_element?(view, ~s(#plan-name-ar[dir="rtl"][lang="ar"]))
    assert has_element?(view, ~s(#plan-name-en[dir="ltr"]))
  end

  test "the preview follows the form, in the chosen language", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/admin/billing/plans/new")

    view
    |> form("#plan-form", plan: %{name: %{en: "Weekly", ar: "أسبوعي"}, price: "150"})
    |> render_change()

    assert has_element?(view, ".ub-preview h3", "Weekly")

    view |> element(".ub-preview button", "AR") |> render_click()
    assert has_element?(view, ".ub-preview h3", "أسبوعي")
    # Every word in the Arabic preview is Arabic, not just the name.
    assert has_element?(view, ".ub-preview", "صالحة لمدة شهر واحد")
    refute has_element?(view, ".ub-preview", "valid 1 month")
    assert has_element?(view, ~s(.ub-preview [dir="rtl"]))
  end

  test "a free plan has no price field and saves at 0", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/admin/billing/plans/new")

    view |> form("#plan-form", plan: %{kind: "free"}) |> render_change()
    refute has_element?(view, "#plan-price")

    view
    |> form("#plan-form",
      plan: %{
        code: "free",
        name: %{en: "Free", ar: "مجاني"},
        validity_mode: "forever",
        cycle_mode: "period",
        is_default: "true"
      }
    )
    |> render_submit()

    plan = plan_by_code("free")
    assert Decimal.equal?(plan.price, 0)
    assert plan.is_default
    assert plan.validity_unit == nil
    assert plan.after_subscription == :continue
  end

  test "the free plan explains and saves what users get after a subscription", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/admin/billing/plans/new")
    refute has_element?(view, "#plan-after-subscription-fresh_start")

    view |> form("#plan-form", plan: %{kind: "free"}) |> render_change()
    assert has_element?(view, ".ub-choice", "Continue where they left off")
    assert has_element?(view, ".ub-choice", "Fresh start")

    view
    |> form("#plan-form",
      plan: %{
        code: "free",
        name: %{en: "Free", ar: "مجاني"},
        validity_mode: "forever",
        after_subscription: "fresh_start"
      }
    )
    |> render_submit()

    assert plan_by_code("free").after_subscription == :fresh_start
  end

  test "saving keeps what the form doesn't show: extra metadata, other stores' product ids",
       %{conn: conn} do
    plan =
      plan_fixture(%{
        code: "weekly-hidden",
        metadata: %{"recommended" => false, "badge" => "best value"},
        # "appstore_direct" isn't configured in this environment, so the form has no field
        # for it.
        provider_product_ids: %{"fake" => "weekly_fake", "appstore_direct" => "weekly_ios"}
      })

    {:ok, view, _html} = live(conn, "/admin/billing/plans/#{plan.id}/edit")

    view
    |> form("#plan-form", plan: %{name: %{en: "Weekly bundle", ar: "باقة أسبوعية"}})
    |> render_submit()

    assert_redirect(view, "/admin/billing?lang=en")
    saved = plan_by_code("weekly-hidden")
    assert saved.name["en"] == "Weekly bundle"
    assert saved.metadata["badge"] == "best value"
    assert saved.provider_product_ids["appstore_direct"] == "weekly_ios"
    assert saved.provider_product_ids["fake"] == "weekly_fake"
  end

  test "editing keeps the code and saves the changes", %{conn: conn} do
    plan = plan_fixture(%{features: %{"rides" => 10}})
    {:ok, view, html} = live(conn, "/admin/billing/plans/#{plan.id}/edit")

    assert html =~ "People who already bought this plan keep what they paid for"
    assert has_element?(view, "#plan-code[readonly]")

    view
    |> form("#plan-form", plan: %{price: "175", features: %{rides: %{mode: "unlimited"}}})
    |> render_submit()

    plan = Ash.get!(Plan, plan.id, authorize?: false)
    assert Decimal.equal?(plan.price, 175)
    assert plan.features == %{"rides" => "unlimited"}
  end

  test "a code already taken is reported on the code field", %{conn: conn} do
    plan_fixture(%{code: "weekly"})
    {:ok, view, _html} = live(conn, "/admin/billing/plans/new")

    view
    |> form("#plan-form", plan: %{code: "weekly", name: %{en: "W", ar: "و"}, price: "1"})
    |> render_submit()

    assert has_element?(view, "#plan-code ~ .ub-error")
  end

  test "duplicating starts a new plan from an existing one", %{conn: conn} do
    plan = plan_fixture(%{code: "basic-monthly", features: %{"rides" => 12}})
    {:ok, view, _html} = live(conn, "/admin/billing/plans/new?copy=#{plan.id}")

    assert has_element?(view, ~s(#plan-code[value="basic-monthly-copy"]))
    assert has_element?(view, ~s(#plan-feature-rides-limit[value="12"]))
  end

  describe "a plan with buyers" do
    setup do
      plan =
        plan_fixture(%{code: "weekly", features: %{"rides" => 10, "share_recipe" => true}})

      paid_purchase_fixture(user_fixture(), plan)
      %{plan: plan}
    end

    test "locks what it sells and offers a new version", %{conn: conn, plan: plan} do
      {:ok, view, _html} = live(conn, "/admin/billing/plans/#{plan.id}/edit")

      assert has_element?(view, "#plan-locked", "This plan has buyers")
      assert has_element?(view, "#plan-price[readonly]")
      assert has_element?(view, "#plan-kind[disabled]")
      assert has_element?(view, "#plan-feature-share_recipe[disabled]")
    end

    test "names can still be edited; locked values are kept as they are", %{
      conn: conn,
      plan: plan
    } do
      {:ok, view, _html} = live(conn, "/admin/billing/plans/#{plan.id}/edit")

      view
      |> form("#plan-form", plan: %{name: %{en: "Weekly bundle", ar: "باقة أسبوعية"}})
      |> render_submit()

      plan = Ash.get!(Plan, plan.id, authorize?: false)
      assert plan.name["en"] == "Weekly bundle"
      assert plan.features == %{"rides" => 10, "share_recipe" => true}
    end

    test "a new version is created and the old plan goes off sale", %{conn: conn, plan: plan} do
      {:ok, view, _html} = live(conn, "/admin/billing")

      {:ok, view, _html} =
        view
        |> element("#plan-#{plan.id} a", "New version")
        |> render_click()
        |> follow_redirect(conn)

      assert has_element?(view, "#plan-replacing", "New version of weekly")
      assert has_element?(view, ~s(#plan-code[value="weekly-v2"]))

      view |> form("#plan-form", plan: %{price: "175"}) |> render_submit()

      assert plan_by_code("weekly-v2").price |> Decimal.equal?(175)
      assert plan_by_code("weekly").status == :inactive
    end
  end

  test "the counter reset hint names this app's own counters", %{conn: conn} do
    {:ok, rides} = UdinBilling.Admin.list_features(%{admin: true})
    rides = Enum.find(rides, &(&1.key == "rides"))

    {:ok, _} =
      UdinBilling.Admin.update_feature(
        rides,
        %{name: %{"en" => "Ride credits", "ar" => "رصيد الرحلات"}},
        %{admin: true}
      )

    {:ok, _view, html} = live(conn, "/admin/billing/plans/new")
    assert html =~ "When counters (reel_imports, Ride credits) refill"
  end

  test "a sale shows the original price crossed out in the preview and saves it", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/admin/billing/plans/new")

    view
    |> form("#plan-form",
      plan: %{
        code: "sale",
        name: %{en: "Weekly", ar: "أسبوعي"},
        price: "150",
        original_price: "200"
      }
    )
    |> render_change()

    assert has_element?(view, ".ub-preview s", "200 EGP")

    view |> form("#plan-form", plan: %{}) |> render_submit()
    assert Decimal.equal?(plan_by_code("sale").original_price, 200)
  end

  test "an original price at or below the price is refused on its field", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/admin/billing/plans/new")

    view
    |> form("#plan-form",
      plan: %{code: "bad-sale", name: %{en: "W", ar: "و"}, price: "150", original_price: "150"}
    )
    |> render_submit()

    assert has_element?(view, "#plan-original-price ~ .ub-error")
    refute plan_by_code("bad-sale")
  end

  describe "language and help texts" do
    defp empty_catalog do
      for table <- ~w(billing_plan_features billing_plans billing_features),
          do: UdinBilling.TestRepo.delete_all(table)
    end

    defp feature!(key, en, ar, kind \\ :counter) do
      Ash.create!(UdinBilling.Feature, %{key: key, kind: kind, name: %{"en" => en, "ar" => ar}},
        authorize?: false
      )
    end

    test "English by default: intro, labels, help and an example", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/billing/plans/new")

      assert has_element?(view, "h1", "New plan")
      assert has_element?(view, "#plan-form-intro", "Design one plan here")
      assert has_element?(view, "#plan-price", "")
      assert has_element?(view, "label", "Original price (optional)")
      assert has_element?(view, "button", "Create plan")
      assert has_element?(view, "#plan-price ~ .ub-hint", "For example:")
    end

    test "?lang=ar shows the page in Arabic, with Arabic help and the main button", %{conn: conn} do
      {:ok, view, html} = live(conn, "/admin/billing/plans/new?lang=ar")

      assert has_element?(view, ".ub[dir=rtl][lang=ar]")
      assert has_element?(view, "h1", "باقة جديدة")
      assert has_element?(view, "#plan-form-intro", "صمّم")
      assert has_element?(view, "button", "إنشاء باقة")
      assert has_element?(view, "#plan-price ~ .ub-hint", "مثال:")
      refute html =~ "Create plan"
      refute html =~ "Original price"
      assert has_element?(view, ~s(#plan-price[dir="ltr"]))
      assert has_element?(view, ~s(#plan-code[dir="ltr"]))
    end

    test "examples come from the catalog, not from the page", %{conn: conn} do
      empty_catalog()
      feature!("tokens", "Tokens", "رموز")
      feature!("priority", "Priority", "أولوية", :switch)

      plan_fixture(%{
        code: "starter-pack",
        name: %{"en" => "Starter", "ar" => "مبتدئ"},
        price: "75",
        features: %{"tokens" => 25}
      })

      {:ok, view, _html} = live(conn, "/admin/billing/plans/new")

      assert has_element?(view, "#feature-tokens .ub-hint", "For example: 25 Tokens")
      assert has_element?(view, "#plan-price ~ .ub-hint", "75")
      assert has_element?(view, "#plan-code ~ .ub-hint", "starter-pack")

      html = render(view)
      refute html =~ ~r/\b(reel|reels|ride|rides|rider|riders|recipe|recipes|bundle|bundles)\b/i
    end

    test "the saved flash is in the chosen language", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/billing/plans/new?lang=ar")

      {:ok, _index, html} =
        view
        |> form("#plan-form",
          plan: %{code: "arabic-flash", name: %{en: "A", ar: "أ"}, price: "9"}
        )
        |> render_submit()
        |> follow_redirect(conn)

      assert html =~ "arabic-flash"
      assert html =~ "تم حفظ"
      refute html =~ "Saved arabic-flash"
    end

    test "the saved flash is in English by default", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/billing/plans/new")

      {:ok, _index, html} =
        view
        |> form("#plan-form",
          plan: %{code: "english-flash", name: %{en: "A", ar: "أ"}, price: "9"}
        )
        |> render_submit()
        |> follow_redirect(conn)

      assert html =~ "Saved english-flash."
    end

    test "validation errors are shown in Arabic", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/billing/plans/new?lang=ar")

      view
      |> form("#plan-form", plan: %{code: "half", name: %{en: "Half", ar: ""}, price: "x"})
      |> render_submit()

      assert has_element?(view, "#plan-name-ar ~ .ub-error", "مطلوب")
      assert has_element?(view, "#plan-price ~ .ub-error", "رقم")
      assert has_element?(view, ".ub-error", "صحّح")
    end

    test "links keep the language", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/billing/plans/new?lang=ar")

      assert has_element?(view, ~s(a[href="/admin/billing?lang=ar"]), "رجوع")
    end

    test "a missing plan sends the admin back to the list, keeping the language", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: to, flash: flash}}} =
               live(conn, "/admin/billing/plans/#{Ecto.UUID.generate()}/edit")

      assert to == "/admin/billing?lang=en"
      assert flash["error"] =~ "doesn't exist"
    end

    test "no visible text has a dash, a semicolon or a project word, in either language", %{
      conn: conn
    } do
      for lang <- ["en", "ar"] do
        {:ok, view, _html} = live(conn, "/admin/billing/plans/new?lang=#{lang}")
        view |> form("#plan-form", plan: %{kind: "free"}) |> render_change()

        text =
          view
          |> element("#plan-form")
          |> render()
          |> String.replace(~r/<[^>]*>/, " ")
          |> String.replace(~r/&[#\w]+;/, "")

        refute text =~ ~r/[\x{2014}\x{2013};]| - /u
        refute text =~ ~r/\b(recipes?|bundles?)\b|ريل|وصفة/iu
      end
    end
  end

  test "the editor asks for product ids only of store providers, never Paymob's", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/admin/billing/plans/new")

    assert has_element?(view, "#plan-product-revenuecat")
    refute has_element?(view, "#plan-product-paymob")
  end

  test "with only Paymob configured, the provider products section is gone", %{conn: conn} do
    paymob = Application.get_env(:udin_billing, :providers) |> Map.take(["paymob"])

    with_env(:providers, paymob, fn ->
      {:ok, _view, html} = live(conn, "/admin/billing/plans/new")
      refute html =~ "Payment provider products"
    end)
  end
end

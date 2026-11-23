defmodule UdinBilling.Web.PaymentsLiveTest do
  use UdinBilling.ConnCase

  alias UdinBilling.Purchases

  setup do
    user = user_fixture()
    plan = plan_fixture(%{name: %{"en" => "Weekly", "ar" => "أسبوعي"}})
    {:ok, purchase} = Purchases.start(user.id, plan.id, "fake")
    {:ok, purchase} = Purchases.attach_provider_ref(purchase, "order-555")
    %{conn: admin_conn(), user: user, purchase: purchase}
  end

  defp pay(purchase, transaction) do
    {:ok, _} =
      Purchases.confirm_payment(purchase.id, %{
        amount: "150.00",
        currency: "EGP",
        provider_ref: purchase.provider_ref,
        payment_ref: transaction
      })
  end

  defp second_payment(purchase) do
    require Ash.Query

    Purchase
    |> Ash.Query.filter(duplicate_of_id == ^purchase.id)
    |> Ash.read_one!(authorize?: false)
  end

  test "payments to refund come first, with why and what to refund", %{
    conn: conn,
    purchase: purchase
  } do
    pay(purchase, "tx-1")
    pay(purchase, "tx-2")
    second = second_payment(purchase)

    {:ok, view, _html} = live(conn, "/admin/billing/payments")

    assert has_element?(view, "#payment-#{second.id}", "Paid twice for the same order")
    assert has_element?(view, "#payment-#{second.id}", "tx-2")
    assert has_element?(view, "#payment-#{second.id}", "order-555")
    assert has_element?(view, "#payment-#{second.id}", "Weekly")
    assert has_element?(view, "#payment-#{second.id} a[href*='#{purchase.id}']")
    refute has_element?(view, "#payment-#{purchase.id}")
  end

  test "every payment is one click away", %{conn: conn, purchase: purchase} do
    pay(purchase, "tx-1")
    pay(purchase, "tx-2")
    second = second_payment(purchase)

    {:ok, view, _html} = live(conn, "/admin/billing/payments")
    view |> element("a", "All payments") |> render_click()

    assert has_element?(view, "#payment-#{purchase.id}", "tx-1")
    assert has_element?(view, "#payment-#{second.id}", "tx-2")
  end

  test "a refunded second payment leaves the list to refund", %{conn: conn, purchase: purchase} do
    pay(purchase, "tx-1")
    pay(purchase, "tx-2")
    second = second_payment(purchase)
    {:ok, _} = Purchases.refund(second.id, "paymob refund")

    {:ok, view, _html} = live(conn, "/admin/billing/payments")
    assert render(view) =~ "Nothing to refund"

    view |> element("a", "All payments") |> render_click()
    assert has_element?(view, "#payment-#{second.id}", "refunded")
  end

  test "explains each case that needs a refund, with an example", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/admin/billing/payments")

    assert html =~ "Paid twice for the same order"
    assert html =~ "Paid after the checkout was cancelled"
    assert html =~ "For example"
  end

  test "is in the navigation for admins without developer tools", %{conn: conn} do
    with_env(:developer_tools, false, fn ->
      {:ok, view, _html} = live(conn, "/admin/billing")
      assert has_element?(view, "nav a", "Payments")
    end)
  end

  defp own_catalog do
    for table <-
          ~w(billing_usages billing_grants billing_purchases billing_plan_features billing_plans billing_features),
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
      {:ok, view, _html} = live(conn, "/admin/billing/payments")

      assert has_element?(view, "h1", "Payments")
      assert has_element?(view, ".ub-note", "Money that users paid")
      assert has_element?(view, "#refund-guide", "How to refund")
    end

    test "?lang=ar shows heading, intro, guide, headers and switch in Arabic", %{
      conn: conn,
      purchase: purchase
    } do
      pay(purchase, "tx-1")
      pay(purchase, "tx-2")
      {:ok, view, _html} = live(conn, "/admin/billing/payments?lang=ar")

      assert has_element?(view, "h1", "المدفوعات")
      assert has_element?(view, ".ub-note", "أموال دفعها المستخدمون")
      assert has_element?(view, "#refund-guide", "كيف تسترد")
      assert has_element?(view, "#payments th", "المعاملة")
      assert has_element?(view, "a", "كل المدفوعات")
      assert has_element?(view, "#payments-columns", "ماذا تعني الأعمدة والحالات")
    end

    test "both stored refund reasons show translated", %{conn: conn, purchase: purchase} do
      pay(purchase, "tx-1")
      pay(purchase, "tx-2")
      second = second_payment(purchase)

      other_user = user_fixture()
      other_plan = plan_fixture()
      {:ok, late} = Purchases.start(other_user.id, other_plan.id, "fake")
      {:ok, late} = Purchases.attach_provider_ref(late, "order-late")
      {:ok, _} = Purchases.cancel(late.id)

      {:ok, _} =
        Purchases.confirm_payment(late.id, %{
          amount: "100",
          currency: "EGP",
          provider_ref: "order-late",
          payment_ref: "tx-late"
        })

      {:ok, view, _html} = live(conn, "/admin/billing/payments?lang=ar")
      assert has_element?(view, "#payment-#{second.id}", "تم الدفع مرتين لنفس الطلب")
      refute has_element?(view, "#payment-#{second.id}", "Paid twice")
      assert has_element?(view, "#payments", "تم الدفع بعد إلغاء الطلب")
      refute has_element?(view, "#payments", "Paid after the checkout")

      {:ok, view, _html} = live(conn, "/admin/billing/payments")
      assert has_element?(view, "#payment-#{second.id}", "Paid twice for the same order")
      assert has_element?(view, "#payments", "Paid after the checkout was cancelled")
    end

    test "unknown stored reasons are shown as saved", %{conn: conn, purchase: purchase} do
      pay(purchase, "tx-1")
      pay(purchase, "tx-2")
      second = second_payment(purchase)
      {:ok, _} = Purchases.refund(second.id, "paymob refund")

      {:ok, view, _html} = live(conn, "/admin/billing/payments?lang=ar&show=all")
      assert has_element?(view, "#payment-#{second.id}", "استرده paymob")
      assert has_element?(view, "#payment-#{second.id} .ub-badge", "تم الاسترداد")
    end

    test "the guide example is built from the catalog", %{conn: conn} do
      own_catalog()
      {:ok, view, _html} = live(conn, "/admin/billing/payments")
      assert has_element?(view, "#refund-guide", "a checkout for 75 EGP")
      refute render(view) =~ ~r/reel|ride|recipe|bundle/i

      {:ok, view, _html} = live(conn, "/admin/billing/payments?lang=ar")
      assert has_element?(view, "#refund-guide", "بمبلغ 75 EGP")
    end

    test "links keep the language", %{conn: conn, purchase: purchase} do
      pay(purchase, "tx-1")
      pay(purchase, "tx-2")
      second = second_payment(purchase)
      {:ok, view, _html} = live(conn, "/admin/billing/payments?lang=ar")

      assert has_element?(view, ~s(a[href*="show=all"][href*="lang=ar"]))
      assert has_element?(view, ~s(#payment-#{second.id} a[href*="/users"][href*="lang=ar"]))
    end
  end
end

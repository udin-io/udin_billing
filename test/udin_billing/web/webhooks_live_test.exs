defmodule UdinBilling.Web.WebhooksLiveTest do
  use UdinBilling.ConnCase

  setup do
    %{conn: admin_conn()}
  end

  defp failed_event(error) do
    ProviderEvent
    |> Ash.Changeset.for_create(:receive, %{
      provider: "fake",
      event_id: "evt-#{System.unique_integer([:positive])}",
      event_type: :payment_succeeded,
      reference: "ref-unknown",
      event: %{"type" => "payment_succeeded"}
    })
    |> Ash.create!(authorize?: false)
    |> Ash.Changeset.for_update(:mark_failed, %{error: error})
    |> Ash.update!(authorize?: false)
  end

  test "failed messages are listed by default with their error", %{conn: conn} do
    event = failed_event("unknown purchase")
    {:ok, view, _html} = live(conn, "/admin/billing/webhooks")

    assert has_element?(view, "#event-#{event.id}", "unknown purchase")
    assert has_element?(view, "#event-#{event.id} button", "Replay")
  end

  test "other statuses are one click away", %{conn: conn} do
    failed_event("x")
    {:ok, view, _html} = live(conn, "/admin/billing/webhooks")

    html = view |> element("a", "processed") |> render_click()
    assert html =~ "No processed messages"
  end

  test "replaying reports the outcome", %{conn: conn} do
    event = failed_event("unknown purchase")
    {:ok, view, _html} = live(conn, "/admin/billing/webhooks")

    html = view |> element("#event-#{event.id} button", "Replay") |> render_click()
    assert html =~ "Replay"
    assert Ash.get!(ProviderEvent, event.id, authorize?: false).attempts == 2
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
      failed_event("unknown purchase")
      {:ok, view, _html} = live(conn, "/admin/billing/webhooks")

      assert has_element?(view, "h1", "Webhooks")
      assert has_element?(view, ".ub-note", "Payment providers send a message")
      assert has_element?(view, "th", "Reference")
      assert has_element?(view, "button", "Replay")
    end

    test "?lang=ar shows heading, intro, header, help and button in Arabic", %{conn: conn} do
      event = failed_event("unknown purchase")
      {:ok, view, html} = live(conn, "/admin/billing/webhooks?lang=ar")

      assert has_element?(view, "h1", "رسائل مزوّد الدفع")
      assert has_element?(view, ".ub-note", "يرسل مزوّد الدفع رسالة")
      assert has_element?(view, "th", "المرجع")
      assert has_element?(view, "#event-#{event.id} button", "إعادة التطبيق")
      assert has_element?(view, "#status-help", "لم يمكن تطبيقها")
      assert has_element?(view, "#event-#{event.id} .ub-badge", "فاشلة")
      assert html =~ "نجحت عملية الدفع"
    end

    test "the example in the help comes from the catalog", %{conn: conn} do
      own_catalog()
      {:ok, _view, html} = live(conn, "/admin/billing/webhooks")
      assert html =~ "to the plan gold"
      refute html =~ ~r/reel|ride|recipe|bundle/i

      {:ok, _view, html} = live(conn, "/admin/billing/webhooks?lang=ar")
      assert html =~ "إلى الباقة gold"
    end

    test "raw message stays left to right data", %{conn: conn} do
      event = failed_event("x")
      {:ok, view, _html} = live(conn, "/admin/billing/webhooks?lang=ar")
      assert has_element?(view, "#event-#{event.id} pre[dir=ltr]", "payment_succeeded")
    end

    test "links keep the language", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/billing/webhooks?lang=ar")
      assert has_element?(view, ~s(a[href*="status=processed"][href*="lang=ar"]))
    end

    test "empty state and replay flash are in the chosen language", %{conn: conn} do
      event = failed_event("unknown purchase")
      {:ok, view, _html} = live(conn, "/admin/billing/webhooks?lang=ar")

      html = view |> element("#event-#{event.id} button", "إعادة التطبيق") |> render_click()
      assert html =~ "أُعيد التطبيق"

      {:ok, view, _html} = live(conn, "/admin/billing/webhooks?lang=ar&status=processed")
      assert render(view) =~ "لا توجد رسائل مطبّقة."
    end
  end
end

defmodule UdinBilling.Providers.PaymobFlowTest do
  @moduledoc "The whole Paymob flow: checkout → Paymob message → credits, through the shared inbox."
  use UdinBilling.DataCase, async: false

  import Plug.Test

  alias UdinBilling.{Purchases, Quotas, Webhooks, WebhookPlug}
  alias UdinBilling.Test.{PaymobFixtures, PaymobStub}

  @customer %{
    first_name: "Mona",
    last_name: "Ali",
    email: "mona@example.com",
    phone_number: "+201000000000"
  }

  setup do
    %{user: user_fixture(), plan: plan_fixture()}
  end

  # The stub answers with the order id the fixtures are signed for.
  defp checkout(user, plan) do
    PaymobStub.respond_with(
      {201,
       %{"id" => "pi_1", "client_secret" => "egy_csk_1", "intention_order_id" => 217_503_754}}
    )

    {:ok, %{purchase: purchase, redirect_url: url}} =
      UdinBilling.checkout(user.id, plan.id, "paymob", %{customer: @customer})

    {purchase, url}
  end

  defp rides(user), do: elem(Quotas.balance(user.id, "rides"), 1).remaining
  defp status(purchase), do: Ash.get!(Purchase, purchase.id, authorize?: false).status

  # Paymob posts the transaction as JSON and puts the signature in the query string.
  defp post_callback(callback) do
    {hmac, body} = Map.pop(callback, "hmac")

    conn(:post, "/?hmac=#{hmac || ""}", Jason.encode!(body))
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> WebhookPlug.call(WebhookPlug.init(provider: "paymob"))
  end

  test "checkout opens Paymob's card page for the plan's price", %{user: user, plan: plan} do
    {purchase, url} = checkout(user, plan)

    assert purchase.provider_ref == "217503754"
    assert url =~ "https://accept.paymob.com/unifiedcheckout/?publicKey=test_public_key"

    assert_received {:paymob_request, :post, "https://accept.paymob.com/v1/intention/", _headers,
                     body}

    assert body["amount"] == 15_000
    assert body["payment_methods"] == [4_097_558]
    assert body["special_reference"] == purchase.id
  end

  test "Paymob's callback pays the purchase and adds the rides, once", %{user: user, plan: plan} do
    {purchase, _url} = checkout(user, plan)
    callback = PaymobFixtures.callback(:paid, purchase.id)

    assert %{status: 200, resp_body: body} = post_callback(callback)
    assert Jason.decode!(body) == %{"status" => "processed"}
    assert status(purchase) == :paid
    assert rides(user) == 10

    assert Jason.decode!(post_callback(callback).resp_body) == %{"status" => "duplicate"}
    assert rides(user) == 10
  end

  test "the browser return and the callback count once between them", %{user: user, plan: plan} do
    {purchase, _url} = checkout(user, plan)

    assert {:ok, :processed} =
             Webhooks.handle("paymob", PaymobFixtures.redirect(:paid, purchase.id))

    assert {:ok, :duplicate} =
             Webhooks.handle("paymob", PaymobFixtures.callback(:paid, purchase.id))

    assert rides(user) == 10
  end

  test "a forged or unsigned message is rejected and nothing is stored", %{user: user, plan: plan} do
    {purchase, _url} = checkout(user, plan)
    forged = put_in(PaymobFixtures.callback(:paid, purchase.id), ["obj", "amount_cents"], 100)

    assert post_callback(forged).status == 401
    assert post_callback(Map.put(forged, "hmac", nil)).status == 401
    assert Ash.read!(ProviderEvent, authorize?: false) == []
    assert status(purchase) == :pending
  end

  test "the unsigned purchase id is ignored: the signed order decides", %{
    user: user,
    plan: plan
  } do
    {paid_for, _url} = checkout(user, plan)
    {:ok, other} = Purchases.start(user_fixture().id, plan.id, "paymob")

    # A redirect whose unsigned merchant_order_id points at another purchase still pays
    # the order Paymob signed, and only that one.
    assert {:ok, :processed} = Webhooks.handle("paymob", PaymobFixtures.redirect(:paid, other.id))
    assert status(paid_for) == :paid and status(other) == :pending

    # Paymob's own callback for that order then counts once, it's not blocked.
    assert {:ok, :duplicate} =
             Webhooks.handle("paymob", PaymobFixtures.callback(:paid, paid_for.id))
  end

  describe "a real signature on reshaped fields" do
    # Paymob signs its fields joined with no separator, so characters can be moved between
    # neighbours without breaking the signature. Every signed field must keep its exact
    # shape, so nothing can be moved.
    test "an order moved into another field can't pay another purchase", %{
      user: user,
      plan: plan
    } do
      {paid, _url} = checkout(user, plan)
      {:ok, :processed} = Webhooks.handle("paymob", PaymobFixtures.callback(:paid, paid.id))
      {:ok, unpaid} = Purchases.start(user.id, plan.id, "paymob")

      forged =
        PaymobFixtures.redirect(:paid, unpaid.id)
        |> Map.merge(%{"order" => "", "is_voided" => "false217503754"})

      assert {:error, _} = Webhooks.handle("paymob", forged)
      assert status(unpaid) == :pending
      assert rides(user) == 10
    end

    test "digits moved between the transaction and integration ids are refused", %{
      user: user,
      plan: plan
    } do
      {purchase, _url} = checkout(user, plan)

      forged =
        PaymobFixtures.redirect(:paid, purchase.id)
        |> Map.merge(%{"id" => "1920364654", "integration_id" => "097558"})

      assert {:error, _} = Webhooks.handle("paymob", forged)
      assert status(purchase) == :pending
    end

    test "a paid order can't be turned into a refund", %{user: user, plan: plan} do
      {purchase, _url} = checkout(user, plan)
      {:ok, :processed} = Webhooks.handle("paymob", PaymobFixtures.callback(:paid, purchase.id))

      forged =
        PaymobFixtures.redirect(:paid, purchase.id)
        |> Map.merge(%{
          "is_capture" => "falsefalse",
          "is_refunded" => "true",
          "is_standalone_payment" => ""
        })

      assert {:error, _} = Webhooks.handle("paymob", forged)
      assert status(purchase) == :paid
      assert rides(user) == 10
    end

    test "a message without a signed order id is refused", %{user: user, plan: plan} do
      {purchase, _url} = checkout(user, plan)
      forged = PaymobFixtures.redirect(:paid, purchase.id) |> Map.put("order", "")

      assert {:error, _} = Webhooks.handle("paymob", forged)
      assert status(purchase) == :pending
    end
  end

  test "a refund Paymob sends as its own transaction refunds the purchase", %{
    user: user,
    plan: plan
  } do
    {purchase, _url} = checkout(user, plan)
    {:ok, :processed} = Webhooks.handle("paymob", PaymobFixtures.callback(:paid, purchase.id))

    assert {:ok, :processed} =
             Webhooks.handle("paymob", PaymobFixtures.callback(:child_refund, purchase.id))

    assert status(purchase) == :refunded
    assert rides(user) == 0
  end

  test "a payment for another price is refused and kept for review", %{user: user} do
    cheap = plan_fixture(%{price: Decimal.new("100")})
    {purchase, _url} = checkout(user, cheap)

    assert {:ok, :failed} = Webhooks.handle("paymob", PaymobFixtures.callback(:paid, purchase.id))
    assert [%{status: :failed, error: error}] = Ash.read!(ProviderEvent, authorize?: false)
    assert error =~ "amount_mismatch"
    assert rides(user) == 0
  end

  test "paid after the checkout was cancelled: the rides are still given", %{
    user: user,
    plan: plan
  } do
    {purchase, _url} = checkout(user, plan)
    {:ok, _} = Purchases.cancel(purchase.id)

    assert {:ok, :processed} =
             Webhooks.handle("paymob", PaymobFixtures.callback(:paid, purchase.id))

    assert status(purchase) == :paid
    assert rides(user) == 10
  end

  test "paid another amount after the checkout was cancelled: kept for refund", %{user: user} do
    cheap = plan_fixture(%{price: Decimal.new("100")})
    {purchase, _url} = checkout(user, cheap)
    {:ok, _} = Purchases.cancel(purchase.id)

    assert {:ok, :processed} =
             Webhooks.handle("paymob", PaymobFixtures.callback(:paid, purchase.id))

    assert status(purchase) == :refund_required
    assert rides(user) == 0
  end

  test "a declined card fails the purchase; a later success still pays", %{user: user, plan: plan} do
    {purchase, _url} = checkout(user, plan)

    assert {:ok, :processed} =
             Webhooks.handle("paymob", PaymobFixtures.callback(:failed, purchase.id))

    assert status(purchase) == :failed

    assert {:ok, :processed} =
             Webhooks.handle("paymob", PaymobFixtures.callback(:paid, purchase.id))

    assert status(purchase) == :paid
  end

  test "a pending transaction changes nothing", %{user: user, plan: plan} do
    {purchase, _url} = checkout(user, plan)

    assert {:ok, :ignored} =
             Webhooks.handle("paymob", PaymobFixtures.callback(:pending, purchase.id))

    assert status(purchase) == :pending
  end

  test "a refund ends access and removes the unused rides", %{user: user, plan: plan} do
    {purchase, _url} = checkout(user, plan)
    {:ok, :processed} = Webhooks.handle("paymob", PaymobFixtures.callback(:paid, purchase.id))
    {:ok, _} = UdinBilling.consume(user.id, "rides", reference: "booking:1")

    assert {:ok, :processed} =
             Webhooks.handle("paymob", PaymobFixtures.callback(:refunded, purchase.id))

    assert status(purchase) == :refunded
    assert rides(user) == 0
  end

  test "a failed Paymob call cancels the checkout so the rider can retry", %{
    user: user,
    plan: plan
  } do
    PaymobStub.respond_with({500, %{"detail" => "down"}})

    assert {:error, {:paymob, _}} =
             UdinBilling.checkout(user.id, plan.id, "paymob", %{customer: @customer})

    assert [%{status: :cancelled}] = Ash.read!(Purchase, authorize?: false)
  end

  test "checkout needs the customer's name, email and phone", %{user: user, plan: plan} do
    assert {:error, {:missing_customer_fields, [:last_name, :email, :phone_number]}} =
             UdinBilling.checkout(user.id, plan.id, "paymob", %{customer: %{first_name: "Mona"}})

    refute_received {:paymob_request, _, _, _, _}
  end
end

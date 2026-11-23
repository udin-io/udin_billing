defmodule UdinBilling.Providers.PaymobTest do
  use UdinBilling.DataCase, async: false

  alias UdinBilling.Provider.Event
  alias UdinBilling.Providers.Paymob
  alias UdinBilling.Test.{PaymobFixtures, PaymobStub}

  setup do
    {:ok, {Paymob, opts}} = UdinBilling.Config.provider("paymob")
    {:ok, purchase} = UdinBilling.Purchases.start(user_fixture().id, plan_fixture().id, "paymob")
    %{opts: opts, purchase: purchase}
  end

  defp customer,
    do: %{
      first_name: "Mona",
      last_name: "Ali",
      email: "mona@example.com",
      phone_number: "+201000000000"
    }

  describe "create_checkout/3" do
    test "requires the customer's name, email and phone before calling Paymob",
         %{opts: opts, purchase: purchase} do
      assert {:error, {:missing_customer_fields, missing}} =
               Paymob.create_checkout(purchase, %{customer: %{first_name: "Mona"}}, opts)

      assert missing == [:last_name, :email, :phone_number]
      refute_received {:paymob_request, _, _, _, _}
    end

    test "creates an intention for the purchase and returns the hosted checkout URL",
         %{opts: opts, purchase: purchase} do
      PaymobStub.respond_with(
        {201,
         %{"id" => "pi_test_1", "client_secret" => "egy_csk_test_1", "intention_order_id" => 99}}
      )

      customer = %{
        first_name: "Mona",
        last_name: "Ali",
        email: "mona@example.com",
        phone_number: "+201000000000"
      }

      assert {:ok, session} =
               Paymob.create_checkout(purchase, %{customer: customer, item_name: "Weekly"}, opts)

      assert session.provider_ref == "99"
      assert session.metadata["paymob_intention_id"] == "pi_test_1"
      assert session.metadata["paymob_order_id"] == 99
      assert session.redirect_url =~ "/unifiedcheckout/?"
      assert session.redirect_url =~ "publicKey=test_public_key"
      assert session.redirect_url =~ "clientSecret=egy_csk_test_1"

      assert_received {:paymob_request, :post, url, headers, body}
      assert url == "https://accept.paymob.com/v1/intention/"
      assert {"authorization", "Token test_secret_key"} in headers
      assert body["amount"] == 15_000
      assert body["currency"] == "EGP"
      assert body["special_reference"] == purchase.id
      assert body["payment_methods"] == [4_097_558]
      assert body["notification_url"] == "https://app.example/billing/webhooks/paymob"
      assert body["billing_data"]["first_name"] == "Mona"
      assert body["billing_data"]["city"] == "NA"
      assert [%{"name" => "Weekly", "amount" => 15_000, "quantity" => 1}] = body["items"]
    end

    test "refuses a response without the order id messages will be matched by",
         %{opts: opts, purchase: purchase} do
      PaymobStub.respond_with({201, %{"id" => "pi_x", "client_secret" => "egy_csk_x"}})

      assert {:error, {:paymob_unexpected_response, _}} =
               Paymob.create_checkout(purchase, %{customer: customer()}, opts)
    end

    test "returns Paymob's error when the API refuses", %{opts: opts, purchase: purchase} do
      PaymobStub.respond_with({401, %{"detail" => "Invalid token"}})

      assert {:error, {:paymob, %ExPaymob.Error{status: 401}}} =
               Paymob.create_checkout(purchase, %{customer: customer()}, opts)
    end

    test "returns an error when Paymob can't be reached", %{opts: opts, purchase: purchase} do
      PaymobStub.respond_with({:error, :timeout})

      assert {:error, {:paymob, %ExPaymob.Error{}}} =
               Paymob.create_checkout(purchase, %{customer: customer()}, opts)
    end

    test "refuses amounts with fractions of a piaster", %{opts: opts, purchase: purchase} do
      assert {:error, {:amount_has_fractional_cents, _}} =
               Paymob.create_checkout(
                 %{purchase | amount: Decimal.new("10.005")},
                 %{customer: customer()},
                 opts
               )
    end
  end

  describe "parse_event/2" do
    test "verifies a callback and normalizes it", %{opts: opts, purchase: purchase} do
      assert {:ok, %Event{} = event} =
               Paymob.parse_event(PaymobFixtures.callback(:paid, purchase.id), %{}, opts)

      assert event.type == :payment_succeeded
      assert event.event_id == "192036465:payment_succeeded"
      assert event.provider_ref == "217503754"
      # Matched by the signed order id only; the unsigned purchase id is never used.
      assert event.purchase_id == nil
      assert event.provider_ref == "217503754"
      assert Decimal.equal?(event.amount, "150.00")
      assert event.currency == "EGP"
    end

    test "maps failed, pending and refunded transactions", %{opts: opts, purchase: purchase} do
      assert {:ok, %{type: :payment_failed, reason: "Do not honour"}} =
               Paymob.parse_event(PaymobFixtures.callback(:failed, purchase.id), %{}, opts)

      assert {:ok, %{type: :ignored}} =
               Paymob.parse_event(PaymobFixtures.callback(:pending, purchase.id), %{}, opts)

      assert {:ok, %{type: :refunded, event_id: "192036465:refunded"}} =
               Paymob.parse_event(PaymobFixtures.callback(:refunded, purchase.id), %{}, opts)
    end

    test "names the transaction a payment or refund is about", %{opts: opts, purchase: purchase} do
      assert {:ok, %{type: :payment_succeeded, payment_ref: "192036465"}} =
               Paymob.parse_event(PaymobFixtures.callback(:paid, purchase.id), %{}, opts)

      # A refund flagged on the paid transaction itself.
      assert {:ok, %{type: :refunded, payment_ref: "192036465"}} =
               Paymob.parse_event(PaymobFixtures.callback(:refunded, purchase.id), %{}, opts)

      # A refund sent as its own transaction names the payment it gives back.
      child =
        PaymobFixtures.callback(:child_refund, purchase.id)
        |> put_in(["obj", "parent_transaction"], 192_036_465)

      assert {:ok, %{type: :refunded, payment_ref: "192036465"} = event} =
               Paymob.parse_event(child, %{}, opts)

      # Replaying the stored message gives the same answer.
      assert {:ok, %{payment_ref: "192036465"}} = Paymob.parse_event(event.payload, %{}, opts)

      assert {:ok, %{type: :refunded, payment_ref: nil}} =
               Paymob.parse_event(PaymobFixtures.callback(:child_refund, purchase.id), %{}, opts)
    end

    test "accepts the browser redirect format with the same signature",
         %{opts: opts, purchase: purchase} do
      assert {:ok, redirect} =
               Paymob.parse_event(PaymobFixtures.redirect(:paid, purchase.id), %{}, opts)

      assert {:ok, callback} =
               Paymob.parse_event(PaymobFixtures.callback(:paid, purchase.id), %{}, opts)

      assert redirect.event_id == callback.event_id
      # Matched by the signed order id only; the unsigned purchase id is never used.
      assert redirect.purchase_id == nil
      assert redirect.provider_ref == "217503754"
      assert Decimal.equal?(redirect.amount, callback.amount)
    end

    test "stores only signed fields, without the customer's personal details",
         %{opts: opts, purchase: purchase} do
      callback =
        PaymobFixtures.callback(:paid, purchase.id)
        |> put_in(["obj", "billing_data"], %{
          "email" => "mona@example.com",
          "phone_number" => "+2010"
        })
        |> put_in(["obj", "order", "shipping_data"], %{"first_name" => "Mona"})

      assert {:ok, event} = Paymob.parse_event(callback, %{}, opts)
      refute inspect(event.payload) =~ "mona@example.com"
      refute inspect(event.payload) =~ "Mona"
      assert {:ok, _} = Paymob.parse_event(event.payload, %{}, opts)
    end

    test "reports a missing HMAC secret as a configuration error",
         %{opts: opts, purchase: purchase} do
      callback = PaymobFixtures.callback(:paid, purchase.id)

      assert {:error, :paymob_hmac_secret_missing} =
               Paymob.parse_event(callback, %{}, Keyword.delete(opts, :hmac_secret))
    end

    test "rejects tampered fields, wrong secrets and missing signatures",
         %{opts: opts, purchase: purchase} do
      paid = PaymobFixtures.callback(:paid, purchase.id)

      cheaper = put_in(paid, ["obj", "amount_cents"], 100)
      assert {:error, :invalid_signature} = Paymob.parse_event(cheaper, %{}, opts)

      flipped = put_in(PaymobFixtures.callback(:failed, purchase.id), ["obj", "success"], true)
      assert {:error, :invalid_signature} = Paymob.parse_event(flipped, %{}, opts)

      assert {:error, :invalid_signature} =
               Paymob.parse_event(paid, %{}, Keyword.put(opts, :hmac_secret, "another-secret"))

      assert {:error, :invalid_signature} =
               Paymob.parse_event(Map.delete(paid, "hmac"), %{}, opts)

      assert {:error, :invalid_signature} =
               Paymob.parse_event(Map.put(paid, "hmac", nil), %{}, opts)

      assert {:error, :invalid_signature} = Paymob.parse_event(%{}, %{}, opts)
    end
  end
end

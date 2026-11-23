defmodule UdinBilling.WebhooksTest do
  use UdinBilling.DataCase, async: false

  import Plug.Test

  alias UdinBilling.{Purchases, Webhooks, WebhookPlug}

  @secret "a-long-test-secret-value"
  @headers %{"x-fake-signature" => @secret}

  setup do
    user = user_fixture()
    plan = plan_fixture()
    {:ok, purchase} = Purchases.start(user.id, plan.id, "fake")
    %{user: user, plan: plan, purchase: purchase}
  end

  defp paid(purchase, extra \\ %{}) do
    Map.merge(
      %{
        "event_id" => "evt-#{purchase.id}",
        "type" => "payment_succeeded",
        "purchase_id" => purchase.id,
        "amount" => "150.00",
        "currency" => "EGP"
      },
      extra
    )
  end

  defp status(purchase), do: Ash.get!(Purchase, purchase.id, authorize?: false).status
  defp stored, do: Ash.read!(ProviderEvent, authorize?: false)

  test "the paid event is sent only once the whole message is committed", %{
    purchase: purchase
  } do
    test_pid = self()
    handler = "paid-after-commit-#{purchase.id}"

    # A listener that reloads data (a screen refreshing) must see the finished work.
    :telemetry.attach(
      handler,
      [:udin_billing, :purchase, :paid],
      fn _event, _measurements, _meta, _config ->
        send(test_pid, {:paid_seen, Enum.map(stored(), & &1.status)})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:ok, :processed} = Webhooks.handle("fake", paid(purchase), @headers)
    assert_received {:paid_seen, [:processed]}
  end

  test "a paid event is dropped when the message's transaction rolls back", %{
    purchase: purchase
  } do
    ref = :telemetry_test.attach_event_handlers(self(), [[:udin_billing, :purchase, :paid]])

    assert {:error, _rolled_back} =
             UdinBilling.Transaction.run(Purchase, fn ->
               {:ok, _} =
                 Purchases.confirm_payment(purchase.id, %{
                   provider_ref: purchase.provider_ref,
                   amount: Decimal.new("150.00"),
                   currency: "EGP"
                 })

               {:error, :boom}
             end)

    refute_received {[:udin_billing, :purchase, :paid], ^ref, _, _}
    assert status(purchase) == :pending
  end

  test "a payment is applied once", %{purchase: purchase} do
    assert {:ok, :processed} = Webhooks.handle("fake", paid(purchase), @headers)
    assert {:ok, :duplicate} = Webhooks.handle("fake", paid(purchase), @headers)
    assert status(purchase) == :paid
    assert [%{status: :processed, attempts: 1}] = stored()
  end

  test "unsigned or forged messages store nothing", %{purchase: purchase} do
    assert {:error, :invalid_signature} = Webhooks.handle("fake", paid(purchase), %{})

    assert {:error, :invalid_signature} =
             Webhooks.handle("fake", paid(purchase), %{"x-fake-signature" => "nope"})

    assert stored() == []
    assert {:error, :unknown_provider} = Webhooks.handle("stripe", %{}, %{})
  end

  test "business refusals are kept for review", %{purchase: purchase} do
    assert {:ok, :failed} =
             Webhooks.handle("fake", paid(purchase, %{"amount" => "1.00"}), @headers)

    assert {:ok, :failed} =
             Webhooks.handle(
               "fake",
               paid(purchase, %{"event_id" => "e2", "purchase_id" => "not-a-uuid"}),
               @headers
             )

    assert status(purchase) == :pending
    assert Enum.all?(stored(), &(&1.status == :failed and &1.error != nil))
  end

  test "a signed provider reference wins over an echoed purchase id", %{
    user: user,
    plan: plan,
    purchase: purchase
  } do
    {:ok, _} = Purchases.attach_provider_ref(purchase, "order-1")
    {:ok, other} = Purchases.start(user.id, plan.id, "fake")

    message = paid(other, %{"provider_ref" => "order-1"})
    assert {:ok, :failed} = Webhooks.handle("fake", message, @headers)
    assert [%{error: error}] = stored()
    assert error =~ "purchase_mismatch"
    assert status(purchase) == :pending and status(other) == :pending
  end

  test "failures and refunds", %{purchase: purchase} do
    assert {:ok, :processed} =
             Webhooks.handle(
               "fake",
               paid(purchase, %{
                 "event_id" => "f1",
                 "type" => "payment_failed",
                 "reason" => "declined"
               }),
               @headers
             )

    assert status(purchase) == :failed
    assert {:ok, :processed} = Webhooks.handle("fake", paid(purchase), @headers)

    assert {:ok, :processed} =
             Webhooks.handle(
               "fake",
               paid(purchase, %{"event_id" => "r1", "type" => "refunded"}),
               @headers
             )

    assert status(purchase) == :refunded

    assert {:ok, :ignored} =
             Webhooks.handle("fake", %{"event_id" => "t1", "type" => "ignored"}, @headers)
  end

  test "a customer_changed message applies the customer's state", %{user: user} do
    subscription_plan_fixture()
    start = DateTime.utc_now() |> DateTime.add(-60)

    message = %{
      "event_id" => "c1",
      "type" => "customer_changed",
      "user_id" => user.id,
      "customer" => %{
        "subscriptions" => [
          %{
            "provider_ref" => "s1",
            "product_id" => "basic_monthly",
            "period_starts_at" => DateTime.to_iso8601(start),
            "period_ends_at" => DateTime.to_iso8601(DateTime.shift(start, month: 1))
          }
        ]
      }
    }

    assert {:ok, :processed} = Webhooks.handle("fake", message, @headers)
    assert UdinBilling.enabled?(user.id, "share_recipe")

    assert {:ok, :failed} =
             Webhooks.handle(
               "fake",
               %{message | "event_id" => "c2", "user_id" => Ecto.UUID.generate()},
               @headers
             )
  end

  test "the outcome event names the customer, so an app can refresh their screens", %{
    user: user,
    purchase: purchase
  } do
    ref = :telemetry_test.attach_event_handlers(self(), [[:udin_billing, :webhook, :processed]])

    message = %{
      "event_id" => "c-telemetry",
      "type" => "customer_changed",
      "user_id" => user.id,
      "customer" => %{"subscriptions" => []}
    }

    {:ok, :processed} = Webhooks.handle("fake", message, @headers)
    assert_received {[:udin_billing, :webhook, :processed], ^ref, _, %{user_id: user_id}}
    assert user_id == user.id

    # A payment message names its purchase, not a user.
    {:ok, :processed} = Webhooks.handle("fake", paid(purchase), @headers)
    assert_received {[:udin_billing, :webhook, :processed], ^ref, _, %{user_id: nil}}
  end

  describe "a customer update that can't be fully applied" do
    defp customer_message(user, event_id, items) do
      %{
        "event_id" => event_id,
        "type" => "customer_changed",
        "user_id" => user.id,
        "customer" => %{"subscriptions" => items}
      }
    end

    defp sub_item(product_id, extra \\ %{}) do
      start = DateTime.utc_now() |> DateTime.add(-60)

      Map.merge(
        %{
          "provider_ref" => "s-#{product_id}",
          "product_id" => product_id,
          "period_starts_at" => DateTime.to_iso8601(start),
          "period_ends_at" => DateTime.to_iso8601(DateTime.shift(start, month: 1))
        },
        extra
      )
    end

    test "is marked failed with the reason, so it shows for review and can be replayed", %{
      user: user
    } do
      message = customer_message(user, "c-unknown", [sub_item("not_configured_monthly")])

      assert {:ok, :failed} = Webhooks.handle("fake", message, @headers)
      assert [%{status: :failed, error: error}] = stored()
      assert error =~ "unknown_product"
    end

    test "after the cause is fixed, a replay applies it", %{user: user} do
      message = customer_message(user, "c-later", [sub_item("basic_monthly")])
      {:ok, :failed} = Webhooks.handle("fake", message, @headers)

      subscription_plan_fixture()
      admin = user_fixture(%{admin: true})
      [event] = stored()

      assert {:ok, :processed} = UdinBilling.Admin.replay_provider_event(event.id, admin)
      assert UdinBilling.enabled?(user.id, "share_recipe")
    end

    test "a sandbox purchase refused on purpose isn't a failure", %{user: user} do
      subscription_plan_fixture()

      message =
        customer_message(user, "c-sandbox", [sub_item("basic_monthly", %{"sandbox" => true})])

      assert {:ok, :processed} = Webhooks.handle("fake", message, @headers)
    end
  end

  test "customer state is fetched from the provider when not inline", %{user: user} do
    subscription_plan_fixture()
    start = DateTime.add(DateTime.utc_now(), -60)

    state =
      sub_state(%{
        provider_ref: "s9",
        period_starts_at: start,
        period_ends_at: DateTime.shift(start, month: 1)
      })

    providers = %{
      "fake" =>
        {UdinBilling.Providers.Fake,
         secret: @secret, customers: %{user.id => %{subscriptions: [state], one_time: []}}}
    }

    with_env(:providers, providers, fn ->
      assert {:ok, :processed} =
               Webhooks.handle(
                 "fake",
                 %{"event_id" => "c3", "type" => "customer_changed", "user_id" => user.id},
                 @headers
               )
    end)

    assert UdinBilling.enabled?(user.id, "share_recipe")
  end

  test "admins replay a fixed message; others can't", %{user: user, purchase: purchase} do
    admin = user_fixture(%{admin: true})
    {:ok, :failed} = Webhooks.handle("fake", paid(purchase, %{"amount" => "1.00"}), @headers)
    [message] = stored()

    assert {:error, :forbidden} = UdinBilling.Admin.replay_provider_event(message.id, user)
    assert {:ok, :failed} = UdinBilling.Admin.replay_provider_event(message.id, admin)
    assert {:ok, [_]} = UdinBilling.Admin.list_provider_events(admin, status: :failed)
  end

  test "the fake provider refuses to run with a short secret", %{purchase: purchase} do
    with_env(:providers, %{"fake" => {UdinBilling.Providers.Fake, secret: ""}}, fn ->
      assert {:error, :fake_provider_secret_too_short} =
               Webhooks.handle("fake", paid(purchase), %{"x-fake-signature" => ""})
    end)
  end

  describe "WebhookPlug" do
    defp post(body, headers) do
      conn =
        conn(:post, "/", Jason.encode!(body))
        |> Plug.Conn.put_req_header("content-type", "application/json")

      conn = Enum.reduce(headers, conn, fn {k, v}, c -> Plug.Conn.put_req_header(c, k, v) end)
      WebhookPlug.call(conn, WebhookPlug.init(provider: "fake"))
    end

    test "200 processed / duplicate, 401 forged", %{purchase: purchase} do
      assert %{status: 200, resp_body: body} = post(paid(purchase), @headers)
      assert Jason.decode!(body) == %{"status" => "processed"}
      assert Jason.decode!(post(paid(purchase), @headers).resp_body) == %{"status" => "duplicate"}
      assert post(paid(purchase), %{"x-fake-signature" => "x"}).status == 401
    end
  end

  describe "checkout" do
    test "creates the purchase and returns the provider page", %{user: user, plan: plan} do
      assert {:ok, %{purchase: purchase, redirect_url: url}} =
               UdinBilling.checkout(user.id, plan.id, "fake")

      assert purchase.provider_ref == "fake_" <> purchase.id
      assert UdinBilling.Checkout.url(purchase) == url
      assert {:error, :unknown_provider} = UdinBilling.checkout(user.id, plan.id, "stripe")
    end
  end

  test "messages belong to the name the app registered the provider under" do
    # An app may register an adapter under its own name (Family-Corp: the Fake provider
    # as "paymob" in tests, or two Paymob accounts as "paymob_eg" and "paymob_ae").
    providers = %{"cards" => {UdinBilling.Providers.Fake, secret: @secret}}

    with_env(:providers, providers, fn ->
      user = user_fixture()
      plan = plan_fixture()
      {:ok, %{purchase: purchase}} = UdinBilling.checkout(user.id, plan.id, "cards")
      assert purchase.provider == "cards"

      assert {:ok, :processed} =
               Webhooks.handle(
                 "cards",
                 %{
                   "event_id" => "evt-cards-1",
                   "type" => "payment_succeeded",
                   "provider_ref" => purchase.provider_ref,
                   "amount" => "150.00",
                   "currency" => "EGP"
                 },
                 @headers
               )

      assert Ash.get!(Purchase, purchase.id, authorize?: false).status == :paid
      assert [%{provider: "cards"}] = Ash.read!(ProviderEvent, authorize?: false)
    end)
  end
end

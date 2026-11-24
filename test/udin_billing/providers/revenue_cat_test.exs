defmodule UdinBilling.Providers.RevenueCatTest do
  use UdinBilling.DataCase, async: false

  import Plug.Test

  alias UdinBilling.{Access, Subscriptions, Webhooks, WebhookPlug}

  @stub UdinBilling.Test.RevenueCatStub
  @auth %{"authorization" => "Bearer a-long-webhook-secret"}

  setup do
    free_plan_fixture()

    basic =
      subscription_plan_fixture(%{
        code: "basic_monthly",
        provider_product_ids: %{"revenuecat" => ["basic_monthly", "basic_monthly:monthly"]},
        features: %{"reel_imports" => 15, "share_recipe" => true}
      })

    subscription_plan_fixture(%{
      code: "plus_monthly",
      price: Decimal.new(360),
      provider_product_ids: %{"revenuecat" => "plus_monthly"},
      features: %{"reel_imports" => 40, "share_recipe" => true}
    })

    plan_fixture(%{
      code: "one_reel",
      price: Decimal.new(15),
      validity_unit: nil,
      validity_count: nil,
      provider_product_ids: %{"revenuecat" => "one_reel"},
      features: %{"reel_imports" => 1}
    })

    %{user: user_fixture(), basic: basic}
  end

  # -- helpers ----------------------------------------------------------------

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
  defp iso(dt), do: dt && DateTime.to_iso8601(dt)

  defp sub(start, extra \\ %{}) do
    Map.merge(
      %{
        "purchase_date" => iso(start),
        "original_purchase_date" => iso(start),
        "expires_date" => iso(DateTime.shift(start, month: 1)),
        "is_sandbox" => false,
        "store" => "app_store",
        "unsubscribe_detected_at" => nil,
        "grace_period_expires_date" => nil,
        "refunded_at" => nil,
        "period_type" => "normal",
        "ownership_type" => "PURCHASED"
      },
      extra
    )
  end

  # RevenueCat's GET /v1/subscribers answer, recording each request for assertions.
  defp customer(subscriptions, non_subscriptions \\ %{}) do
    test = self()

    Req.Test.stub(@stub, fn conn ->
      send(
        test,
        {:revenuecat_request, conn.request_path, Plug.Conn.get_req_header(conn, "authorization")}
      )

      Req.Test.json(conn, %{
        "request_date" => iso(now()),
        "subscriber" => %{
          "original_app_user_id" => "x",
          "subscriptions" => subscriptions,
          "non_subscriptions" => non_subscriptions,
          "subscriber_attributes" => %{"$email" => %{"value" => "mona@example.com"}}
        }
      })
    end)
  end

  defp event(user, type, extra \\ %{}) do
    %{
      "api_version" => "1.0",
      "event" =>
        Map.merge(
          %{
            "id" => "evt-#{System.unique_integer([:positive])}",
            "type" => type,
            "app_user_id" => user.id,
            "product_id" => "basic_monthly",
            "environment" => "PRODUCTION",
            "expiration_at_ms" => 1,
            "subscriber_attributes" => %{"$email" => %{"value" => "mona@example.com"}},
            "country_code" => "EG",
            "price" => 9.99
          },
          extra
        )
    }
  end

  defp access(user), do: Access.load(user.id)

  # -- webhook security ---------------------------------------------------------

  describe "webhook authorization" do
    test "only the configured Authorization header is accepted", %{user: user} do
      customer(%{})

      assert {:error, :invalid_signature} =
               Webhooks.handle("revenuecat", event(user, "RENEWAL"), %{})

      assert {:error, :invalid_signature} =
               Webhooks.handle("revenuecat", event(user, "RENEWAL"), %{
                 "authorization" => "Bearer wrong"
               })

      assert Ash.read!(ProviderEvent, authorize?: false) == []
      assert {:ok, :processed} = Webhooks.handle("revenuecat", event(user, "RENEWAL"), @auth)
    end

    test "a missing or short webhook secret is a configuration error", %{user: user} do
      {:ok, {mod, opts}} = UdinBilling.Config.provider("revenuecat")

      with_env(
        :providers,
        %{"revenuecat" => {mod, Keyword.put(opts, :webhook_auth, "short")}},
        fn ->
          assert {:error, :revenuecat_webhook_auth_missing} =
                   Webhooks.handle("revenuecat", event(user, "RENEWAL"), @auth)
        end
      )
    end

    test "the plug answers 401 / 200", %{user: user} do
      customer(%{"basic_monthly" => sub(DateTime.add(now(), -60))})

      call = fn headers ->
        conn =
          conn(:post, "/", Jason.encode!(event(user, "INITIAL_PURCHASE")))
          |> Plug.Conn.put_req_header("content-type", "application/json")

        conn = Enum.reduce(headers, conn, fn {k, v}, c -> Plug.Conn.put_req_header(c, k, v) end)
        WebhookPlug.call(conn, WebhookPlug.init(provider: "revenuecat"))
      end

      assert call.(%{}).status == 401
      assert call.(@auth).status == 200
      assert Access.enabled?(access(user), "share_recipe")
    end
  end

  # -- lifecycle ----------------------------------------------------------------

  describe "lifecycle through webhooks" do
    test "a purchase fetches the customer and grants the plan", %{user: user} do
      customer(%{"basic_monthly" => sub(DateTime.add(now(), -60))})

      assert {:ok, :processed} =
               Webhooks.handle("revenuecat", event(user, "INITIAL_PURCHASE"), @auth)

      assert_received {:revenuecat_request, path, ["Bearer sk_test_key"]}
      assert path == "/v1/subscribers/#{user.id}"

      a = access(user)
      assert Access.enabled?(a, "share_recipe")
      # Basic's 15: the subscription replaces the free plan's 3.
      assert Access.remaining(a, "reel_imports") == 15
    end

    test "the same event twice applies once", %{user: user} do
      customer(%{"basic_monthly" => sub(DateTime.add(now(), -60))})
      message = event(user, "INITIAL_PURCHASE")

      assert {:ok, :processed} = Webhooks.handle("revenuecat", message, @auth)
      assert {:ok, :duplicate} = Webhooks.handle("revenuecat", message, @auth)
      assert [_] = Ash.read!(Subscription, authorize?: false)
    end

    test "cancel keeps access until the period end; grace keeps it while retrying", %{user: user} do
      start = DateTime.add(now(), -60)
      customer(%{"basic_monthly" => sub(start, %{"unsubscribe_detected_at" => iso(now())})})

      {:ok, :processed} =
        Webhooks.handle(
          "revenuecat",
          event(user, "CANCELLATION", %{"cancel_reason" => "UNSUBSCRIBE"}),
          @auth
        )

      [sub] = Ash.read!(Subscription, authorize?: false)
      assert sub.auto_renew == false
      assert Access.enabled?(access(user), "share_recipe")

      ended = DateTime.add(now(), -3600)

      customer(%{
        "basic_monthly" =>
          sub(DateTime.shift(ended, month: -1), %{
            "expires_date" => iso(ended),
            "grace_period_expires_date" => iso(DateTime.add(now(), 3, :day))
          })
      })

      {:ok, :processed} = Webhooks.handle("revenuecat", event(user, "BILLING_ISSUE"), @auth)
      assert Access.enabled?(access(user), "share_recipe")
    end

    test "expiry and refund remove access", %{user: user} do
      start = DateTime.add(now(), -60)
      customer(%{"basic_monthly" => sub(start)})
      {:ok, :processed} = Webhooks.handle("revenuecat", event(user, "INITIAL_PURCHASE"), @auth)

      customer(%{"basic_monthly" => sub(start, %{"refunded_at" => iso(now())})})

      {:ok, :processed} =
        Webhooks.handle(
          "revenuecat",
          event(user, "CANCELLATION", %{"cancel_reason" => "CUSTOMER_SUPPORT"}),
          @auth
        )

      refute Access.enabled?(access(user), "share_recipe")
      assert Access.remaining(access(user), "reel_imports") == 3
    end

    test "a renewal starts a full new month", %{user: user} do
      first = DateTime.add(now(), -40, :day)

      customer(%{
        "basic_monthly" => sub(first, %{"expires_date" => iso(DateTime.add(now(), -10, :day))})
      })

      {:ok, :processed} = Webhooks.handle("revenuecat", event(user, "INITIAL_PURCHASE"), @auth)

      renewed = DateTime.add(now(), -10, :day)
      customer(%{"basic_monthly" => sub(renewed)})
      {:ok, :processed} = Webhooks.handle("revenuecat", event(user, "RENEWAL"), @auth)

      assert [%{period_starts_at: starts}] = Ash.read!(Subscription, authorize?: false)
      assert DateTime.compare(starts, renewed) == :eq

      assert Access.remaining(access(user), "reel_imports") == 15
    end

    test "an upgrade with :shift keeps this month's use, regardless of report order", %{
      user: user
    } do
      with_env(:upgrade_policy, :shift, fn ->
        start = DateTime.add(now(), -3, :day)
        customer(%{"basic_monthly" => sub(start)})
        {:ok, :processed} = Webhooks.handle("revenuecat", event(user, "INITIAL_PURCHASE"), @auth)

        for n <- 1..10,
            do: {:ok, _} = UdinBilling.consume(user.id, "reel_imports", reference: "e#{n}")

        upgraded = DateTime.add(now(), -60)

        # Apple ends the old subscription at the upgrade and starts the new one.
        customer(%{
          "plus_monthly" => sub(upgraded),
          "basic_monthly" => sub(start, %{"expires_date" => iso(upgraded)})
        })

        {:ok, :processed} = Webhooks.handle("revenuecat", event(user, "PRODUCT_CHANGE"), @auth)

        # Plus 40 − 10 used (the free plan is replaced while subscribed)
        assert Access.remaining(access(user), "reel_imports") == 30
      end)
    end

    test "Google Play's product:base_plan id maps to the same plan", %{user: user, basic: basic} do
      customer(%{
        "basic_monthly:monthly" => sub(DateTime.add(now(), -60), %{"store" => "play_store"})
      })

      {:ok, :processed} =
        Webhooks.handle(
          "revenuecat",
          event(user, "INITIAL_PURCHASE", %{"product_id" => "basic_monthly:monthly"}),
          @auth
        )

      assert [%{plan_id: plan_id}] = Ash.read!(Subscription, authorize?: false)
      assert plan_id == basic.id
    end

    test "records the store each subscription was bought in", %{user: user} do
      customer(%{
        "basic_monthly:monthly" => sub(DateTime.add(now(), -60), %{"store" => "play_store"})
      })

      {:ok, :processed} = Webhooks.handle("revenuecat", event(user, "INITIAL_PURCHASE"), @auth)

      assert [%{store: "play_store"}] = Ash.read!(Subscription, authorize?: false)
    end

    test "sandbox purchases count only when allowed", %{user: user} do
      customer(%{"basic_monthly" => sub(DateTime.add(now(), -60), %{"is_sandbox" => true})})
      {:ok, :processed} = Webhooks.handle("revenuecat", event(user, "INITIAL_PURCHASE"), @auth)
      refute Access.enabled?(access(user), "share_recipe")

      with_env(:allow_sandbox, true, fn ->
        assert {:ok, %{applied: 1}} = UdinBilling.sync_customer("revenuecat", user.id)
      end)

      assert Access.enabled?(access(user), "share_recipe")
    end
  end

  describe "one-time top-ups" do
    test "a single-reel purchase adds one never-expiring reel; a refund removes it", %{user: user} do
      top_up = %{
        "one_reel" => [
          %{
            "id" => "rc1",
            "store_transaction_id" => "txn-1",
            "purchase_date" => iso(DateTime.add(now(), -60)),
            "is_sandbox" => false,
            "store" => "app_store"
          }
        ]
      }

      customer(%{}, top_up)

      {:ok, :processed} =
        Webhooks.handle(
          "revenuecat",
          event(user, "NON_RENEWING_PURCHASE", %{
            "product_id" => "one_reel",
            "expiration_at_ms" => nil
          }),
          @auth
        )

      assert Access.remaining(access(user), "reel_imports") == 4

      refund =
        event(user, "CANCELLATION", %{
          "product_id" => "one_reel",
          "cancel_reason" => "CUSTOMER_SUPPORT",
          "expiration_at_ms" => nil,
          "transaction_id" => "txn-1"
        })

      assert {:ok, :processed} = Webhooks.handle("revenuecat", refund, @auth)
      assert Access.remaining(access(user), "reel_imports") == 3
    end

    test "syncing twice records a top-up once", %{user: user} do
      customer(%{}, %{
        "one_reel" => [
          %{
            "id" => "rc2",
            "store_transaction_id" => "txn-2",
            "purchase_date" => iso(now()),
            "is_sandbox" => false
          }
        ]
      })

      {:ok, _} = UdinBilling.sync_customer("revenuecat", user.id)
      {:ok, _} = UdinBilling.sync_customer("revenuecat", user.id)
      assert [_] = Ash.read!(Purchase, authorize?: false)
    end
  end

  describe "edge cases" do
    test "test pings and transfers are ignored", %{user: user} do
      assert {:ok, :ignored} = Webhooks.handle("revenuecat", event(user, "TEST"), @auth)
      assert {:ok, :ignored} = Webhooks.handle("revenuecat", event(user, "TRANSFER"), @auth)
      refute_received {:revenuecat_request, _, _}
    end

    test "anonymous or unknown users are kept for review", %{user: user} do
      assert {:ok, :failed} =
               Webhooks.handle(
                 "revenuecat",
                 event(%{user | id: "$RCAnonymousID:abc"}, "INITIAL_PURCHASE"),
                 @auth
               )

      assert {:ok, :failed} =
               Webhooks.handle(
                 "revenuecat",
                 event(%{user | id: Ecto.UUID.generate()}, "INITIAL_PURCHASE"),
                 @auth
               )
    end

    test "RevenueCat down: nothing applied, the retry applies it", %{user: user} do
      Req.Test.stub(@stub, &Plug.Conn.send_resp(&1, 503, "down"))
      message = event(user, "INITIAL_PURCHASE")

      assert {:error, {:fetch_customer_failed, {:revenuecat_http, 503}}} =
               Webhooks.handle("revenuecat", message, @auth)

      customer(%{"basic_monthly" => sub(DateTime.add(now(), -60))})
      assert {:ok, :processed} = Webhooks.handle("revenuecat", message, @auth)
      assert Access.enabled?(access(user), "share_recipe")
    end

    test "an entry with an unreadable date is skipped and the rest still applies", %{
      user: user
    } do
      customer(
        %{
          "basic_monthly" => sub(DateTime.add(now(), -60)),
          "plus_monthly" => sub(DateTime.add(now(), -60), %{"purchase_date" => "not a date"})
        },
        %{"one_reel" => [%{"id" => "tx-1", "purchase_date" => "2026-13-45"}]}
      )

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, :processed} =
                   Webhooks.handle("revenuecat", event(user, "INITIAL_PURCHASE"), @auth)
        end)

      assert log =~ "plus_monthly"
      assert log =~ "one_reel"
      assert Access.remaining(access(user), "reel_imports") == 15
    end

    test "a subscription can't move to another account", %{user: user} do
      start = DateTime.add(now(), -60)

      {:ok, _} =
        Subscriptions.apply_state("revenuecat", user.id, %{
          provider_ref: "shared",
          product_id: "basic_monthly",
          period_starts_at: start,
          period_ends_at: DateTime.shift(start, month: 1)
        })

      other = user_fixture()

      assert {:error, {:owned_by_another_user, _}} =
               Subscriptions.apply_state("revenuecat", other.id, %{
                 provider_ref: "shared",
                 product_id: "basic_monthly",
                 period_starts_at: start,
                 period_ends_at: DateTime.shift(start, month: 1)
               })
    end

    test "only identifiers are stored from the event, no personal data", %{user: user} do
      customer(%{})
      {:ok, _} = Webhooks.handle("revenuecat", event(user, "RENEWAL"), @auth)
      [stored] = Ash.read!(ProviderEvent, authorize?: false)
      refute inspect(stored) =~ "mona@example.com"
      refute inspect(stored) =~ "country_code"
    end
  end
end

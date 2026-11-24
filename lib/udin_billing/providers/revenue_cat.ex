defmodule UdinBilling.Providers.RevenueCat do
  @moduledoc """
  App Store and Google Play subscriptions and one-time purchases through RevenueCat.

  ## How it works
  The mobile app buys with the RevenueCat SDK, after logging the user in with their
  **server user id** (`Purchases.logIn(user.id)`), so every purchase is tied to our user.
  Billing state then comes from RevenueCat in two ways, both ending in
  `UdinBilling.Subscriptions.apply_customer/4`:

    * **Webhooks** (`UdinBilling.WebhookPlug`, provider `"revenuecat"`): RevenueCat sends
      the configured `Authorization` header; it's checked in constant time. Every
      billing event becomes "this customer changed", and the customer's full current
      state is fetched from `GET /v1/subscribers/{app_user_id}`, as RevenueCat
      recommends. One code path for every event type, and a missed or out-of-order event
      can't leave access wrong.
    * **Sync** (`UdinBilling.sync_customer/2`): the app calls the backend right after a
      purchase or on "Restore purchases"; same fetch, same code.

  ## Mapping
    * `subscriber.subscriptions[product]` → a subscription: period = `purchase_date` →
      `expires_date`; cancelled when `unsubscribe_detected_at` is set (access until the
      period end); `grace_period_expires_date`; `refunded_at`; `is_sandbox`.
      Its reference is `"<user id>:<product id>"`: renewals of a product update one row,
      and a new product (plan change) creates a new one.
    * `subscriber.non_subscriptions[product][]` → a one-time purchase per store
      transaction (the single-reel top-up).
    * A refund of a one-time purchase arrives as a `CANCELLATION` with
      `cancel_reason: CUSTOMER_SUPPORT` and no expiration; it refunds that purchase by its
      store transaction id. Subscription refunds come through the fetched `refunded_at`.
    * `TEST` and non-billing events are ignored. `TRANSFER` is ignored: configure the
      RevenueCat project to keep purchases with their original App User ID, so access
      never moves between accounts (a transfer would be refused anyway).

  Only what's needed to identify the event is stored (no subscriber attributes, prices or
  country).

  ## Options (in `runtime.exs`, secrets from env)
    * `:api_key` - the project's **secret** API key (`sk_...`), server only.
    * `:webhook_auth` - the exact `Authorization` header value set on the RevenueCat
      webhook (at least 16 characters).
    * `:base_url` - default `"https://api.revenuecat.com"`.
    * `:req_options` - extra `Req` options (tests: `plug: {Req.Test, ...}`).
  """
  @behaviour UdinBilling.Provider

  alias UdinBilling.Provider.Event

  require Logger

  @base_url "https://api.revenuecat.com"

  # Events whose meaning is "the customer's purchases changed".
  @billing_events ~w(INITIAL_PURCHASE RENEWAL CANCELLATION UNCANCELLATION NON_RENEWING_PURCHASE
                     SUBSCRIPTION_PAUSED EXPIRATION BILLING_ISSUE PRODUCT_CHANGE
                     SUBSCRIPTION_EXTENDED REFUND_REVERSED TEMPORARY_ENTITLEMENT_GRANT)

  @stored_fields ~w(id type app_user_id product_id transaction_id cancel_reason environment)

  @impl true
  def parse_event(params, headers, opts) do
    with {:ok, expected} <- webhook_auth(opts),
         :ok <- verify(Map.get(headers, "authorization"), expected),
         {:ok, event} <- event(params) do
      {:ok, to_event(event)}
    end
  end

  @impl true
  def fetch_customer(user_id, opts) do
    with {:ok, api_key} <- api_key(opts),
         {:ok, body} <- get_subscriber(user_id, api_key, opts) do
      {:ok, to_customer(body["subscriber"] || %{}, user_id)}
    end
  end

  # -- webhook ----------------------------------------------------------------

  defp webhook_auth(opts) do
    case Keyword.get(opts, :webhook_auth) do
      value when is_binary(value) and byte_size(value) >= 16 -> {:ok, value}
      _ -> {:error, :revenuecat_webhook_auth_missing}
    end
  end

  defp verify(received, expected) when is_binary(received) do
    if Plug.Crypto.secure_compare(received, expected), do: :ok, else: {:error, :invalid_signature}
  end

  defp verify(_received, _expected), do: {:error, :invalid_signature}

  defp event(%{"event" => %{"id" => id, "type" => type} = event})
       when is_binary(id) and is_binary(type),
       do: {:ok, event}

  defp event(_params), do: {:error, :malformed_event}

  defp to_event(event) do
    base = %Event{
      provider: "revenuecat",
      event_id: event["id"],
      type: :ignored,
      user_id: event["app_user_id"],
      payload: %{"event" => Map.take(event, @stored_fields)}
    }

    cond do
      one_time_refund?(event) ->
        %{base | type: :refunded, provider_ref: event["transaction_id"]}

      event["type"] in @billing_events ->
        %{base | type: :customer_changed}

      true ->
        if event["type"] == "TRANSFER",
          do:
            Logger.warning(
              "udin_billing: RevenueCat TRANSFER ignored; keep purchases with their original App User ID"
            )

        base
    end
  end

  # A refunded one-time purchase (no expiration); subscription refunds come via the fetch.
  defp one_time_refund?(event) do
    event["type"] == "CANCELLATION" and event["cancel_reason"] == "CUSTOMER_SUPPORT" and
      is_nil(event["expiration_at_ms"]) and is_binary(event["transaction_id"])
  end

  # -- REST -------------------------------------------------------------------

  defp api_key(opts) do
    case Keyword.get(opts, :api_key) do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, :revenuecat_api_key_missing}
    end
  end

  defp get_subscriber(user_id, api_key, opts) do
    [
      method: :get,
      url:
        Keyword.get(opts, :base_url, @base_url) <>
          "/v1/subscribers/" <> URI.encode(user_id, &URI.char_unreserved?/1),
      headers: [{"authorization", "Bearer " <> api_key}],
      receive_timeout: 15_000,
      retry: :transient
    ]
    |> Keyword.merge(Keyword.get(opts, :req_options, []))
    |> Req.request()
    |> case do
      {:ok, %Req.Response{status: 200, body: %{} = body}} -> {:ok, body}
      {:ok, %Req.Response{status: status}} -> {:error, {:revenuecat_http, status}}
      {:error, exception} -> {:error, {:revenuecat_unreachable, Exception.message(exception)}}
    end
  end

  # An entry whose dates can't be read is skipped with a warning: one bad entry must not
  # turn every message for this user into a retry loop, and the rest still applies.
  defp to_customer(subscriber, user_id) do
    %{
      subscriptions:
        subscriber
        |> Map.get("subscriptions", %{})
        |> Enum.flat_map(fn {product_id, sub} -> subscription(user_id, product_id, sub) end),
      one_time:
        for {product_id, items} <- Map.get(subscriber, "non_subscriptions", %{}),
            item <- List.wrap(items),
            ref = item["store_transaction_id"] || item["id"],
            is_binary(ref),
            entry <- one_time(user_id, product_id, ref, item) do
          entry
        end
    }
  end

  defp subscription(user_id, product_id, sub) do
    with %DateTime{} = starts_at <- time(sub["purchase_date"]),
         %DateTime{} = ends_at <- time(sub["expires_date"]) do
      [
        %{
          provider_ref: "#{user_id}:#{product_id}",
          product_id: product_id,
          period_starts_at: starts_at,
          period_ends_at: ends_at,
          auto_renew: is_nil(sub["unsubscribe_detected_at"]),
          grace_ends_at: time(sub["grace_period_expires_date"]),
          refunded_at: time(sub["refunded_at"]),
          sandbox: sub["is_sandbox"] == true,
          store: sub["store"]
        }
      ]
    else
      nil -> skip(user_id, product_id, "purchase_date or expires_date")
    end
  end

  defp one_time(user_id, product_id, ref, item) do
    case time(item["purchase_date"]) do
      %DateTime{} = paid_at ->
        [
          %{
            provider_ref: ref,
            product_id: product_id,
            paid_at: paid_at,
            sandbox: item["is_sandbox"] == true
          }
        ]

      nil ->
        skip(user_id, product_id, "purchase_date")
    end
  end

  defp skip(user_id, product_id, fields) do
    Logger.warning("RevenueCat: skipped #{product_id} for user #{user_id}, unreadable #{fields}")
    []
  end

  defp time(value) when not is_binary(value), do: nil

  defp time(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _} -> nil
    end
  end
end

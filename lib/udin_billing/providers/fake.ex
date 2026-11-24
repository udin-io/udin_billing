defmodule UdinBilling.Providers.Fake do
  @moduledoc """
  A stand-in provider for tests and local development. It never moves money.

  **Never configure it in production**: anyone who knows its secret can mark purchases
  paid. Its secret must be at least 16 bytes.

      config :udin_billing, :providers, %{"fake" => {UdinBilling.Providers.Fake, secret: "a-long-test-secret"}}

  Messages are flat maps signed with the secret in an `x-fake-signature` header (or a
  `"signature"` param):

      %{"event_id" => "evt_1", "type" => "payment_succeeded", "purchase_id" => id,
        "amount" => "150.00", "currency" => "EGP"}

      %{"event_id" => "evt_2", "type" => "customer_changed", "user_id" => id,
        "customer" => %{"subscriptions" => [...], "one_time" => [...]}}

  `create_checkout/3` returns `fake_<purchase id>`; `fetch_customer/2` returns
  `opts[:customers][user_id]` (empty by default).
  """
  @behaviour UdinBilling.Provider

  alias UdinBilling.Provider.Event

  @types %{
    "payment_succeeded" => :payment_succeeded,
    "payment_failed" => :payment_failed,
    "refunded" => :refunded,
    "customer_changed" => :customer_changed,
    "ignored" => :ignored
  }

  @impl true
  def create_checkout(purchase, checkout, _opts) do
    # Echoes the item name so tests can see what a real payment page would show.
    {:ok,
     %{
       provider_ref: "fake_" <> purchase.id,
       redirect_url: "https://fake.invalid/checkout/" <> purchase.id,
       metadata: %{"item_name" => checkout[:item_name]}
     }}
  end

  @impl true
  def fetch_customer(user_id, opts) do
    {:ok,
     opts |> Keyword.get(:customers, %{}) |> Map.get(user_id, %{subscriptions: [], one_time: []})}
  end

  @impl true
  def parse_event(params, headers, opts) do
    signature = Map.get(headers, "x-fake-signature") || Map.get(params, "signature")

    with {:ok, secret} <- secret(opts),
         :ok <- verify(signature, secret),
         {:ok, type} <- type(params["type"]) do
      {:ok,
       %Event{
         provider: "fake",
         event_id: params["event_id"],
         type: type,
         provider_ref: params["provider_ref"],
         payment_ref: params["payment_ref"],
         purchase_id: params["purchase_id"],
         user_id: params["user_id"],
         customer: customer(params["customer"]),
         amount: params["amount"] && Decimal.new(params["amount"]),
         currency: params["currency"],
         reason: params["reason"],
         payload: Map.delete(params, "signature")
       }}
    end
  end

  defp secret(opts) do
    case Keyword.get(opts, :secret) do
      secret when is_binary(secret) and byte_size(secret) >= 16 -> {:ok, secret}
      _ -> {:error, :fake_provider_secret_too_short}
    end
  end

  defp verify(signature, secret) when is_binary(signature) do
    if Plug.Crypto.secure_compare(signature, secret), do: :ok, else: {:error, :invalid_signature}
  end

  defp verify(_signature, _secret), do: {:error, :invalid_signature}

  defp type(type) do
    case Map.fetch(@types, type || "") do
      {:ok, type} -> {:ok, type}
      :error -> {:error, :unknown_event_type}
    end
  end

  defp customer(nil), do: nil

  defp customer(customer) do
    %{
      subscriptions: Enum.map(Map.get(customer, "subscriptions", []), &subscription/1),
      one_time: Enum.map(Map.get(customer, "one_time", []), &one_time/1)
    }
  end

  defp subscription(item) do
    %{
      provider_ref: item["provider_ref"],
      product_id: item["product_id"],
      period_starts_at: time(item["period_starts_at"]),
      period_ends_at: time(item["period_ends_at"]),
      auto_renew: Map.get(item, "auto_renew", true),
      grace_ends_at: time(item["grace_ends_at"]),
      refunded_at: time(item["refunded_at"]),
      sandbox: Map.get(item, "sandbox", false)
    }
  end

  defp one_time(item) do
    %{
      provider_ref: item["provider_ref"],
      product_id: item["product_id"],
      paid_at: time(item["paid_at"]),
      refunded_at: time(item["refunded_at"]),
      sandbox: Map.get(item, "sandbox", false)
    }
  end

  defp time(nil), do: nil

  defp time(value) do
    {:ok, datetime, _offset} = DateTime.from_iso8601(value)
    datetime
  end
end

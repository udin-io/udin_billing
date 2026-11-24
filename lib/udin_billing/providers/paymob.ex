defmodule UdinBilling.Providers.Paymob do
  @moduledoc """
  Paymob (Egypt, UAE, KSA, Oman) through the Unified Checkout "Intention" API, built on
  the team's `ex_paymob` client.

  ## Why a wrapper around ex_paymob
  `ex_paymob` does the Paymob-specific work: the HTTP calls and the HMAC-SHA512 signature
  check. This module only translates between Paymob and billing: it turns a purchase
  into an intention, and a verified Paymob message into a `UdinBilling.Provider.Event`.

  ## Checkout
  `create_checkout/3` creates an intention with the purchase id as `special_reference`
  (Paymob returns it as the order's `merchant_order_id`), then returns the hosted
  checkout URL. The user pays on Paymob's page.

  ## Messages from Paymob
  Paymob reports a result twice:
    * the server-to-server "transaction processed" callback, a POST with the
      transaction under `"obj"` and the signature in the `hmac` query parameter. This is
      the source of truth;
    * the user's browser redirect, a GET with the same fields flattened into the query
      (`"order"`, `"source_data.pan"`, ...). It's converted to the callback shape so the
      same signature check applies.

  A missing or wrong `hmac` returns `{:error, :invalid_signature}`.

  ## Why every signed field must keep its exact shape
  Paymob's signature covers its fields joined with no separator, so characters can be moved
  between neighbouring fields without breaking it (an empty order id with `is_voided` set to
  `"false217503754"` signs the same as the real message). A verified message is therefore
  also checked for shape, or refused with `{:error, {:malformed_event, fields}}`: booleans
  exactly `true`/`false`, amounts and ids digits without a leading zero, the currency three
  capital letters, `created_at` a timestamp, the integration one of this app's
  `:integrations`, and the order id present. With every field pinned, nothing can move.

  ## Matching a message to a purchase
  Paymob signs the order id but not `merchant_order_id` (our purchase id), and the
  redirect travels through the customer's browser. So the checkout stores Paymob's order
  id as the purchase's `provider_ref`, and messages are matched by that signed id only;
  `merchant_order_id` is kept for people reading the stored message, never used to find
  the purchase. Only the signed fields and the few billing needs are stored; customer
  details in Paymob's payload are dropped.

  ## Options (per app, usually in `runtime.exs`)
    * `:secret_key`, `:public_key`, `:hmac_secret` - from the Paymob dashboard.
    * `:integrations` - integration id per payment method, e.g.
      `%{card: 4097558, wallet: 4097559}`. Configuring a method doesn't offer it.
    * `:enabled_methods` - the methods riders see, e.g. `[:card]` (default). Turning
      wallet on later is a config change: add `:wallet` here.
    * `:notification_url`, `:redirection_url` - your webhook and return pages.
    * `:region` (`:egypt` default, `:uae`, `:ksa`, `:oman`) or `:base_url`.
    * `:billing_defaults` - value for the address fields Paymob's form needs but the app
      doesn't collect (apartment, street, city, ...), default `"NA"`. First name, last
      name, email and phone are required from the app and never defaulted.

    * `:http_client` - an `ExPaymob.HttpClient` module, for tests.

  The checkout must pass `customer: %{first_name:, last_name:, email:, phone_number:}`;
  without them `create_checkout/3` returns `{:error, {:missing_customer_fields, [...]}}`.
  `redirection_url` only applies to card and wallet payments (Paymob's rule).

  ## Payment methods
  Paymob's checkout page shows the methods whose integration ids the intention lists. The
  adapter sends the ids of `:enabled_methods` only, so a configured but disabled method
  (wallet, today) is never offered. A checkout may narrow it further with
  `checkout.methods` (e.g. `[:card]`), never widen it. An enabled method without an
  integration id is a configuration error, reported before calling Paymob.

  Payments already made through any configured integration are always accepted, even if
  the method was disabled afterwards: the money was taken.

  ## Refunds
  A refunded or voided transaction (`is_refunded` / `is_voided`) refunds the whole
  purchase: access ends and unused units are revoked. So does a refund or void Paymob
  reports as its own transaction on the order (`has_parent_transaction`, successful, not a
  capture). Partial refunds are treated the same, because a bundle can't be partly
  refunded.

  Each message names its transaction (`payment_ref`): the payment's own id, or for a
  refund sent as its own transaction, its `parent_transaction`. That's how a refund of
  the second charge of an order paid twice reaches that charge, not the plan. The child-transaction form follows Paymob's documentation; confirm it with a
  real sandbox refund.

  All options are passed to `ex_paymob` per request, so each host app keeps its own keys
  and nothing is read from global `:ex_paymob` config unless an option is missing.
  """
  @behaviour UdinBilling.Provider

  alias UdinBilling.Provider.Event

  @billing_fields ~w(apartment street building city country floor state postal_code)

  # Keys of the browser redirect that are nested in the callback's "obj".
  @redirect_nested %{
    "order" => ["order", "id"],
    "source_data.pan" => ["source_data", "pan"],
    "source_data.sub_type" => ["source_data", "sub_type"],
    "source_data.type" => ["source_data", "type"],
    "merchant_order_id" => ["order", "merchant_order_id"],
    "data.message" => ["data", "message"]
  }

  @impl true
  def create_checkout(purchase, checkout, opts) do
    with :ok <- require_customer(Map.get(checkout, :customer, %{})),
         {:ok, integration_ids} <- integration_ids(checkout, opts),
         {:ok, cents} <- to_cents(purchase.amount),
         {:ok, body} <-
           ExPaymob.Intention.create(
             intention(purchase, cents, integration_ids, checkout, opts),
             opts
           ),
         {:ok, intention_id, client_secret, order_id} <- read_intention(body) do
      {:ok,
       %{
         # Paymob signs the order id in every callback; the intention id isn't sent back.
         provider_ref: to_string(order_id),
         redirect_url:
           ExPaymob.Intention.checkout_url(client_secret, Keyword.fetch!(opts, :public_key), opts),
         metadata: %{
           "paymob_intention_id" => intention_id,
           "paymob_order_id" => order_id
         }
       }}
    else
      {:error, %ExPaymob.Error{} = error} -> {:error, {:paymob, error}}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def parse_event(params, _headers, opts) do
    with :ok <- require_hmac_secret(opts),
         {:ok, payload, hmac} <- callback_shape(params),
         :ok <- ExPaymob.Webhook.verify_hmac(payload, hmac, opts),
         :ok <- check_signed_shape(payload["obj"], opts) do
      {:ok, to_event(payload["obj"], hmac)}
    else
      {:error, :invalid_hmac} -> {:error, :invalid_signature}
      {:error, _reason} = error -> error
    end
  end

  # Paymob rejects an intention without these (per its Intention API collection); checking
  # first gives the app a clear error instead of an opaque API failure.
  @required_customer [:first_name, :last_name, :email, :phone_number]

  defp require_customer(customer) do
    case Enum.filter(@required_customer, &(Map.get(customer, &1) in [nil, ""])) do
      [] -> :ok
      missing -> {:error, {:missing_customer_fields, missing}}
    end
  end

  # ex_paymob would fall back to the PAYMOB_HMAC_SECRET env var and crash on nil; a
  # missing secret is a configuration error and is reported as one.
  defp require_hmac_secret(opts) do
    case Keyword.get(opts, :hmac_secret) do
      secret when is_binary(secret) and secret != "" -> :ok
      _ -> {:error, :paymob_hmac_secret_missing}
    end
  end

  # -- checkout ---------------------------------------------------------------

  @methods [:card, :wallet]

  @doc """
  Integration ids to offer for a checkout: the enabled methods (narrowed by
  `checkout.methods` when given), each of which must have an integration id.
  """
  @spec integration_ids(map(), keyword()) :: {:ok, [integer()]} | {:error, term()}
  def integration_ids(checkout, opts) do
    enabled = Keyword.get(opts, :enabled_methods, [:card])
    integrations = Keyword.get(opts, :integrations, %{})
    requested = Map.get(checkout, :methods, enabled)

    with :ok <- known_methods(enabled ++ requested),
         :ok <- subset(requested, enabled),
         {:ok, ids} <- ids_for(requested, integrations) do
      if ids == [], do: {:error, :no_payment_method_enabled}, else: {:ok, ids}
    end
  end

  defp known_methods(methods) do
    case Enum.reject(methods, &(&1 in @methods)) do
      [] -> :ok
      unknown -> {:error, {:unknown_payment_methods, unknown}}
    end
  end

  defp subset(requested, enabled) do
    case requested -- enabled do
      [] -> :ok
      disabled -> {:error, {:payment_methods_disabled, disabled}}
    end
  end

  defp ids_for(methods, integrations) do
    methods
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, []}, fn method, {:ok, ids} ->
      case Map.get(integrations, method) do
        id when is_integer(id) -> {:cont, {:ok, [id | ids]}}
        _ -> {:halt, {:error, {:payment_method_not_configured, method}}}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, Enum.reverse(ids)}
      error -> error
    end
  end

  defp intention(purchase, cents, integration_ids, checkout, opts) do
    item_name = Map.get(checkout, :item_name, "Plan")

    %{
      amount: cents,
      currency: purchase.currency,
      payment_methods: integration_ids,
      items: [%{name: item_name, amount: cents, description: item_name, quantity: 1}],
      billing_data: billing_data(Map.get(checkout, :customer, %{}), opts),
      special_reference: purchase.id,
      notification_url: Keyword.get(opts, :notification_url),
      redirection_url: Keyword.get(opts, :redirection_url),
      expiration: UdinBilling.Config.checkout_ttl()
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp billing_data(customer, opts) do
    default = Keyword.get(opts, :billing_defaults, "NA")

    @billing_fields
    |> Map.new(&{&1, default})
    |> Map.merge(%{
      "first_name" => customer.first_name,
      "last_name" => customer.last_name,
      "email" => customer.email,
      "phone_number" => customer.phone_number
    })
  end

  # Paymob takes integer minor units (piasters for EGP).
  defp to_cents(amount) do
    cents = Decimal.mult(amount, 100)

    if Decimal.integer?(cents),
      do: {:ok, Decimal.to_integer(cents)},
      else: {:error, {:amount_has_fractional_cents, amount}}
  end

  defp read_intention(%{"id" => id, "client_secret" => secret, "intention_order_id" => order_id})
       when is_binary(id) and is_binary(secret) and is_integer(order_id),
       do: {:ok, id, secret, order_id}

  defp read_intention(body), do: {:error, {:paymob_unexpected_response, body}}

  # -- messages ---------------------------------------------------------------

  # Callback: already `%{"obj" => ..., "hmac" => ...}` (hmac from the query string).
  defp callback_shape(%{"obj" => %{} = obj, "hmac" => hmac}) when is_binary(hmac),
    do: {:ok, %{"obj" => obj}, hmac}

  # Redirect: flat query params; rebuild the nested "obj" the signature is defined over.
  defp callback_shape(%{"hmac" => hmac} = params) when is_binary(hmac) do
    obj =
      Enum.reduce(params, %{}, fn {key, value}, acc ->
        case Map.fetch(@redirect_nested, key) do
          {:ok, path} -> put_in(acc, Enum.map(path, &Access.key(&1, %{})), value)
          :error -> Map.put(acc, key, value)
        end
      end)

    {:ok, %{"obj" => Map.delete(obj, "hmac")}, hmac}
  end

  # No hmac at all: refuse before ex_paymob, whose compare needs a binary.
  defp callback_shape(_params), do: {:error, :invalid_signature}

  defp to_event(obj, hmac) do
    type = event_type(obj)

    %Event{
      provider: "paymob",
      event_id: "#{obj["id"]}:#{type}",
      type: type,
      # Matched by the signed order id only (see "Matching a message to a purchase").
      provider_ref: blank_to_nil(get_in(obj, ["order", "id"])),
      payment_ref: payment_ref(obj, type),
      purchase_id: nil,
      amount: cents_to_decimal(obj["amount_cents"]),
      currency: blank_to_nil(obj["currency"]),
      reason: blank_to_nil(get_in(obj, ["data", "message"])),
      payload: stored_payload(obj, hmac)
    }
  end

  # What's kept in the event store: the signed fields (so a replay can verify them again)
  # and the few fields billing reads. Customer details Paymob includes (billing and
  # shipping data: name, email, phone) are dropped.
  @signed_top_level ~w(amount_cents created_at currency error_occured has_parent_transaction id
                       integration_id is_3d_secure is_auth is_capture is_refunded
                       is_standalone_payment is_voided owner pending success)

  defp stored_payload(obj, hmac) do
    order = obj["order"] || %{}
    source = obj["source_data"] || %{}

    %{
      "obj" =>
        obj
        |> Map.take(@signed_top_level)
        |> Map.put("order", Map.take(order, ["id", "merchant_order_id"]))
        |> Map.put("source_data", Map.take(source, ["pan", "sub_type", "type"]))
        |> Map.put("data", Map.take(obj["data"] || %{}, ["message"]))
        |> Map.merge(Map.take(obj, ["parent_transaction"])),
      "hmac" => hmac
    }
  end

  # The transaction a message is about: the payment itself, or for a refund sent as its
  # own transaction, the payment it gives back. `parent_transaction` isn't signed, so it
  # only picks among the purchases of the signed order (see `UdinBilling.Webhooks`).
  defp payment_ref(obj, :refunded) do
    if child_refund?(obj),
      do: blank_to_nil(obj["parent_transaction"]),
      else: blank_to_nil(obj["id"])
  end

  defp payment_ref(obj, _type), do: blank_to_nil(obj["id"])

  defp event_type(obj) do
    cond do
      truthy?(obj["is_refunded"]) or truthy?(obj["is_voided"]) -> :refunded
      truthy?(obj["pending"]) -> :ignored
      child_refund?(obj) -> :refunded
      truthy?(obj["success"]) -> :payment_succeeded
      true -> :payment_failed
    end
  end

  # A refund or void reported as its own transaction on the order, rather than as a flag on
  # the original one. A capture of an authorization is also a child, but it's a payment.
  defp child_refund?(obj) do
    truthy?(obj["has_parent_transaction"]) and truthy?(obj["success"]) and
      not truthy?(obj["is_capture"])
  end

  # -- signed field shapes (see "Why every signed field must keep its exact shape") ------

  @signed_booleans ~w(error_occured has_parent_transaction is_3d_secure is_auth is_capture
                      is_refunded is_standalone_payment is_voided pending success)
  @signed_numbers ~w(amount_cents id integration_id owner)

  defp check_signed_shape(obj, opts) do
    problems =
      Enum.reject(@signed_booleans, &boolean_value?(obj[&1])) ++
        Enum.reject(@signed_numbers, &number_value?(obj[&1])) ++
        unless_shape(number_value?(get_in(obj, ["order", "id"])), "order.id") ++
        unless_shape(currency?(obj["currency"]), "currency") ++
        unless_shape(timestamp?(obj["created_at"]), "created_at") ++
        unless_shape(our_integration?(obj["integration_id"], opts), "integration_id")

    case Enum.uniq(problems) do
      [] -> :ok
      fields -> {:error, {:malformed_event, fields}}
    end
  end

  defp unless_shape(true, _field), do: []
  defp unless_shape(false, field), do: [field]

  # The callback sends JSON booleans; the redirect sends the strings "true"/"false".
  defp boolean_value?(value), do: value in [true, false, "true", "false"]

  defp number_value?(value) when is_integer(value), do: value >= 0
  defp number_value?(value) when is_binary(value), do: value =~ ~r/\A(0|[1-9][0-9]*)\z/
  defp number_value?(_value), do: false

  defp currency?(value), do: is_binary(value) and value =~ ~r/\A[A-Z]{3}\z/

  defp timestamp?(value) when is_binary(value) do
    match?({:ok, _}, NaiveDateTime.from_iso8601(value)) or
      match?({:ok, _, _}, DateTime.from_iso8601(value))
  end

  defp timestamp?(_value), do: false

  # Payments through any configured integration count, even a disabled method's: the money
  # was taken. Anything else isn't this app's.
  defp our_integration?(value, opts) do
    configured =
      opts |> Keyword.get(:integrations, %{}) |> Map.values() |> Enum.map(&to_string/1)

    value != nil and to_string(value) in configured
  end

  # The callback sends JSON booleans; the redirect sends the strings "true"/"false".
  defp truthy?(value), do: value in [true, "true"]

  defp cents_to_decimal(cents) when is_integer(cents), do: Decimal.div(cents, 100)

  defp cents_to_decimal(cents) when is_binary(cents) do
    case Integer.parse(cents) do
      {value, ""} -> Decimal.div(value, 100)
      _ -> nil
    end
  end

  defp cents_to_decimal(_cents), do: nil

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: to_string(value)
end

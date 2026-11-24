defmodule UdinBilling.Provider do
  @moduledoc """
  The contract a payment provider adapter implements (Paymob, RevenueCat, or
  `UdinBilling.Providers.Fake` for tests).

  ## Why a contract
  Checkout, webhooks and subscription syncing are the same everywhere: verify a message,
  store it once, apply it. Providers differ only in their HTTP calls and message formats,
  so an adapter implements these callbacks and everything else (`UdinBilling.Checkout`,
  `UdinBilling.Webhooks`, `UdinBilling.Subscriptions`) is shared.

  Configure adapters by name:

      config :udin_billing, :providers, %{"paymob" => {MyAdapter, secret: "..."}}

  ## Message kinds (`t:UdinBilling.Provider.Event.t/0` `type`)
    * `:payment_succeeded` / `:payment_failed` / `:refunded` - about one purchase, found by
      the provider's signed `provider_ref` (or `purchase_id` when the provider has none).
    * `:customer_changed` - "something changed for this customer": the customer's full
      state is in `customer`, or fetched with `fetch_customer/2`, then applied with
      `UdinBilling.Subscriptions.apply_customer/4`.
    * `:ignored` - nothing to do (test pings, pending transactions).
  """

  defmodule Event do
    @moduledoc "A verified provider message in one shape for all providers."
    @enforce_keys [:provider, :event_id, :type, :payload]
    defstruct [
      :provider,
      :event_id,
      :type,
      :provider_ref,
      :payment_ref,
      :purchase_id,
      :user_id,
      :customer,
      :amount,
      :currency,
      :reason,
      :payload
    ]

    @type type :: :payment_succeeded | :payment_failed | :refunded | :customer_changed | :ignored
    @type t :: %__MODULE__{
            provider: String.t(),
            event_id: String.t(),
            type: type(),
            provider_ref: String.t() | nil,
            payment_ref: String.t() | nil,
            purchase_id: String.t() | nil,
            user_id: String.t() | nil,
            customer: map() | nil,
            amount: Decimal.t() | nil,
            currency: String.t() | nil,
            reason: String.t() | nil,
            payload: map()
          }
  end

  @type session :: %{provider_ref: String.t(), redirect_url: String.t(), metadata: map()}

  @doc """
  Verifies a provider message (body/query `params` and request `headers`, lowercase
  names) and normalizes it. `{:error, :invalid_signature}` when it can't be proven to come
  from the provider. `payload` must hold only what's needed to verify it again (no
  customer personal data).
  """
  @callback parse_event(
              params :: map(),
              headers :: %{String.t() => String.t()},
              opts :: keyword()
            ) ::
              {:ok, Event.t()} | {:error, :invalid_signature | term()}

  @doc """
  Creates a payment for a pending purchase and returns where to send the user. Called
  outside any transaction. `provider_ref` must be the reference the provider later signs.
  """
  @callback create_checkout(purchase :: struct(), checkout :: map(), opts :: keyword()) ::
              {:ok, session()} | {:error, term()}

  @doc """
  Fetches a customer's current state for `UdinBilling.Subscriptions.apply_customer/4`
  (restore purchases, sync after a webhook). Called outside any transaction.
  """
  @callback fetch_customer(user_id :: String.t(), opts :: keyword()) ::
              {:ok, %{subscriptions: list(), one_time: list()}} | {:error, term()}

  @optional_callbacks create_checkout: 3, fetch_customer: 2

  @doc """
  True when `module` implements the optional `callback/arity`. Loads the module first:
  `function_exported?/3` alone is false for a module not loaded yet (common in releases
  and on the first request).
  """
  @spec implements?(module(), atom(), arity()) :: boolean()
  def implements?(module, callback, arity),
    do: Code.ensure_loaded?(module) and function_exported?(module, callback, arity)
end

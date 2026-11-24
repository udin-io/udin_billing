defmodule UdinBilling do
  @moduledoc """
  Public API of the shared billing library (Family-Corp, ReelsChef, and future apps).

  ## What it does
  Sells plans and turns them into access:
    * **switches** - on/off features (`share_recipe`, `smart_aggregation`, ...);
    * **counters** - units per cycle (`reel_imports`, `rides`), each user's cycle starting
      on their own date, no carry over.

  Features, plans and their values are data (see `UdinBilling.Admin`); each app's
  differences are config (see `UdinBilling.Config`). Nothing here is app-specific.

  ## Typical calls

      access = UdinBilling.access(user.id)                 # once per request / mount
      UdinBilling.Access.enabled?(access, "share_recipe")
      UdinBilling.Access.remaining(access, "reel_imports")

      # work that can fail (reel extraction): hold, then commit or release
      {:ok, _} = UdinBilling.reserve(user.id, "reel_imports", reference: extraction.id)
      UdinBilling.commit(user.id, "reel_imports", reference: extraction.id)   # recipe found
      UdinBilling.release(user.id, "reel_imports", reference: extraction.id)  # any failure

      # spend now (ride booking), inside the app's own transaction
      UdinBilling.consume(user.id, "rides", reference: "booking:" <> booking.id)

  Everything here runs server-side with authorization bypassed; the app decides who may
  call it (e.g. a rider only for their own id). Admin functions check the actor.
  """

  alias UdinBilling.{Access, Account, Checkout, Purchases, Quotas, Subscriptions, Webhooks}

  @doc "See `UdinBilling.Access.load/2`: all switches and counters of a user, in one call."
  defdelegate access(user_id, opts \\ []), to: Access, as: :load

  @doc "True when switch `key` is on for `user_id` now (one check, without counters)."
  defdelegate enabled?(user_id, key), to: Access, as: :enabled_now?

  @doc "See `UdinBilling.Quotas.balance/3`."
  defdelegate balance(user_id, key, opts \\ []), to: Quotas

  @doc "See `UdinBilling.Quotas.reserve/3`."
  defdelegate reserve(user_id, key, opts), to: Quotas

  @doc "See `UdinBilling.Quotas.commit/3`."
  defdelegate commit(user_id, key, opts), to: Quotas

  @doc "See `UdinBilling.Quotas.release/3`."
  defdelegate release(user_id, key, opts), to: Quotas

  @doc """
  Plans on sale, in display order (paid plans only: the free plan isn't bought), for a
  pricing or bundles screen. Show names with `UdinBilling.Plan.localized/3`.
  """
  @spec plans_for_sale() :: [struct()]
  def plans_for_sale, do: Ash.read!(UdinBilling.Plan, action: :purchasable, authorize?: false)

  @doc "See `UdinBilling.Quotas.consume/3`."
  defdelegate consume(user_id, key, opts), to: Quotas

  @doc "See `UdinBilling.Checkout.start/4`."
  defdelegate checkout(user_id, plan_id, provider, checkout \\ %{}), to: Checkout, as: :start

  @doc "See `UdinBilling.Purchases.start/4`."
  defdelegate start_purchase(user_id, plan_id, provider, metadata \\ %{}),
    to: Purchases,
    as: :start

  @doc "See `UdinBilling.Purchases.confirm_payment/2`."
  defdelegate confirm_payment(purchase_id, payment), to: Purchases

  @doc "See `UdinBilling.Purchases.refund/2`."
  defdelegate refund(purchase_id, reason), to: Purchases

  @doc "See `UdinBilling.Subscriptions.sync_customer/3`: after a purchase, and for restore."
  defdelegate sync_customer(provider, user_id, opts \\ []), to: Subscriptions

  @doc "See `UdinBilling.Subscriptions.apply_customer/4`."
  defdelegate apply_customer(provider, user_id, customer, opts \\ []), to: Subscriptions

  @doc "See `UdinBilling.Webhooks.handle/3`."
  defdelegate handle_webhook(provider, params, headers \\ %{}), to: Webhooks, as: :handle

  @doc """
  Anchors `user_id`'s free-plan cycles at `now` (call at signup). Safe to repeat: the
  first anchor is kept.
  """
  @spec ensure_account(Ecto.UUID.t(), DateTime.t()) :: {:ok, struct()} | {:error, term()}
  def ensure_account(user_id, now \\ DateTime.utc_now()) do
    Ash.create(Account, %{user_id: user_id, anchor_at: now}, action: :ensure, authorize?: false)
  end
end

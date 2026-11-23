defmodule UdinBilling.Checkout do
  @moduledoc """
  Starts a paid checkout for providers with a hosted payment page (e.g. Paymob): creates
  the pending purchase, creates the payment at the provider, and returns where to send the
  user.

  ## Order
  1. `UdinBilling.Purchases.start/4` (price copied, purchase policy applied).
  2. The provider call (HTTP), outside any database transaction.
  3. The provider's reference and the checkout URL are stored on the purchase, so an open
     checkout can be resumed with `url/1`.

  If the provider call fails, the purchase is cancelled so it doesn't block a retry.
  Store purchases (App Store / Google Play) don't use this: the app buys in-app and the
  provider's messages record the purchase.
  """
  alias UdinBilling.{Config, Plan, Purchases}

  @doc """
  Starts a checkout of `plan_id` for `user_id` through `provider`. `checkout` carries what
  the provider needs from the app (e.g. `%{customer: %{first_name: ..., email: ...}}`).
  `locale` (e.g. `"ar"`) picks the language of the plan name shown on the payment page;
  default: the default locale.
  """
  @spec start(Ecto.UUID.t(), Ecto.UUID.t(), String.t() | atom(), map()) ::
          {:ok, %{purchase: struct(), redirect_url: String.t()}} | {:error, term()}
  def start(user_id, plan_id, provider, checkout \\ %{}) do
    with {:ok, {module, opts}} <- Config.provider(provider),
         :ok <- supports_checkout(module),
         {:ok, purchase} <- Purchases.start(user_id, plan_id, provider) do
      purchase
      |> module.create_checkout(with_item_name(checkout, plan_id), opts)
      |> finish(purchase)
    end
  end

  @doc "The provider checkout URL stored on a pending purchase, or nil."
  @spec url(struct()) :: String.t() | nil
  def url(purchase), do: purchase.metadata["checkout_url"]

  defp supports_checkout(module) do
    if UdinBilling.Provider.implements?(module, :create_checkout, 3),
      do: :ok,
      else: {:error, :checkout_not_supported}
  end

  defp finish({:ok, session}, purchase) do
    metadata = Map.put(session.metadata, "checkout_url", session.redirect_url)

    with {:ok, purchase} <-
           Purchases.attach_provider_ref(purchase, session.provider_ref, metadata) do
      {:ok, %{purchase: purchase, redirect_url: session.redirect_url}}
    end
  end

  defp finish({:error, reason}, purchase) do
    case Purchases.cancel(purchase.id) do
      {:ok, _cancelled} -> {:error, reason}
      {:error, cancel_error} -> {:error, {reason, cancel_failed: cancel_error}}
    end
  end

  defp with_item_name(%{item_name: _} = checkout, _plan_id), do: checkout

  defp with_item_name(checkout, plan_id) do
    locale = Map.get(checkout, :locale) || Config.default_locale()

    case Ash.get(Plan, plan_id, authorize?: false) do
      {:ok, plan} ->
        Map.put(checkout, :item_name, Plan.localized(plan, :name, locale) || plan.code)

      {:error, _} ->
        checkout
    end
  end
end

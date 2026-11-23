defmodule UdinBilling.Changes.EnforcePurchasePolicy do
  @moduledoc """
  Applies `config :udin_billing, :purchase_policy` when a purchase starts.

    * `:stack` - always allowed; each purchase becomes its own lot with its own expiry.
    * `:single_active` - refused while the user has an unexpired paid purchase with quota
      left (or a feature-only purchase in its validity), or an open checkout (pending and
      younger than `:checkout_ttl`).

  ## How concurrent starts are prevented
  Under `:single_active` the user's row is locked (`FOR UPDATE`) inside the purchase's
  transaction before checking. Two checkouts started at the same moment (two tabs, a
  double tap) run one after the other; the second sees the first's open checkout and is
  refused, so at most one checkout per user can be open at a time.

  A checkout cancelled after that (abandoned past `:checkout_ttl`, or by the host) can
  still be paid on the provider's page. Under `:single_active` that payment is recorded as
  `:refund_required` instead of granting quota, see `UdinBilling.Purchases.confirm_payment/2`.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias UdinBilling.{Config, Purchases}

  @user_resource Application.compile_env!(:udin_billing, :user_resource)

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &enforce/1)
  end

  defp enforce(changeset) do
    case Config.purchase_policy() do
      :stack -> changeset
      :single_active -> enforce_single_active(changeset)
    end
  end

  defp enforce_single_active(changeset) do
    user_id = Ash.Changeset.get_attribute(changeset, :user_id)
    now = DateTime.utc_now()

    with :ok <- lock_user(user_id) do
      cond do
        Purchases.active_purchase?(user_id, now) ->
          refuse(changeset, "the current plan must run out or expire before buying another")

        Purchases.open_checkout(user_id, now) != nil ->
          refuse(changeset, "a checkout is already in progress")

        true ->
          changeset
      end
    else
      {:error, message} -> refuse(changeset, message)
    end
  end

  defp lock_user(user_id) do
    @user_resource
    |> Ash.Query.filter(id == ^user_id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> {:error, "user not found"}
      {:ok, _user} -> :ok
      {:error, error} -> {:error, Exception.message(error)}
    end
  end

  defp refuse(changeset, message) do
    Ash.Changeset.add_error(changeset, field: :plan_id, message: message)
  end
end

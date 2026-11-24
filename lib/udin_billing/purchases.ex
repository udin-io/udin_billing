defmodule UdinBilling.Purchases do
  @moduledoc """
  Starting, paying, failing, cancelling and refunding one-time purchases.

  Every state change locks the purchase row first, so provider messages that retry or
  arrive together change it exactly once.
  """
  require Ash.Query

  alias UdinBilling.{Config, Grant, Purchase, Transaction}

  @term_fields [:validity_unit, :validity_count, :cycle_unit, :cycle_count]

  # Every status a screen may need to react to. `:pending` is only ever the start.
  @announced_statuses [:paid, :refund_required, :failed, :refunded, :cancelled]

  @type payment :: %{
          required(:amount) => Decimal.t() | String.t() | number() | nil,
          required(:currency) => String.t() | nil,
          optional(:provider_ref) => String.t() | nil,
          optional(:payment_ref) => String.t() | nil,
          optional(:paid_at) => DateTime.t() | nil
        }

  @doc """
  Opens a pending checkout of one-time plan `plan_id` for `user_id` through `provider`.
  Refused when the plan isn't for sale or the purchase policy blocks a second plan.
  """
  @spec start(Ecto.UUID.t(), Ecto.UUID.t(), String.t() | atom(), map()) ::
          {:ok, struct()} | {:error, term()}
  def start(user_id, plan_id, provider, metadata \\ %{}) do
    Ash.create(
      Purchase,
      %{user_id: user_id, plan_id: plan_id, provider: to_string(provider), metadata: metadata},
      action: :start,
      authorize?: false
    )
  end

  @doc """
  Records a purchase already paid elsewhere, once per `provider_ref`: a store top-up
  (the ReelsChef single reel) or, with `provider: "admin"` and `amount: 0`, a gift.
  Repeating it returns the existing purchase.

  Options: `:paid_at`, `:amount`, `:metadata`.
  """
  @spec record_paid(Ecto.UUID.t(), Ecto.UUID.t(), String.t() | atom(), String.t(), keyword()) ::
          {:ok, struct()} | {:error, term()}
  def record_paid(user_id, plan_id, provider, provider_ref, opts \\ []) do
    provider = to_string(provider)

    case by_provider_ref(provider, provider_ref) do
      {:ok, %Purchase{} = existing} -> {:ok, existing}
      {:ok, nil} -> create_paid(user_id, plan_id, provider, provider_ref, opts)
      error -> error
    end
  end

  @doc "Stores the provider's reference for a pending purchase."
  @spec attach_provider_ref(struct(), String.t(), map()) :: {:ok, struct()} | {:error, term()}
  def attach_provider_ref(purchase, provider_ref, metadata \\ %{}) do
    purchase
    |> Ash.Changeset.for_update(:attach_provider_ref, %{
      provider_ref: provider_ref,
      metadata: Map.merge(purchase.metadata, metadata)
    })
    |> Ash.update(authorize?: false)
  end

  @doc """
  Marks a purchase paid exactly once. Returns the purchase; check its status. Repeats are
  no-ops. A wrong amount or currency returns `{:error, {:amount_mismatch, _}}` without
  changes.

  A payment for a cancelled checkout (abandoned past `:checkout_ttl`, or cancelled by the
  app) is accepted as `:paid` when `payment.provider_ref` is the checkout's own
  reference, the amount matches, and the purchase policy is `:stack`. The plan then starts
  when the payment arrived. Otherwise it's kept as `:refund_required`, nothing granted.

  `payment.payment_ref` is the provider's transaction id. A different transaction for a
  purchase that's already settled means the buyer was charged twice: it's recorded as
  its own `:refund_required` purchase linked to this one (see `UdinBilling.Purchase`),
  and this purchase is returned unchanged.
  """
  @spec confirm_payment(Ecto.UUID.t(), payment()) :: {:ok, struct()} | {:error, term()}
  def confirm_payment(purchase_id, payment),
    do: change_status(Purchase, purchase_id, &apply_payment(&1, payment))

  @doc "Marks a pending purchase failed; settled purchases are returned unchanged."
  @spec fail(Ecto.UUID.t(), String.t()) :: {:ok, struct()} | {:error, term()}
  def fail(purchase_id, reason) do
    change_status(Purchase, purchase_id, fn
      %Purchase{status: :pending} = purchase ->
        update(purchase, :mark_failed, %{failure_reason: reason})

      settled ->
        {:ok, settled}
    end)
  end

  @doc """
  Refunds a paid purchase: ends its access now and revokes its unused units (past use
  stays in history). Repeats are no-ops; never-paid purchases can't be refunded.
  """
  @spec refund(Ecto.UUID.t(), String.t()) :: {:ok, struct()} | {:error, term()}
  def refund(purchase_id, reason),
    do: change_status([Purchase, Grant], purchase_id, &apply_refund(&1, reason))

  @doc "Refunds the purchase a provider knows as `provider_ref`. Unknown refs are rejected."
  @spec refund_by_ref(String.t(), String.t(), String.t()) :: {:ok, struct()} | {:error, term()}
  def refund_by_ref(provider, provider_ref, reason) do
    case by_provider_ref(provider, provider_ref) do
      {:ok, %Purchase{id: id}} -> refund(id, reason)
      {:ok, nil} -> {:error, {:unknown_purchase, provider_ref}}
      error -> error
    end
  end

  @doc """
  Cancels a pending checkout. A payment that still arrives is accepted or kept for refund,
  see `confirm_payment/2`.
  """
  @spec cancel(Ecto.UUID.t()) :: {:ok, struct()} | {:error, term()}
  def cancel(purchase_id) do
    change_status(Purchase, purchase_id, fn
      %Purchase{status: :pending} = purchase -> update(purchase, :cancel, %{})
      settled -> {:ok, settled}
    end)
  end

  @doc "The user's open checkout (pending, younger than `:checkout_ttl`), or nil."
  @spec open_checkout(Ecto.UUID.t(), DateTime.t()) :: struct() | nil
  def open_checkout(user_id, now \\ DateTime.utc_now()) do
    since = DateTime.add(now, -Config.checkout_ttl(), :second)

    Purchase
    |> Ash.Query.for_read(:open_checkouts, %{user_id: user_id, since: since})
    |> Ash.Query.limit(1)
    |> Ash.read_one!(authorize?: false)
  end

  @doc """
  Cancels checkouts older than `max_age_seconds` (default `:checkout_ttl`) and returns how
  many: pending ones, and declined ones (a declined card can be retried on the provider's
  page until it closes). One SQL UPDATE whose "still open" condition Postgres re-checks per
  row, so a checkout paid a moment earlier is never cancelled. A payment that arrives
  afterwards follows the late-payment rules (`confirm_payment/2`). Schedule it (e.g. hourly).
  """
  @spec cancel_stale(pos_integer(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def cancel_stale(max_age_seconds \\ Config.checkout_ttl(), opts \\ [])
      when is_integer(max_age_seconds) and max_age_seconds > 0 do
    before = DateTime.add(Keyword.get(opts, :now, DateTime.utc_now()), -max_age_seconds, :second)

    Purchase
    |> Ash.Query.for_read(:stale_pending, %{before: before})
    |> Ash.bulk_update(:cancel, %{},
      strategy: [:atomic],
      authorize?: false,
      return_errors?: true,
      return_records?: true
    )
    |> case do
      %Ash.BulkResult{status: :success, records: records} ->
        # The bulk update has committed: each cancelled checkout is announced now.
        Enum.each(records, &emit_status/1)
        {:ok, length(records)}

      %Ash.BulkResult{errors: errors} ->
        {:error, errors}
    end
  end

  @doc """
  True when the user has a paid purchase still in use at `now`: unexpired and either with
  units left or switches only. Used by the `:single_active` policy.
  """
  @spec active_purchase?(Ecto.UUID.t(), DateTime.t()) :: boolean()
  def active_purchase?(user_id, now) do
    user_id
    |> UdinBilling.Sources.list(now)
    |> Enum.filter(&(&1.kind == :purchase))
    |> Enum.any?(&in_use?(user_id, &1, now))
  end

  @doc "Paid purchases whose access hasn't ended at `now`."
  @spec active(Ecto.UUID.t(), DateTime.t()) :: [struct()]
  def active(user_id, now) do
    Purchase
    |> Ash.Query.for_read(:active_for_user, %{user_id: user_id, at: now})
    |> Ash.read!(authorize?: false)
  end

  @doc """
  True when `paid_amount` / `paid_currency` equal `purchase`'s copied price (decimal
  comparison; currency ignores case).
  """
  @spec amount_matches?(struct(), term(), String.t() | nil) :: boolean()
  def amount_matches?(_purchase, nil, _currency), do: false
  def amount_matches?(_purchase, _amount, nil), do: false

  def amount_matches?(purchase, paid_amount, paid_currency) do
    Decimal.equal?(purchase.amount, paid_amount) and
      String.upcase(purchase.currency) == String.upcase(paid_currency)
  end

  # -- helpers ----------------------------------------------------------------

  defp create_paid(user_id, plan_id, provider, provider_ref, opts) do
    Purchase
    |> Ash.Changeset.for_create(:record_paid, %{
      user_id: user_id,
      plan_id: plan_id,
      provider: provider,
      provider_ref: provider_ref,
      metadata: Keyword.get(opts, :metadata, %{}),
      paid_at: Keyword.get(opts, :paid_at),
      amount: Keyword.get(opts, :amount)
    })
    |> Ash.create(authorize?: false)
    |> case do
      {:ok, purchase} ->
        emit_status(purchase)
        {:ok, purchase}

      # A parallel call recorded it first: return that one.
      {:error, error} ->
        case by_provider_ref(provider, provider_ref) do
          {:ok, %Purchase{} = existing} -> {:ok, existing}
          _ -> {:error, error}
        end
    end
  end

  defp by_provider_ref(provider, provider_ref) do
    Purchase
    |> Ash.Query.for_read(:by_provider_ref, %{provider: provider, provider_ref: provider_ref})
    |> Ash.read_one(authorize?: false)
  end

  # A purchase with switches only is in use until it expires; one with counters while any
  # of its own units are left.
  defp in_use?(user_id, source, now) do
    case for({key, value} <- source.features, not is_boolean(value), do: key) do
      [] ->
        true

      keys ->
        user_id
        |> UdinBilling.Quotas.balances([source], now, keys)
        |> Map.values()
        |> Enum.any?(&(&1.remaining == :unlimited or &1.remaining > 0))
    end
  end

  defp lock(purchase_id) do
    Purchase
    |> Ash.Query.filter(id == ^purchase_id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> {:rejected, :not_found}
      other -> other
    end
  end

  defp update(purchase, action, params),
    do: purchase |> Ash.Changeset.for_update(action, params) |> Ash.update(authorize?: false)

  # A settled purchase: the same transaction again changes nothing, another one is a
  # second charge for the same order.
  defp apply_payment(%Purchase{status: status} = purchase, payment)
       when status in [:paid, :refund_required, :refunded] do
    if second_charge?(purchase, payment),
      do: record_second_payment(purchase, payment),
      else: {:ok, purchase}
  end

  # The amount is checked before any write, so a mismatch is a clean rejection that
  # doesn't roll back a caller's transaction (e.g. the provider message inbox).
  defp apply_payment(%Purchase{status: status} = purchase, payment)
       when status in [:pending, :failed] do
    if amount_matches?(purchase, payment.amount, payment.currency),
      do: record_payment(purchase, :mark_paid, payment),
      else:
        {:rejected,
         {:amount_mismatch,
          %{
            expected: {purchase.amount, purchase.currency},
            paid: {payment.amount, payment.currency}
          }}}
  end

  defp apply_payment(%Purchase{status: :cancelled} = purchase, payment) do
    case late_refusal(purchase, payment) do
      nil ->
        record_payment(purchase, :mark_paid_late, payment)

      reason ->
        record_payment(purchase, :mark_refund_required, Map.put(payment, :reason, reason))
    end
  end

  # Why a payment for a cancelled checkout can't be accepted, or nil when it can: the
  # provider's reference is the one stored on this checkout (Paymob signs it, so it can't
  # come from another order) and the full price was paid. Under
  # :single_active it never counts: the cancellation may have let the user start another
  # plan, and granting this one too would break "one at a time". The reason is stored on
  # the purchase for admins.
  defp late_refusal(purchase, payment) do
    cond do
      Config.purchase_policy() == :single_active ->
        "one plan at a time here (purchase_policy: :single_active)"

      not same_checkout?(purchase, payment) ->
        "the payment's reference isn't this checkout's"

      not amount_matches?(purchase, payment.amount, payment.currency) ->
        "paid #{payment.amount} #{payment.currency}, the price is " <>
          "#{Decimal.to_string(purchase.amount, :normal)} #{purchase.currency}"

      true ->
        nil
    end
  end

  defp same_checkout?(%Purchase{provider_ref: ref}, payment) when is_binary(ref),
    do: Map.get(payment, :provider_ref) == ref

  defp same_checkout?(_purchase, _payment), do: false

  defp record_payment(purchase, action, payment) do
    params = %{
      paid_amount: payment.amount,
      paid_currency: payment.currency,
      provider_ref: Map.get(payment, :provider_ref),
      payment_ref: Map.get(payment, :payment_ref),
      paid_at: Map.get(payment, :paid_at)
    }

    params =
      if reason = Map.get(payment, :reason), do: Map.put(params, :reason, reason), else: params

    update(purchase, action, params)
  end

  # Without transaction ids on both sides there's no telling a repeat from a new charge,
  # so it's taken as a repeat, as before transaction ids were stored.
  defp second_charge?(%Purchase{payment_ref: paid_by}, payment) do
    new = Map.get(payment, :payment_ref)
    is_binary(paid_by) and is_binary(new) and new != paid_by
  end

  defp record_second_payment(purchase, payment) do
    case second_payment_by_ref(purchase.provider, payment.payment_ref) do
      {:ok, nil} -> create_second_payment(purchase, payment)
      {:ok, _already_recorded} -> {:ok, purchase}
      {:error, _} = error -> error
    end
  end

  defp second_payment_by_ref(provider, payment_ref) do
    Purchase
    |> Ash.Query.filter(provider == ^provider and payment_ref == ^payment_ref)
    |> Ash.read_one(authorize?: false)
  end

  defp create_second_payment(purchase, payment) do
    paid_amount = payment.amount && Decimal.new(payment.amount)

    attrs =
      purchase
      |> Map.take([:user_id, :plan_id, :provider, :amount, :currency, :features] ++ @term_fields)
      |> Map.merge(%{
        payment_ref: payment.payment_ref,
        paid_at: Map.get(payment, :paid_at) || DateTime.utc_now(),
        duplicate_of_id: purchase.id,
        metadata: %{
          "paid_amount" => Decimal.to_string(paid_amount || purchase.amount, :normal),
          "paid_currency" => payment.currency || purchase.currency
        }
      })

    case Ash.create(Purchase, attrs, action: :record_second_payment, authorize?: false) do
      {:ok, second} ->
        emit_status(second)
        {:ok, purchase}

      {:error, _} = error ->
        error
    end
  end

  defp apply_refund(%Purchase{status: :refunded} = purchase, _reason), do: {:ok, purchase}

  defp apply_refund(%Purchase{status: :refund_required} = purchase, reason),
    do: update(purchase, :mark_refunded, %{refund_reason: reason})

  defp apply_refund(%Purchase{status: :paid} = purchase, reason) do
    with {:ok, refunded} <- update(purchase, :mark_refunded, %{refund_reason: reason}),
         :ok <- UdinBilling.Lots.revoke(purchase_id: purchase.id) do
      {:ok, refunded}
    end
  end

  defp apply_refund(%Purchase{status: status}, _reason),
    do: {:rejected, {:purchase_not_refundable, status}}

  # Locks the purchase, applies `fun` and announces the new status once committed. A call
  # that leaves the status as it was (a repeat) announces nothing.
  defp change_status(resources, purchase_id, fun) do
    resources
    |> Transaction.run(fn ->
      with {:ok, purchase} <- lock(purchase_id),
           {:ok, changed} <- fun.(purchase) do
        {:ok, {changed, changed.status != purchase.status}}
      end
    end)
    |> case do
      {:ok, {purchase, true = _changed?}} ->
        emit_status(purchase)
        {:ok, purchase}

      {:ok, {purchase, false = _changed?}} ->
        {:ok, purchase}

      error ->
        error
    end
  end

  # After commit: a listener reloading the purchase must see its new status.
  defp emit_status(%Purchase{status: status} = purchase)
       when status in @announced_statuses do
    Transaction.after_commit(fn ->
      :telemetry.execute([:udin_billing, :purchase, status], %{amount: purchase.amount}, %{
        purchase_id: purchase.id,
        user_id: purchase.user_id,
        plan_id: purchase.plan_id
      })
    end)
  end

  defp emit_status(_purchase), do: :ok
end

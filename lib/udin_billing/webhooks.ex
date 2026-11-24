defmodule UdinBilling.Webhooks do
  @moduledoc """
  Applies verified provider messages to billing, each exactly once.

  ## Steps
  1. The adapter verifies and normalizes the message (`c:UdinBilling.Provider.parse_event/3`).
     Unverified messages stop here and nothing is stored.
  2. Store it in `UdinBilling.ProviderEvent` (or find the stored copy). Already applied →
     `{:ok, :duplicate}`.
  3. For `:customer_changed` without the state inline, fetch the customer's state from
     the provider, outside any transaction.
  4. In one transaction: lock the stored message, apply it, record the outcome.

  ## Outcomes
    * `{:ok, :processed | :ignored}` - applied now.
    * `{:ok, :duplicate}` - applied earlier; nothing changed.
    * `{:ok, :failed}` - refused for a business reason (wrong amount, unknown purchase or
      user); kept for an admin. Retrying wouldn't help, so the provider gets a success
      response.
    * `{:error, :invalid_signature}` - not from the provider.
    * `{:error, _}` - something broke (database, provider API down). Nothing was applied,
      so the provider's retry or `replay/1` will apply it.
  """
  require Ash.Query
  require Logger

  alias UdinBilling.{Config, ProviderEvent, Purchase, Purchases, Subscriptions, Transaction}
  alias UdinBilling.Provider.Event

  @user_resource Application.compile_env!(:udin_billing, :user_resource)

  @type outcome :: :processed | :ignored | :duplicate | :failed

  @doc """
  Verifies `params` (and `headers`, lowercase names) with provider `provider` and applies
  the message.
  """
  @spec handle(String.t() | atom(), map(), map()) :: {:ok, outcome()} | {:error, term()}
  def handle(provider, params, headers \\ %{}) do
    with {:ok, {module, opts}} <- Config.provider(provider),
         {:ok, %Event{} = event} <- module.parse_event(params, headers, opts) do
      # The message belongs to the name the app registered this adapter under (the same
      # name its purchases carry), whatever the adapter calls itself.
      event = %{event | provider: to_string(provider)}
      event |> process(module, opts) |> tap(&emit(&1, event))
    end
  end

  @doc "Applies a stored message again, e.g. after fixing the cause of a `:failed` outcome."
  @spec replay(Ecto.UUID.t()) :: {:ok, outcome()} | {:error, term()}
  def replay(provider_event_id) do
    with {:ok, stored} <- Ash.get(ProviderEvent, provider_event_id, authorize?: false),
         {:ok, {module, opts}} <- Config.provider(stored.provider) do
      event = from_stored(stored)
      event |> process(module, opts, retry_failed?: true) |> tap(&emit(&1, event))
    end
  end

  # -- processing -------------------------------------------------------------

  defp process(event, module, opts, flags \\ []) do
    retry_failed? = Keyword.get(flags, :retry_failed?, false)

    with {:ok, stored} <- store(event),
         :pending <- already_done(stored, retry_failed?),
         {:ok, event} <- with_customer(event, module, opts) do
      apply_in_transaction(stored, event, retry_failed?)
    else
      :done -> {:ok, :duplicate}
      error -> error
    end
  end

  # A customer's full state is applied item by item, each in its own transaction, so one
  # refused item (unknown product, sandbox) can't roll back the rest. Applying the same
  # state twice changes nothing, so this needs no outer lock; the outcome is then recorded.
  defp apply_in_transaction(stored, %Event{type: :customer_changed} = event, _retry_failed?) do
    result = apply_event(event)

    Transaction.run(ProviderEvent, fn ->
      with {:ok, locked} <- lock(stored) do
        record_outcome(locked, result)
      end
    end)
  end

  defp apply_in_transaction(stored, event, retry_failed?) do
    Transaction.run([ProviderEvent, Purchase], fn ->
      with {:ok, locked} <- lock(stored),
           :pending <- already_done(locked, retry_failed?) do
        apply_and_record(locked, event)
      else
        :done -> {:ok, :duplicate}
        error -> error
      end
    end)
  end

  defp already_done(%ProviderEvent{status: status}, _retry) when status in [:processed, :ignored],
    do: :done

  defp already_done(%ProviderEvent{status: :failed}, false), do: :done
  defp already_done(_stored, _retry), do: :pending

  defp with_customer(%Event{type: :customer_changed, customer: nil} = event, module, opts) do
    cond do
      # Unknown or anonymous ids: no provider call; applying records the refusal.
      known_user(event.user_id) != :ok -> {:ok, event}
      UdinBilling.Provider.implements?(module, :fetch_customer, 2) -> fetch(event, module, opts)
      true -> {:error, :fetch_customer_not_supported}
    end
  end

  defp with_customer(event, _module, _opts), do: {:ok, event}

  defp fetch(event, module, opts) do
    case module.fetch_customer(event.user_id, opts) do
      {:ok, customer} -> {:ok, %{event | customer: customer}}
      {:error, reason} -> {:error, {:fetch_customer_failed, reason}}
    end
  end

  defp apply_and_record(stored, event), do: record_outcome(stored, apply_event(event))

  defp record_outcome(stored, result) do
    case result do
      :ignored -> mark(stored, :mark_ignored, %{}, :ignored)
      {:ok, _} -> mark(stored, :mark_processed, %{}, :processed)
      {:error, reason} -> mark(stored, :mark_failed, %{error: describe(reason)}, :failed)
    end
  end

  defp apply_event(%Event{type: :ignored}), do: :ignored

  defp apply_event(%Event{type: :customer_changed, customer: nil} = event),
    do: {:error, {:unknown_user, event.user_id}}

  defp apply_event(%Event{type: :customer_changed} = event) do
    with :ok <- known_user(event.user_id),
         {:ok, %{skipped: skipped}} <-
           Subscriptions.apply_customer(event.provider, event.user_id, event.customer) do
      # An item that couldn't be applied (an unknown product, a database error...) fails the
      # message, so it shows under Webhooks → failed and can be replayed once fixed. The
      # items that did apply stay applied; replaying applies them again harmlessly. Sandbox
      # purchases refused on purpose (`:allow_sandbox` off) aren't failures.
      case Enum.reject(skipped, &match?({_ref, :sandbox_not_allowed}, &1)) do
        [] -> {:ok, nil}
        not_applied -> {:error, {:items_not_applied, not_applied}}
      end
    end
  end

  defp apply_event(%Event{} = event) do
    with {:ok, purchase_id} <- resolve_purchase(event) do
      case event.type do
        :payment_succeeded ->
          Purchases.confirm_payment(purchase_id, %{
            amount: event.amount,
            currency: event.currency,
            provider_ref: event.provider_ref,
            payment_ref: event.payment_ref
          })

        :payment_failed ->
          Purchases.fail(purchase_id, event.reason || "payment failed")

        :refunded ->
          event |> refund_target(purchase_id) |> Purchases.refund("#{event.provider} refund")
      end
      |> case do
        {:ok, _purchase} -> {:ok, nil}
        error -> error
      end
    end
  end

  # A refund names the transaction it gives back when the provider says so: the second
  # charge of an order paid twice is its own purchase. Only a purchase of this same order
  # (the signed reference already resolved) can be picked, so a transaction id can't move
  # a refund onto another order. Otherwise the order's purchase, as before.
  defp refund_target(%Event{payment_ref: ref, provider: provider}, purchase_id)
       when is_binary(ref) do
    Purchase
    |> Ash.Query.filter(
      provider == ^provider and payment_ref == ^ref and
        (id == ^purchase_id or duplicate_of_id == ^purchase_id)
    )
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %Purchase{id: id}} -> id
      _not_this_order -> purchase_id
    end
  end

  defp refund_target(_event, purchase_id), do: purchase_id

  # With a provider reference (which the provider signs), the purchase is the one that
  # reference was stored on at checkout, and an echoed purchase id must agree with it.
  # This stops an unsigned field from moving a payment onto another purchase.
  defp resolve_purchase(%Event{provider_ref: ref} = event) when is_binary(ref) do
    Purchase
    |> Ash.Query.for_read(:by_provider_ref, %{provider: event.provider, provider_ref: ref})
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} ->
        {:error, {:unknown_purchase, ref}}

      {:ok, purchase} when event.purchase_id in [nil, purchase.id] ->
        {:ok, purchase.id}

      {:ok, purchase} ->
        {:error, {:purchase_mismatch, %{signed: purchase.id, echoed: event.purchase_id}}}

      {:error, _} = error ->
        error
    end
  end

  defp resolve_purchase(%Event{purchase_id: purchase_id}) do
    case Ecto.UUID.cast(purchase_id || "") do
      {:ok, id} -> {:ok, id}
      :error -> {:error, {:unknown_purchase, purchase_id}}
    end
  end

  defp known_user(user_id) do
    with {:ok, id} <- cast_uuid(user_id),
         {:ok, %{}} <- Ash.get(@user_resource, id, authorize?: false) do
      :ok
    else
      _ -> {:error, {:unknown_user, user_id}}
    end
  end

  defp cast_uuid(value) do
    case Ecto.UUID.cast(value || "") do
      {:ok, id} -> {:ok, id}
      :error -> :error
    end
  end

  # -- storage ----------------------------------------------------------------

  defp store(event) do
    Ash.create(
      ProviderEvent,
      %{
        provider: event.provider,
        event_id: event.event_id,
        event_type: event.type,
        reference: event.provider_ref || event.purchase_id || event.user_id,
        event: to_stored(event),
        payload: event.payload
      },
      action: :receive,
      authorize?: false
    )
  end

  defp lock(stored) do
    ProviderEvent
    |> Ash.Query.filter(id == ^stored.id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
  end

  defp mark(stored, action, params, outcome) do
    case stored |> Ash.Changeset.for_update(action, params) |> Ash.update(authorize?: false) do
      {:ok, _} -> {:ok, outcome}
      {:error, _} = error -> error
    end
  end

  @stored_fields [:provider_ref, :purchase_id, :user_id, :currency, :reason]
  @time_fields [:period_starts_at, :period_ends_at, :grace_ends_at, :refunded_at, :paid_at]

  # The normalized message as JSON. A customer state the adapter sent inline (product ids
  # and dates only) is kept; a fetched one isn't, so a replay fetches it fresh.
  defp to_stored(event) do
    event
    |> Map.take(@stored_fields)
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.put("amount", event.amount && Decimal.to_string(event.amount))
    |> Map.put("customer", encode_customer(event.customer))
  end

  defp encode_customer(nil), do: nil

  defp encode_customer(customer) do
    Map.new(customer, fn {group, items} -> {to_string(group), Enum.map(items, &encode_item/1)} end)
  end

  defp encode_item(item) do
    Map.new(item, fn
      {key, %DateTime{} = time} -> {to_string(key), DateTime.to_iso8601(time)}
      {key, value} -> {to_string(key), value}
    end)
  end

  defp decode_customer(nil), do: nil

  defp decode_customer(customer) do
    %{
      subscriptions: Enum.map(Map.get(customer, "subscriptions", []), &decode_item/1),
      one_time: Enum.map(Map.get(customer, "one_time", []), &decode_item/1)
    }
  end

  defp decode_item(item) do
    Map.new(item, fn {key, value} ->
      key = String.to_existing_atom(key)
      {key, if(key in @time_fields and is_binary(value), do: parse_time(value), else: value)}
    end)
  end

  defp parse_time(value) do
    {:ok, time, _offset} = DateTime.from_iso8601(value)
    time
  end

  defp from_stored(stored) do
    e = stored.event

    %Event{
      provider: stored.provider,
      event_id: stored.event_id,
      type: stored.event_type,
      provider_ref: e["provider_ref"],
      purchase_id: e["purchase_id"],
      user_id: e["user_id"],
      amount: e["amount"] && Decimal.new(e["amount"]),
      currency: e["currency"],
      reason: e["reason"],
      customer: decode_customer(e["customer"]),
      payload: stored.payload
    }
  end

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(%{__exception__: true} = error), do: Exception.message(error)
  defp describe(reason), do: inspect(reason)

  defp emit({:ok, outcome}, event) do
    if outcome == :failed,
      do:
        Logger.warning(
          "udin_billing: #{event.provider} message #{event.event_id} refused; stored for review"
        )

    :telemetry.execute([:udin_billing, :webhook, outcome], %{count: 1}, %{
      provider: event.provider,
      event_id: event.event_id,
      type: event.type,
      # The customer the message is about (store messages), or nil (payment messages name a
      # purchase): lets the app refresh that user's screens.
      user_id: event.user_id
    })
  end

  defp emit({:error, reason}, event) do
    Logger.error(
      "udin_billing: #{event.provider} message #{event.event_id} not applied: #{inspect(reason)}"
    )

    :telemetry.execute([:udin_billing, :webhook, :error], %{count: 1}, %{
      provider: event.provider,
      event_id: event.event_id,
      type: event.type,
      # The customer the message is about (store messages), or nil (payment messages name a
      # purchase): lets the app refresh that user's screens.
      user_id: event.user_id
    })
  end
end

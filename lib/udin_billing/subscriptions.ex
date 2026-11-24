defmodule UdinBilling.Subscriptions do
  @moduledoc """
  Applies the subscription state a store or provider reports, for any provider.

  ## Why "state", not events
  Stores send many event types, sometimes late or out of order. Providers like RevenueCat
  recommend fetching the customer's current state after any event and storing it. So an
  adapter turns whatever it receives into a `t:state/0` and calls `apply_state/4`; this
  module is the only place that decides what that means for access. Applying the same
  state twice changes nothing.

  ## What a state means
    * new paid period (first purchase or renewal): copy the plan's current terms; the new
      period starts new counter cycles (no carry over)
    * `auto_renew: false` (cancelled): access continues until the period end
    * `grace_ends_at`: the store is retrying a failed payment; whether switches stay on
      meanwhile is `config :udin_billing, :grace_access`
    * `refunded_at`: access ends at that moment and unused units are revoked
    * a new subscription while another one is active (plan change): the old one's current
      units are replaced according to `config :udin_billing, :upgrade_policy`
      (`:fresh` = full new counters, `:shift` = new counters minus what was used)

  ## Deactivated plans
  `renewable?/1` is false for an inactive plan, for renewals we control. Store renewals
  are charged by Apple/Google, so a paid renewal of an inactive plan still gives access
  (money taken = access given) and reported as
  `[:udin_billing, :subscription, :renewed_inactive_plan]` so an admin can act in the store.
  """
  require Ash.Query

  alias UdinBilling.{
    Config,
    Grant,
    Lots,
    Plan,
    Purchases,
    Sources,
    Subscription,
    Terms,
    Transaction,
    Usage
  }

  alias UdinBilling.Quotas

  @type state :: %{
          required(:provider_ref) => String.t(),
          required(:product_id) => String.t(),
          required(:period_starts_at) => DateTime.t(),
          required(:period_ends_at) => DateTime.t(),
          optional(:auto_renew) => boolean(),
          optional(:grace_ends_at) => DateTime.t() | nil,
          optional(:refunded_at) => DateTime.t() | nil,
          optional(:sandbox) => boolean(),
          optional(:store) => String.t() | nil
        }

  @type one_time :: %{
          required(:provider_ref) => String.t(),
          required(:product_id) => String.t(),
          required(:paid_at) => DateTime.t(),
          optional(:refunded_at) => DateTime.t() | nil,
          optional(:sandbox) => boolean()
        }

  @doc """
  Applies one subscription `state` from `provider` for `user_id`. Returns the stored
  subscription. Refused: unknown product, a product that isn't a recurring plan, sandbox
  purchases when `:allow_sandbox` is off.
  """
  @spec apply_state(String.t(), Ecto.UUID.t(), state(), keyword()) ::
          {:ok, struct()} | {:error, term()}
  def apply_state(provider, user_id, state, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with :ok <- check_sandbox(state),
         {:ok, plan} <- recurring_plan(provider, state.product_id) do
      case apply_locked(provider, user_id, state, plan, now) do
        # Two reports of a brand-new subscription at once (app sync + webhook): the other
        # one created it first. Run again; the row now exists, is locked and updated.
        {:error, _} = error ->
          if exists?(provider, state.provider_ref),
            do: apply_locked(provider, user_id, state, plan, now),
            else: error

        ok ->
          ok
      end
    end
  end

  # Telemetry is emitted after the transaction commits, so it never reports a change that
  # was rolled back.
  defp apply_locked(provider, user_id, state, plan, now) do
    Transaction.run([Subscription, Grant, Usage], fn ->
      with {:ok, existing} <- lock(provider, state.provider_ref) do
        upsert(existing, plan, provider, user_id, state, now)
      end
    end)
    |> case do
      {:ok, {subscription, events}} ->
        Enum.each(events, fn {event, event_plan} -> emit(event, subscription, event_plan) end)
        {:ok, subscription}

      error ->
        error
    end
  end

  defp exists?(provider, provider_ref) do
    Subscription
    |> Ash.Query.for_read(:by_provider_ref, %{provider: provider, provider_ref: provider_ref})
    |> Ash.exists?(authorize?: false)
  end

  @doc """
  Applies everything a provider reports for a customer: every subscription state and every
  one-time store purchase (`UdinBilling.Purchases.record_paid/5`, refunded when the store
  says so). Skipped items are returned with their reason instead of failing the rest.
  """
  @spec apply_customer(
          String.t(),
          Ecto.UUID.t(),
          %{subscriptions: [state()], one_time: [one_time()]},
          keyword()
        ) ::
          {:ok, %{applied: non_neg_integer(), skipped: [{String.t(), term()}]}}
  def apply_customer(provider, user_id, customer, opts \\ []) do
    # Oldest first, so a plan change is recognized however the provider orders them.
    subscriptions =
      Enum.sort_by(Map.get(customer, :subscriptions, []), & &1.period_starts_at, DateTime)

    results =
      Enum.map(subscriptions, &{&1.provider_ref, apply_state(provider, user_id, &1, opts)}) ++
        Enum.map(
          Map.get(customer, :one_time, []),
          &{&1.provider_ref, apply_one_time(provider, user_id, &1)}
        )

    {:ok,
     %{
       applied: Enum.count(results, &match?({_, {:ok, _}}, &1)),
       skipped: for({ref, {:error, reason}} <- results, do: {ref, reason})
     }}
  end

  @doc """
  Fetches `user_id`'s current state from `provider` and applies it: call it right after an
  in-app purchase and on "Restore purchases". The fetch runs outside any transaction.
  Rate-limit it per user in the app (each call is one provider API request).
  """
  @spec sync_customer(String.t() | atom(), Ecto.UUID.t(), keyword()) ::
          {:ok, %{applied: non_neg_integer(), skipped: [{String.t(), term()}]}} | {:error, term()}
  def sync_customer(provider, user_id, opts \\ []) do
    provider = to_string(provider)

    with {:ok, {module, provider_opts}} <- Config.provider(provider),
         :ok <- fetches?(module),
         {:ok, customer} <- module.fetch_customer(user_id, provider_opts) do
      apply_customer(provider, user_id, customer, opts)
    end
  end

  defp fetches?(module) do
    if UdinBilling.Provider.implements?(module, :fetch_customer, 2),
      do: :ok,
      else: {:error, :fetch_customer_not_supported}
  end

  @doc """
  Subscriptions granting access at `at` (default now), oldest period first: of `user_ids`,
  or of everyone when it's nil. A store grace period counts when
  `config :udin_billing, :grace_access` is on, the same rule as a user's access. For lists
  and counts (e.g. "who is subscribed"), in one query whatever the number of users.
  """
  @spec active(DateTime.t(), [Ecto.UUID.t()] | nil) :: [struct()]
  def active(at \\ DateTime.utc_now(), user_ids \\ nil) do
    Subscription
    |> Ash.Query.for_read(:active, %{
      user_ids: user_ids,
      at: at,
      include_grace: Config.grace_access?()
    })
    |> Ash.read!(authorize?: false)
  end

  @doc "True when a subscription to `plan` may renew: recurring, active, and recurring enabled."
  @spec renewable?(struct()) :: boolean()
  def renewable?(%{kind: :recurring, status: :active}), do: Config.mode_enabled?(:recurring)
  def renewable?(_plan), do: false

  # -- one-time store purchases ------------------------------------------------

  defp apply_one_time(provider, user_id, item) do
    with :ok <- check_sandbox(item),
         {:ok, plan} <- one_time_plan(provider, item.product_id),
         {:ok, purchase} <-
           Purchases.record_paid(user_id, plan.id, provider, item.provider_ref,
             paid_at: item.paid_at
           ) do
      if Map.get(item, :refunded_at),
        do: Purchases.refund(purchase.id, "#{provider} refund"),
        else: {:ok, purchase}
    end
  end

  # -- subscriptions ----------------------------------------------------------

  defp upsert(nil, plan, provider, user_id, state, now) do
    attrs =
      plan
      |> Terms.access_terms()
      |> Map.merge(dates(state, now))
      |> Map.merge(%{
        user_id: user_id,
        plan_id: plan.id,
        provider: provider,
        provider_ref: state.provider_ref
      })

    with {:ok, previous} <- {:ok, active_at_start(user_id, provider, state)},
         {:ok, subscription} <- Ash.create(Subscription, attrs, authorize?: false),
         :ok <- replace_previous(previous, subscription) do
      {:ok, {subscription, [{:started, plan}]}}
    end
  end

  # The provider says this subscription now belongs to someone else (a restore on another
  # account). Moving access between accounts silently would let one purchase serve many,
  # so it's refused and kept for an admin. Configure the provider to keep purchases with
  # their original account (RevenueCat: "Keep with original App User ID").
  defp upsert(%Subscription{user_id: owner} = existing, _plan, _provider, user_id, _state, _now)
       when owner != user_id,
       do: {:rejected, {:owned_by_another_user, existing.id}}

  # A state older than the stored one (a slow fetch finishing after a newer one) changes
  # nothing: periods only move forward.
  defp upsert(%Subscription{} = existing, plan, provider, user_id, state, now) do
    if DateTime.compare(state.period_starts_at, existing.period_starts_at) == :lt,
      do: {:ok, {existing, []}},
      else: update_existing(existing, plan, provider, user_id, state, now)
  end

  defp update_existing(%Subscription{} = existing, plan, provider, user_id, state, now) do
    new_period? = DateTime.compare(existing.period_starts_at, state.period_starts_at) != :eq
    terms = if new_period?, do: Terms.access_terms(plan), else: %{}
    attrs = Map.merge(terms, dates(state, now))
    # A new period while another subscription is active is a plan change too: switching
    # back to a product used before (A → B → A) reuses A's row.
    previous = if new_period?, do: active_at_start(user_id, provider, state), else: []

    with {:ok, subscription} <-
           existing |> Ash.Changeset.for_update(:update, attrs) |> Ash.update(authorize?: false),
         :ok <- revoke_if_refunded(existing, subscription),
         :ok <- replace_previous(previous, subscription) do
      {:ok, {subscription, if(new_period?, do: [{:renewed, plan}], else: [])}}
    end
  end

  # A provider that doesn't report the store leaves the one recorded as it was.
  defp dates(state, now) do
    refunded_at = Map.get(state, :refunded_at)
    grace_ends_at = Map.get(state, :grace_ends_at)
    access_ends_at = refunded_at || state.period_ends_at

    state
    |> Map.take([:store])
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.merge(%{
      period_starts_at: state.period_starts_at,
      period_ends_at: state.period_ends_at,
      grace_ends_at: grace_ends_at,
      refunded_at: refunded_at,
      access_ends_at: access_ends_at,
      auto_renew: Map.get(state, :auto_renew, true),
      status:
        cond do
          refunded_at -> :refunded
          DateTime.compare(access_ends_at, now) == :gt -> :active
          grace_ends_at && DateTime.compare(grace_ends_at, now) == :gt -> :grace
          true -> :expired
        end
    })
  end

  defp revoke_if_refunded(%{refunded_at: nil}, %{refunded_at: %DateTime{}} = subscription),
    do: Lots.revoke(subscription_id: subscription.id)

  defp revoke_if_refunded(_before, _after), do: :ok

  # A new subscription that started while others were active is a plan change: their
  # units of the cycle it started in are replaced by the new plan's, per the upgrade
  # policy. Judged at the new subscription's start, not at apply time, so a late or
  # out-of-order sync gives the same result.
  defp replace_previous([], _subscription), do: :ok

  defp replace_previous(previous, subscription) do
    start = subscription.period_starts_at

    # Only a change in the middle of the old plan's cycle replaces its units. When the new
    # plan starts where the old cycle would end anyway (renewal boundary, resubscribe), the
    # old cycle's use belongs to the past month and nothing is carried.
    current =
      for old <- previous,
          source = Sources.subscription_source(old),
          at = last_moment_before(old, start),
          {:ok, window} <- [Sources.window(source, at)],
          mid_cycle?(source, at, start),
          do: {source, at, Sources.lot_key(source, window.index)}

    current_keys = Enum.map(current, &elem(&1, 2))

    # Lots are created on first use: an old plan unused this cycle has none yet. Create
    # them first so revoking withdraws the cycle; otherwise it would be granted later at
    # full size, on top of the new plan.
    with :ok <- ensure_withdrawn_lots(subscription.user_id, current),
         used = used_by_key(subscription.user_id, current_keys),
         :ok <- Lots.revoke(source_keys: current_keys) do
      case Config.upgrade_policy() do
        :fresh -> :ok
        :shift -> shift_units(subscription, used, start)
      end
    end
  end

  defp ensure_withdrawn_lots(user_id, current) do
    Enum.reduce_while(current, :ok, fn {source, at, _key}, :ok ->
      case Quotas.ensure_cycle_lots(user_id, [source], at) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp used_by_key(_user_id, []), do: %{}

  defp used_by_key(user_id, source_keys) do
    lot_ids =
      Grant
      |> Ash.Query.for_read(:for_sources, %{user_id: user_id, source_keys: source_keys})
      |> Ash.read!(authorize?: false)
      |> Enum.map(& &1.id)

    # Only spent units: a hold may still be given back, and a held unit sits in the old
    # (withdrawn) lot either way, so counting it would take it off twice.
    Usage
    |> Ash.Query.filter(grant_id in ^lot_ids and status == :committed)
    |> Ash.read!(authorize?: false)
    |> Enum.group_by(& &1.feature_key, & &1.amount)
    |> Map.new(fn {key, amounts} -> {key, Enum.sum(amounts)} end)
  end

  # Pre-creates the new subscription's first lots with the units already used this cycle
  # taken off; lots created later (next cycles) are full.
  defp shift_units(subscription, used, now) do
    source = Sources.subscription_source(subscription)

    Enum.reduce_while(Map.keys(subscription.features), :ok, fn key, :ok ->
      case Quotas.wanted_lots([source], key, now) do
        [lot] -> {:cont, create_shifted(lot, subscription.user_id, Map.get(used, key, 0))}
        [] -> {:cont, :ok}
      end
    end)
  end

  defp create_shifted(lot, user_id, used) do
    remaining = lot.remaining && max(lot.remaining - used, 0)

    case Ash.create(Grant, %{lot | remaining: remaining} |> Map.put(:user_id, user_id),
           action: :ensure,
           authorize?: false
         ) do
      {:ok, _lot} -> :ok
      {:error, _} = error -> error
    end
  end

  # Stores end the old subscription at (about) the moment the new one starts on an
  # upgrade, so the handover allows a few minutes of clock difference either way. Only a
  # subscription whose access ends at that handover is the one being replaced: one that
  # keeps running past it is a second subscription paid alongside (another phone, or a
  # Play purchase without replacement) and keeps its units. `apply_customer/4` applies the
  # oldest first, so the old one's new end is stored before the new one arrives.
  @handover_slack_seconds 300

  defp active_at_start(user_id, provider, state) do
    start = state.period_starts_at
    ended_after = DateTime.add(start, -@handover_slack_seconds, :second)
    ended_by = DateTime.add(start, @handover_slack_seconds, :second)

    Subscription
    |> Ash.Query.filter(
      user_id == ^user_id and provider == ^provider and provider_ref != ^state.provider_ref and
        status != :refunded and period_starts_at < ^start and access_ends_at > ^ended_after and
        access_ends_at <= ^ended_by
    )
    |> Ash.read!(authorize?: false)
  end

  defp mid_cycle?(source, at, start) do
    case UdinBilling.Cycle.window(source.anchor, source.cycle_unit, source.cycle_count, nil, at) do
      {:ok, %{ends_at: natural_end}} ->
        DateTime.compare(natural_end, DateTime.add(start, @handover_slack_seconds, :second)) ==
          :gt

      :none ->
        false
    end
  end

  # The old subscription's last moment within its access, at or before `start`.
  defp last_moment_before(old, start) do
    last = DateTime.add(old.access_ends_at, -1, :microsecond)
    if DateTime.compare(last, start) == :lt, do: last, else: start
  end

  defp lock(provider, provider_ref) do
    Subscription
    |> Ash.Query.for_read(:by_provider_ref, %{provider: provider, provider_ref: provider_ref})
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
  end

  defp recurring_plan(provider, product_id) do
    case Plan.by_product_id(provider, product_id) do
      %Plan{kind: :recurring} = plan -> {:ok, plan}
      %Plan{} -> {:error, {:not_a_recurring_plan, product_id}}
      nil -> {:error, {:unknown_product, product_id}}
    end
  end

  defp one_time_plan(provider, product_id) do
    case Plan.by_product_id(provider, product_id) do
      %Plan{kind: :one_time} = plan -> {:ok, plan}
      %Plan{} -> {:error, {:not_a_one_time_plan, product_id}}
      nil -> {:error, {:unknown_product, product_id}}
    end
  end

  defp check_sandbox(item) do
    if Map.get(item, :sandbox, false) and not Config.allow_sandbox?(),
      do: {:error, :sandbox_not_allowed},
      else: :ok
  end

  defp emit(event, subscription, plan) do
    metadata = %{
      subscription_id: subscription.id,
      user_id: subscription.user_id,
      plan_id: plan.id
    }

    :telemetry.execute([:udin_billing, :subscription, event], %{count: 1}, metadata)

    if event == :renewed and plan.status != :active do
      :telemetry.execute(
        [:udin_billing, :subscription, :renewed_inactive_plan],
        %{count: 1},
        metadata
      )
    end
  end
end

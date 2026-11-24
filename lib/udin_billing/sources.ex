defmodule UdinBilling.Sources do
  @moduledoc """
  Where a user's access comes from at a moment: the free default plan, paid one-time
  purchases still within their validity, and subscriptions still within their access
  window.

  ## Why one list
  Switches, counters and balances all start from the same question, "which plans count
  right now?". Answering it in one place keeps every check consistent, and it takes a fixed
  number of indexed queries (account, default plan, purchases, subscriptions).

  Every source carries its own copied features, start date (anchor), cycle and end, so the
  current cycle and its lot key are computed the same way for all three kinds.
  """
  alias UdinBilling.{Account, Cycle, Plan, Purchase, Subscription}

  require Ash.Query

  defmodule Source do
    @moduledoc "One plan that grants access to a user right now."
    @enforce_keys [:key, :kind, :plan_id, :features, :anchor]
    defstruct [
      :key,
      :kind,
      :plan_id,
      :purchase_id,
      :subscription_id,
      :features,
      :anchor,
      :cycle_unit,
      :cycle_count,
      :ends_at,
      :cycle_ends_at
    ]

    @type t :: %__MODULE__{
            key: String.t(),
            kind: :default | :purchase | :subscription,
            plan_id: Ecto.UUID.t(),
            purchase_id: Ecto.UUID.t() | nil,
            subscription_id: Ecto.UUID.t() | nil,
            features: map(),
            anchor: DateTime.t(),
            cycle_unit: atom() | nil,
            cycle_count: pos_integer() | nil,
            ends_at: DateTime.t() | nil,
            cycle_ends_at: DateTime.t() | nil
          }
  end

  @doc """
  The sources granting access to `user_id` at `now`. The free plan's cycles start at the
  user's account anchor; with no account yet, at `now` (the account is created on the
  user's first spend).

  While a subscription's period is paid, it replaces the free plan (Basic = 15, not 15 +
  the free 3), unless `config :udin_billing, free_plan_with_subscription: :keep`. In the
  store's grace period the free plan's allowance comes back. One-time
  purchases always add on top. The free plan's own cycles keep running by date, so a user
  back on free continues the free cycle they were in: free units used earlier in that
  cycle stay used.
  """
  @spec list(Ecto.UUID.t(), DateTime.t()) :: [Source.t()]
  def list(user_id, now) do
    subscriptions = subscriptions(user_id, now)
    free_plan(user_id, now, subscriptions) ++ purchases(user_id, now) ++ subscriptions
  end

  defp free_plan(user_id, now, []), do: default(user_id, now)

  defp free_plan(user_id, now, subscriptions) do
    case UdinBilling.Config.free_plan_with_subscription() do
      :replace ->
        if Enum.any?(subscriptions, &paid_now?(&1, now)), do: [], else: default(user_id, now)

      :keep ->
        default(user_id, now)
    end
  end

  # A subscription replaces the free plan only while its period is paid. In the store's
  # grace period (payment being retried) it keeps its switches but grants no new units, so
  # the free plan's allowance comes back meanwhile, rather than leaving the user with none.
  defp paid_now?(%Source{cycle_ends_at: %DateTime{} = paid_until}, now),
    do: DateTime.compare(paid_until, now) == :gt

  defp paid_now?(_source, _now), do: true

  @doc """
  The counter cycle of `source` containing `now`, or `:none`. Cycles end at the paid
  period's end (`cycle_ends_at`), which for a subscription in its store grace period is
  before its access end: grace keeps switches on but grants no new, unpaid units.
  """
  @spec window(Source.t(), DateTime.t()) :: {:ok, Cycle.window()} | :none
  def window(%Source{} = source, now) do
    Cycle.window(source.anchor, source.cycle_unit, source.cycle_count, cycle_end(source), now)
  end

  defp cycle_end(%Source{cycle_ends_at: nil, ends_at: ends_at}), do: ends_at
  defp cycle_end(%Source{cycle_ends_at: cycle_ends_at}), do: cycle_ends_at

  @doc "The lot key of `source` in cycle `index`."
  @spec lot_key(Source.t(), non_neg_integer()) :: String.t()
  def lot_key(%Source{key: key}, index), do: "#{key}:#{index}"

  @doc "Keys of the switches that are on in any of `sources`."
  @spec switches_on([Source.t()]) :: MapSet.t(String.t())
  def switches_on(sources) do
    sources
    |> Enum.flat_map(&UdinBilling.FeatureValue.switches_on(&1.features))
    |> MapSet.new()
  end

  defp default(user_id, now) do
    case Plan.default_plan() do
      nil ->
        []

      plan ->
        {anchor, restart} = free_start(plan, user_id, now)

        [
          %Source{
            # The cycle shape is part of the key: changing the free plan from monthly to
            # lifetime (or similar) starts the new allowance instead of colliding with old
            # lots. Switching to another plan with the same shape mid-period doesn't.
            # A fresh start after a subscription adds its own suffix: new lots, new units.
            key: "default:#{shape(plan)}" <> restart,
            kind: :default,
            plan_id: plan.id,
            features: plan.features,
            anchor: anchor,
            cycle_unit: plan.cycle_unit,
            cycle_count: plan.cycle_count,
            ends_at: Plan.expires_at(plan, anchor)
          }
        ]
    end
  end

  # Where the free allowance starts, and the key suffix of a fresh start. With
  # `after_subscription: :fresh_start` (and subscriptions replacing the free plan), the
  # allowance restarts when the user's latest subscription ended.
  defp free_start(%{after_subscription: :fresh_start}, user_id, now) do
    anchor = account_anchor(user_id) || now

    with :replace <- UdinBilling.Config.free_plan_with_subscription(),
         %DateTime{} = ended <- last_subscription_end(user_id, now),
         :gt <- DateTime.compare(ended, anchor) do
      {ended, ":after:#{DateTime.to_unix(ended, :millisecond)}"}
    else
      _ -> {anchor, ""}
    end
  end

  defp free_start(_plan, user_id, now), do: {account_anchor(user_id) || now, ""}

  # The last moment a subscription really ended: after its store grace period too, since
  # a renewal can still succeed until then. A refunded subscription never ended a paid
  # stretch, so it doesn't count. Otherwise every failed renewal or refund would hand out
  # a new allowance while the user stays subscribed.
  defp last_subscription_end(user_id, now) do
    Subscription
    |> Ash.Query.filter(
      user_id == ^user_id and is_nil(refunded_at) and access_ends_at <= ^now and
        (is_nil(grace_ends_at) or grace_ends_at <= ^now)
    )
    |> Ash.Query.sort(access_ends_at: :desc)
    |> Ash.Query.select([:access_ends_at, :grace_ends_at])
    |> Ash.Query.limit(1)
    |> Ash.read_one!(authorize?: false)
    |> case do
      nil -> nil
      %{grace_ends_at: nil} = subscription -> subscription.access_ends_at
      subscription -> latest(subscription.access_ends_at, subscription.grace_ends_at)
    end
  end

  defp latest(a, b), do: if(DateTime.compare(a, b) == :lt, do: b, else: a)

  defp shape(%{cycle_unit: nil}), do: "once"
  defp shape(%{cycle_unit: unit, cycle_count: count}), do: "#{unit}#{count}"

  defp account_anchor(user_id) do
    Account
    |> Ash.Query.for_read(:for_user, %{user_id: user_id})
    |> Ash.read_one!(authorize?: false)
    |> case do
      nil -> nil
      account -> account.anchor_at
    end
  end

  defp purchases(user_id, now) do
    Purchase
    |> Ash.Query.for_read(:active_for_user, %{user_id: user_id, at: now})
    |> Ash.read!(authorize?: false)
    |> Enum.map(fn purchase ->
      %Source{
        key: "purchase:#{purchase.id}",
        kind: :purchase,
        plan_id: purchase.plan_id,
        purchase_id: purchase.id,
        features: purchase.features,
        anchor: purchase.paid_at,
        cycle_unit: purchase.cycle_unit,
        cycle_count: purchase.cycle_count,
        ends_at: purchase.access_expires_at
      }
    end)
  end

  defp subscriptions(user_id, now) do
    now
    |> UdinBilling.Subscriptions.active([user_id])
    |> Enum.map(&subscription_source/1)
  end

  @doc "The source of a subscription's current paid period."
  @spec subscription_source(struct()) :: Source.t()
  def subscription_source(subscription) do
    %Source{
      # The period start is part of the key: a renewal starts new cycles (no carry over).
      key:
        "sub:#{subscription.id}:#{DateTime.to_unix(subscription.period_starts_at, :millisecond)}",
      kind: :subscription,
      plan_id: subscription.plan_id,
      subscription_id: subscription.id,
      features: subscription.features,
      anchor: subscription.period_starts_at,
      cycle_unit: subscription.cycle_unit,
      cycle_count: subscription.cycle_count,
      ends_at: access_end(subscription),
      # Counters only come from paid periods: no new cycle during grace.
      cycle_ends_at: subscription.access_ends_at
    }
  end

  # Paid access end, extended by the store's grace period when the app allows it.
  defp access_end(%{refunded_at: nil, grace_ends_at: %DateTime{} = grace, access_ends_at: paid}) do
    if UdinBilling.Config.grace_access?() and DateTime.compare(grace, paid) == :gt,
      do: grace,
      else: paid
  end

  defp access_end(subscription), do: subscription.access_ends_at
end

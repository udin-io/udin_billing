defmodule UdinBilling.Quotas do
  @moduledoc """
  Spending and reading counters (reel imports, rides, ...).

  ## Two ways to spend
    * **Hold, then decide** (work that can fail, e.g. a reel extraction):
      `reserve/3` when the work starts takes the units so nobody else can use them;
      `commit/3` when it succeeds counts them; `release/3` on any failure gives them back.
      A hold left open (crash, lost request) lapses after `:hold_ttl` and its units return
      automatically.
    * **Spend now** (`consume/3`, e.g. a ride booking): hold and commit in one step, safe
      to call inside the app's own transaction.

  Every call takes a `reference` (extraction id, booking id). Repeating a call with the
  same reference never takes units twice.

  ## How a spend works
  In one transaction:
    1. Create the user's billing account if new (anchors the free plan's cycles).
    2. Create this cycle's lot for every source that grants the counter, if missing.
    3. Give back units of lapsed holds.
    4. Lock the user's spendable lots of that counter (`FOR UPDATE`), soonest-expiring
       first, so concurrent spends for the same user queue instead of overspending.
    5. If the reference already holds or used units, return them unchanged.
    6. Take units from an unlimited lot if there is one, otherwise across lots in expiry
       order, and record one `UdinBilling.Usage` per lot.

  Running out returns `{:error, :insufficient_quota}` without rolling back the caller's
  transaction; only the account and lot rows from steps 1–2 may have been created, and
  creating them is safe at any time.
  """
  require Ash.Query

  alias UdinBilling.{Account, Config, Feature, FeatureValue, Grant, Sources, Transaction, Usage}

  @type balance :: %{
          feature: String.t(),
          remaining: non_neg_integer() | :unlimited,
          limit: non_neg_integer() | :unlimited,
          resets_at: DateTime.t() | nil
        }

  @type result :: {:ok, [struct()]} | {:error, :insufficient_quota | :unknown_counter | term()}

  @doc """
  Holds `amount` units (default 1) of counter `key` for `user_id` under `opts[:reference]`.
  Options: `:reference` (required), `:amount`, `:now`.
  """
  @spec reserve(Ecto.UUID.t(), String.t(), keyword()) :: result()
  def reserve(user_id, key, opts), do: spend(user_id, key, opts, :held)

  @doc """
  Holds and counts in one step. Same options as `reserve/3`.
  """
  @spec consume(Ecto.UUID.t(), String.t(), keyword()) :: result()
  def consume(user_id, key, opts), do: spend(user_id, key, opts, :committed)

  @doc """
  Counts the units held under `opts[:reference]`. If the hold already lapsed and was given
  back, it tries to take the units again (so finished work is still charged when units are
  left). Committing twice is a no-op.
  """
  @spec commit(Ecto.UUID.t(), String.t(), keyword()) :: result()
  def commit(user_id, key, opts) do
    with {:ok, call} <- call(key, opts) do
      Transaction.run([Grant, Usage, Account], fn ->
        with {:ok, _account} <- lock_account(user_id, call.now) do
          user_id |> lock_live(call) |> commit_live(user_id, call)
        end
      end)
      |> unwrap(user_id, call, :committed)
    end
  end

  @doc """
  Gives back the units held under `opts[:reference]` (work failed, wasn't a recipe, ...).
  Releasing nothing is a no-op; units already committed can't be released.
  """
  @spec release(Ecto.UUID.t(), String.t(), keyword()) ::
          {:ok, [struct()]} | {:error, :already_committed | :unknown_counter | term()}
  def release(user_id, key, opts) do
    with {:ok, call} <- call(key, opts) do
      Transaction.run([Grant, Usage], fn ->
        user_id |> lock_live(call) |> release_live()
      end)
      |> unwrap(user_id, call, :released)
    end
  end

  @doc "The balance of counter `key` for `user_id`. Reads only. Option: `:now`."
  @spec balance(Ecto.UUID.t(), String.t(), keyword()) ::
          {:ok, balance()} | {:error, :unknown_counter}
  def balance(user_id, key, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with :ok <- check_counter(key) do
      sources = Sources.list(user_id, now)
      {:ok, Map.fetch!(balances(user_id, sources, now, [key]), key)}
    end
  end

  @doc """
  Balances of `keys` for `user_id` from already-loaded `sources`, in two queries (lots and
  lapsed holds). Only lots of the given sources count. Used by `UdinBilling.Access` to read
  every counter at once.
  """
  @spec balances(Ecto.UUID.t(), [Sources.Source.t()], DateTime.t(), [String.t()]) :: %{
          String.t() => balance()
        }
  def balances(user_id, sources, now, keys) do
    owners = MapSet.new(sources, & &1.key)

    lots =
      user_id
      |> spendable(nil, now, false)
      |> Enum.filter(&MapSet.member?(owners, owner(&1.source_key)))

    lapsed = lapsed_by_lot(user_id, now)
    # Every lot that exists for these sources' current cycles, revoked ones included, so a
    # cycle whose lot was revoked (refund, plan change) isn't counted again as pending.
    lot_keys = existing_lot_keys(user_id, sources, now, keys)

    Map.new(keys, fn key ->
      existing =
        for lot <- lots, lot.feature_key == key do
          %{
            remaining: lot.remaining && lot.remaining + Map.get(lapsed, lot.id, 0),
            amount: lot.amount,
            expires_at: lot.expires_at
          }
        end

      {key, summarize(key, existing ++ pending(sources, key, lot_keys, now))}
    end)
  end

  # -- spending ---------------------------------------------------------------

  defp spend(user_id, key, opts, status) do
    with {:ok, call} <- call(key, opts) do
      Transaction.run([Grant, Usage, Account], fn -> take(user_id, call, status) end)
      |> unwrap(user_id, call, status)
    end
  end

  # Locking the user's account row first makes all spends of one user run one at a time,
  # so the "already charged for this reference?" check below can't race (two calls with
  # the same reference could otherwise each charge a different lot).
  defp take(user_id, call, status) do
    with {:ok, _account} <- lock_account(user_id, call.now),
         sources = Sources.list(user_id, call.now),
         :ok <- ensure_lots(user_id, call.key, sources, call.now),
         :ok <- reclaim_lapsed(user_id, call.key, call.now),
         {:ok, []} <- live(user_id, call) do
      user_id
      |> spendable(call.key, call.now, true)
      |> owned_by(sources)
      |> allocate(call.amount)
      |> record(user_id, call, status)
    else
      {:ok, [_ | _] = existing} -> {:ok, {:repeat, existing}}
      {:error, _} = error -> error
    end
  end

  defp allocate(lots, amount) do
    case Enum.find(lots, &Grant.unlimited?/1) do
      %Grant{} = unlimited -> {:ok, [{unlimited, amount}]}
      nil -> take_from(lots, amount, [])
    end
  end

  defp take_from(_lots, 0, taken), do: {:ok, Enum.reverse(taken)}
  defp take_from([], _needed, _taken), do: {:error, :insufficient_quota}
  defp take_from([%Grant{remaining: 0} | rest], needed, taken), do: take_from(rest, needed, taken)

  defp take_from([%Grant{remaining: remaining} = lot | rest], needed, taken) do
    units = min(remaining, needed)
    take_from(rest, needed - units, [{lot, units} | taken])
  end

  defp record({:error, reason}, _user_id, _call, _status), do: {:rejected, reason}

  defp record({:ok, allocation}, user_id, call, status) do
    hold_expires_at = if status == :held, do: DateTime.add(call.now, Config.hold_ttl(), :second)

    allocation
    |> Enum.reduce_while({:ok, []}, fn {lot, units}, {:ok, usages} ->
      with {:ok, _lot} <- debit(lot, units),
           {:ok, usage} <- create_usage(lot, units, user_id, call, status, hold_expires_at) do
        {:cont, {:ok, [usage | usages]}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, usages} -> {:ok, {:new, Enum.reverse(usages)}}
      error -> error
    end
  end

  defp debit(%Grant{remaining: nil} = lot, _units), do: {:ok, lot}

  defp debit(lot, units) do
    lot |> Ash.Changeset.for_update(:debit, %{units: units}) |> Ash.update(authorize?: false)
  end

  defp credit(%Grant{remaining: nil} = lot, _units), do: {:ok, lot}

  defp credit(lot, units) do
    lot |> Ash.Changeset.for_update(:credit, %{units: units}) |> Ash.update(authorize?: false)
  end

  defp create_usage(lot, units, user_id, call, status, hold_expires_at) do
    Ash.create(
      Usage,
      %{
        user_id: user_id,
        grant_id: lot.id,
        feature_key: call.key,
        amount: units,
        reference: call.reference,
        status: status,
        hold_expires_at: hold_expires_at
      },
      authorize?: false
    )
  end

  # -- commit / release ---------------------------------------------------------

  defp lock_live(user_id, call) do
    Usage
    |> Ash.Query.for_read(:live_for_reference, %{
      user_id: user_id,
      feature_key: call.key,
      reference: call.reference
    })
    |> Ash.Query.lock(:for_update)
    |> Ash.Query.load(:grant)
    |> Ash.read(authorize?: false)
  end

  defp commit_live({:ok, []}, user_id, call), do: take(user_id, call, :committed)

  defp commit_live({:ok, usages}, _user_id, _call) do
    if Enum.all?(usages, &(&1.status == :committed)),
      do: {:ok, {:repeat, usages}},
      else: update_all(usages, :commit)
  end

  defp commit_live(error, _user_id, _call), do: error

  defp release_live({:ok, []}), do: {:ok, {:repeat, []}}

  defp release_live({:ok, usages}) do
    if Enum.any?(usages, &(&1.status == :committed)) do
      {:rejected, :already_committed}
    else
      give_back(usages)
    end
  end

  defp release_live(error), do: error

  defp give_back(usages) do
    usages
    |> Enum.reduce_while({:ok, []}, fn usage, {:ok, done} ->
      with {:ok, _lot} <- credit(usage.grant, usage.amount),
           {:ok, released} <- update(usage, :release) do
        {:cont, {:ok, [released | done]}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, released} -> {:ok, {:new, Enum.reverse(released)}}
      error -> error
    end
  end

  defp update_all(usages, action) do
    usages
    |> Enum.reduce_while({:ok, []}, fn usage, {:ok, done} ->
      case update(usage, action) do
        {:ok, updated} -> {:cont, {:ok, [updated | done]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, updated} -> {:ok, {:new, Enum.reverse(updated)}}
      error -> error
    end
  end

  defp update(usage, action),
    do: usage |> Ash.Changeset.for_update(action, %{}) |> Ash.update(authorize?: false)

  # Holds whose time ran out give their units back before anyone spends, so a crashed
  # extraction never keeps units stuck.
  defp reclaim_lapsed(user_id, key, now) do
    Usage
    |> Ash.Query.for_read(:lapsed_holds, %{user_id: user_id, feature_key: key, at: now})
    |> Ash.Query.lock(:for_update)
    |> Ash.Query.load(:grant)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, []} ->
        :ok

      {:ok, usages} ->
        usages
        |> give_back()
        |> then(fn
          {:ok, _} -> :ok
          error -> error
        end)

      error ->
        error
    end
  end

  # -- lots -------------------------------------------------------------------

  # The user's account row, locked for this transaction (created on the first spend).
  defp lock_account(user_id, now) do
    with {:ok, _account} <- ensure_account(user_id, now) do
      Account
      |> Ash.Query.for_read(:for_user, %{user_id: user_id})
      |> Ash.Query.lock(:for_update)
      |> Ash.read_one(authorize?: false)
    end
  end

  # Only lots of sources granting access now can be spent, matching balances/4: a lot of a
  # subscription that ended early, or of a previous period, is never spent from.
  defp owned_by(lots, sources) do
    owners = MapSet.new(sources, & &1.key)
    Enum.filter(lots, &MapSet.member?(owners, owner(&1.source_key)))
  end

  # Read first: the account exists after a user's first spend, so normal spends write
  # nothing here. The upsert covers the first-spend race.
  defp ensure_account(user_id, now) do
    Account
    |> Ash.Query.for_read(:for_user, %{user_id: user_id})
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} ->
        Ash.create(Account, %{user_id: user_id, anchor_at: now},
          action: :ensure,
          authorize?: false
        )

      other ->
        other
    end
  end

  @doc false
  # Creates the current cycle's lot of every counter `sources` grant at `now`, once. Used
  # before withdrawing a cycle (plan change): a revoked lot marks the cycle as used up, a
  # missing one would be granted later at full size.
  @spec ensure_cycle_lots(Ecto.UUID.t(), [Sources.Source.t()], DateTime.t()) ::
          :ok | {:error, term()}
  def ensure_cycle_lots(user_id, sources, now) do
    sources
    |> Enum.flat_map(&Map.keys(&1.features))
    |> Enum.uniq()
    |> Enum.reduce_while(:ok, fn key, :ok ->
      case ensure_lots(user_id, key, sources, now) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  # Creates the current cycle's lot of `key` for every source that grants it, once.
  defp ensure_lots(user_id, key, sources, now) do
    wanted = wanted_lots(sources, key, now)
    existing = existing_keys(user_id, Enum.map(wanted, & &1.source_key))

    wanted
    |> Enum.reject(&MapSet.member?(existing, {&1.source_key, &1.feature_key}))
    |> Enum.reduce_while(:ok, fn attrs, :ok ->
      case Ash.create(Grant, Map.put(attrs, :user_id, user_id),
             action: :ensure,
             authorize?: false
           ) do
        {:ok, _lot} -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  @doc false
  # Lot attributes for the current cycle of each source granting `key`.
  @spec wanted_lots([Sources.Source.t()], String.t(), DateTime.t()) :: [map()]
  def wanted_lots(sources, key, now) do
    for source <- sources,
        value = Map.get(source.features, key),
        granted?(value),
        {:ok, window} <- [Sources.window(source, now)] do
      units = if value == FeatureValue.unlimited(), do: nil, else: value

      %{
        plan_id: source.plan_id,
        purchase_id: source.purchase_id,
        subscription_id: source.subscription_id,
        feature_key: key,
        source_key: Sources.lot_key(source, window.index),
        amount: units,
        remaining: units,
        starts_at: window.starts_at,
        expires_at: window.ends_at
      }
    end
  end

  defp granted?(value), do: value == FeatureValue.unlimited() or (is_integer(value) and value > 0)

  defp existing_keys(_user_id, []), do: MapSet.new()

  defp existing_keys(user_id, source_keys) do
    Grant
    |> Ash.Query.for_read(:for_sources, %{user_id: user_id, source_keys: source_keys})
    |> Ash.read!(authorize?: false)
    |> MapSet.new(&{&1.source_key, &1.feature_key})
  end

  defp spendable(user_id, key, now, lock?) do
    Grant
    |> Ash.Query.for_read(:spendable, %{user_id: user_id, feature_key: key, at: now})
    |> then(&if(lock?, do: Ash.Query.lock(&1, :for_update), else: &1))
    |> Ash.read!(authorize?: false)
  end

  defp live(user_id, call) do
    Usage
    |> Ash.Query.for_read(:live_for_reference, %{
      user_id: user_id,
      feature_key: call.key,
      reference: call.reference
    })
    |> Ash.read(authorize?: false)
  end

  # -- balances ---------------------------------------------------------------

  # "purchase:<id>:3" -> "purchase:<id>": the source a lot belongs to.
  defp owner(source_key), do: String.replace(source_key, ~r/:\d+\z/, "")

  # Lots the current cycle will have but that don't exist yet count at their full amount.
  defp pending(sources, key, lot_keys, now) do
    for lot <- wanted_lots(sources, key, now),
        not MapSet.member?(lot_keys, {lot.source_key, key}) do
      %{remaining: lot.remaining, amount: lot.amount, expires_at: lot.expires_at}
    end
  end

  defp existing_lot_keys(user_id, sources, now, keys) do
    source_keys =
      for source <- sources, {:ok, window} <- [Sources.window(source, now)], uniq: true do
        Sources.lot_key(source, window.index)
      end

    case source_keys do
      [] ->
        MapSet.new()

      _ ->
        Grant
        |> Ash.Query.for_read(:for_sources, %{user_id: user_id, source_keys: source_keys})
        |> Ash.read!(authorize?: false)
        |> Enum.filter(&(&1.feature_key in keys))
        |> MapSet.new(&{&1.source_key, &1.feature_key})
    end
  end

  defp lapsed_by_lot(user_id, now) do
    Usage
    |> Ash.Query.for_read(:lapsed_holds, %{user_id: user_id, at: now})
    |> Ash.read!(authorize?: false)
    |> Enum.group_by(& &1.grant_id, & &1.amount)
    |> Map.new(fn {grant_id, amounts} -> {grant_id, Enum.sum(amounts)} end)
  end

  defp summarize(key, entries) do
    unlimited? = Enum.any?(entries, &is_nil(&1.remaining))

    %{
      feature: key,
      remaining:
        if(unlimited?, do: :unlimited, else: entries |> Enum.map(& &1.remaining) |> Enum.sum()),
      limit:
        if(unlimited?, do: :unlimited, else: entries |> Enum.map(&(&1.amount || 0)) |> Enum.sum()),
      resets_at:
        entries
        |> Enum.filter(&(is_nil(&1.remaining) or &1.remaining > 0))
        |> Enum.map(& &1.expires_at)
        |> Enum.reject(&is_nil/1)
        |> Enum.min(DateTime, fn -> nil end)
    }
  end

  # -- plumbing ---------------------------------------------------------------

  defp call(key, opts) do
    amount = Keyword.get(opts, :amount, 1)

    unless is_integer(amount) and amount > 0 do
      raise ArgumentError, "amount must be a positive integer, got: #{inspect(amount)}"
    end

    with :ok <- check_counter(key) do
      {:ok,
       %{
         key: key,
         amount: amount,
         reference: opts |> Keyword.fetch!(:reference) |> to_string(),
         now: Keyword.get(opts, :now, DateTime.utc_now())
       }}
    end
  end

  defp check_counter(key) do
    case Feature.fetch_by_keys([key]) do
      %{^key => %{kind: :counter}} -> :ok
      _ -> {:error, :unknown_counter}
    end
  end

  defp unwrap({:ok, {kind, usages}}, user_id, call, event) do
    if kind == :new, do: emit(event, user_id, call, %{})
    {:ok, usages}
  end

  defp unwrap({:error, reason} = error, user_id, call, _event) do
    emit(:rejected, user_id, call, %{reason: reason})
    error
  end

  defp emit(event, user_id, call, extra) do
    :telemetry.execute(
      [:udin_billing, :units, event],
      %{amount: call.amount},
      Map.merge(%{user_id: user_id, feature: call.key, reference: call.reference}, extra)
    )
  end
end

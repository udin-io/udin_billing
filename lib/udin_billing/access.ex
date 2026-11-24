defmodule UdinBilling.Access do
  @moduledoc """
  Everything a user can do right now, in one struct: which switches are on, each counter's
  balance, and which plans grant them.

  ## Why
  Screens and APIs usually need several checks at once ("can share?", "reels left?",
  "show the paywall?"). `load/2` answers all of them with a fixed number of indexed queries
  (feature catalog, account, default plan, purchases, subscriptions, lots, lapsed holds)
  instead of one round trip per check. Load it once per request or LiveView mount and
  read from it.

      access = UdinBilling.access(user.id)
      UdinBilling.Access.enabled?(access, "share_recipe")
      UdinBilling.Access.remaining(access, "reel_imports")   # 12 | :unlimited | 0
  """
  alias UdinBilling.{Feature, Quotas, Sources}

  require Ash.Query

  defstruct [:user_id, :at, switches: MapSet.new(), counters: %{}, sources: []]

  @type t :: %__MODULE__{
          user_id: Ecto.UUID.t(),
          at: DateTime.t(),
          switches: MapSet.t(String.t()),
          counters: %{String.t() => Quotas.balance()},
          sources: [Sources.Source.t()]
        }

  @doc "Loads `user_id`'s access at `opts[:now]` (default now). Reads only."
  @spec load(Ecto.UUID.t(), keyword()) :: t()
  def load(user_id, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    sources = Sources.list(user_id, now)

    %__MODULE__{
      user_id: user_id,
      at: now,
      switches: Sources.switches_on(sources),
      counters: Quotas.balances(user_id, sources, now, counter_keys()),
      sources: sources
    }
  end

  @doc "True when switch `key` is on. Unknown or unset switches are off."
  @spec enabled?(t(), String.t()) :: boolean()
  def enabled?(%__MODULE__{switches: switches}, key), do: MapSet.member?(switches, key)

  @doc "Units of counter `key` left now: a number, `:unlimited`, or 0 when not granted."
  @spec remaining(t(), String.t()) :: non_neg_integer() | :unlimited
  def remaining(%__MODULE__{counters: counters}, key) do
    case Map.fetch(counters, key) do
      {:ok, %{remaining: remaining}} -> remaining
      :error -> 0
    end
  end

  @doc "True when at least `amount` units of counter `key` are left."
  @spec can_spend?(t(), String.t(), pos_integer()) :: boolean()
  def can_spend?(access, key, amount \\ 1) do
    case remaining(access, key) do
      :unlimited -> true
      left -> left >= amount
    end
  end

  @doc "True when switch `key` is on for `user_id` now. One check, without counters."
  @spec enabled_now?(Ecto.UUID.t(), String.t(), DateTime.t()) :: boolean()
  def enabled_now?(user_id, key, now \\ DateTime.utc_now()) do
    user_id |> Sources.list(now) |> Sources.switches_on() |> MapSet.member?(key)
  end

  defp counter_keys do
    Feature
    |> Ash.Query.filter(kind == :counter)
    |> Ash.Query.select([:key])
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.key)
  end
end

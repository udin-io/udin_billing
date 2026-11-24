defmodule UdinBilling.Cycle do
  @moduledoc """
  Finds the counter cycle that contains a moment, counted from a source's own start date.

  ## How
  Cycle `k` starts at `anchor + k × count units`, always shifted from the original anchor,
  so months never drift: from Jan 31 the cycles start Feb 28 (29), Mar 31, Apr 30, ...
  A cycle also ends early when the source's access ends.

  Pure functions; no database, no time zones (anchors are exact instants).
  """

  @type unit :: :day | :week | :month | :year
  @type window :: %{
          index: non_neg_integer(),
          starts_at: DateTime.t(),
          ends_at: DateTime.t() | nil
        }

  @doc """
  The cycle containing `now` for a source starting at `anchor` and ending at `ends_at`
  (nil = never). With no cycle unit, the single "cycle" is the whole access period.
  Returns `:none` before the start or after the end.
  """
  @spec window(DateTime.t(), unit() | nil, pos_integer() | nil, DateTime.t() | nil, DateTime.t()) ::
          {:ok, window()} | :none
  def window(anchor, unit, count, ends_at, now) do
    cond do
      DateTime.compare(now, anchor) == :lt -> :none
      ends_at != nil and DateTime.compare(now, ends_at) != :lt -> :none
      is_nil(unit) -> {:ok, %{index: 0, starts_at: anchor, ends_at: ends_at}}
      true -> {:ok, cycle(anchor, unit, count, ends_at, now)}
    end
  end

  defp cycle(anchor, unit, count, ends_at, now) do
    index = anchor |> estimate(unit, count, now) |> settle(anchor, unit, count, now)

    %{
      index: index,
      starts_at: shift(anchor, unit, index * count),
      ends_at: earliest(shift(anchor, unit, (index + 1) * count), ends_at)
    }
  end

  # A close guess from elapsed whole units; `settle/5` corrects the last step either way.
  defp estimate(anchor, unit, count, now), do: max(div(elapsed(anchor, now, unit), count), 0)

  defp elapsed(anchor, now, :day), do: div(DateTime.diff(now, anchor), 86_400)
  defp elapsed(anchor, now, :week), do: div(DateTime.diff(now, anchor), 604_800)
  defp elapsed(anchor, now, :month), do: (now.year - anchor.year) * 12 + now.month - anchor.month
  defp elapsed(anchor, now, :year), do: now.year - anchor.year

  defp settle(index, anchor, unit, count, now) do
    cond do
      index > 0 and after?(shift(anchor, unit, index * count), now) ->
        settle(index - 1, anchor, unit, count, now)

      not after?(shift(anchor, unit, (index + 1) * count), now) ->
        settle(index + 1, anchor, unit, count, now)

      true ->
        index
    end
  end

  defp shift(anchor, unit, amount), do: DateTime.shift(anchor, [{unit, amount}])
  defp after?(a, b), do: DateTime.compare(a, b) == :gt

  defp earliest(a, nil), do: a
  defp earliest(a, b), do: if(after?(a, b), do: b, else: a)
end

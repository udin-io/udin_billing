defmodule UdinBilling.Transaction do
  @moduledoc """
  Runs billing work in one database transaction with a flat result.

  ## Why
  `Ash.transact/2` wraps the function's return value in `{:ok, value}` and rolls back
  when it returns `{:error, _}`. Billing needs a third outcome: a business rejection
  (e.g. not enough quota) that wrote nothing and must NOT roll back, because the caller
  may be inside its own transaction (a booking) and a nested rollback would poison it.

  The function returns one of:
    * `{:ok, value}` - committed, returned as `{:ok, value}`;
    * `{:rejected, reason}` - nothing written, committed, returned as `{:error, reason}`;
    * `{:error, error}` - rolled back, returned as `{:error, error}`.

  ## After commit
  Billing calls nest: a webhook's transaction wraps `Purchases.confirm_payment/2`, which
  runs its own. Telemetry sent when the inner one returns would reach listeners (a screen
  reloading the purchase) before anything is committed. `after_commit/1` queues work until
  the outermost `run/2` of this process commits, and drops it when that one rolls back or
  raises. The queue lives in the process dictionary because a transaction belongs to one
  process; a host transaction around the outermost `run/2` is the host's to handle.
  """

  @depth {__MODULE__, :depth}
  @queue {__MODULE__, :after_commit}

  @doc "Runs `fun` in a transaction over `resources`. See the module doc for results."
  @spec run([module()] | module(), (-> {:ok, term()} | {:rejected, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def run(resources, fun) do
    depth = Process.get(@depth, 0)
    # An outermost run starts with an empty queue: work left by one that raised is dropped.
    if depth == 0, do: Process.delete(@queue)
    Process.put(@depth, depth + 1)

    raw =
      try do
        Ash.transact(resources, fun)
      after
        Process.put(@depth, depth)
      end

    if depth == 0, do: flush(committed?(raw))

    case raw do
      {:ok, {:ok, value}} -> {:ok, value}
      {:ok, {:rejected, reason}} -> {:error, reason}
      {:error, _} = error -> error
    end
  end

  @doc """
  Runs `fun` once the outermost `run/2` of this process commits, or now when no billing
  transaction is open. Dropped when the transaction rolls back.
  """
  @spec after_commit((-> term())) :: :ok
  def after_commit(fun) when is_function(fun, 0) do
    if Process.get(@depth, 0) == 0 do
      fun.()
      :ok
    else
      Process.put(@queue, [fun | Process.get(@queue, [])])
      :ok
    end
  end

  defp committed?({:ok, _}), do: true
  defp committed?({:error, _}), do: false

  # Queued oldest first; the queue is cleared before running so a callback that opens its
  # own transaction starts clean.
  defp flush(committed?) do
    queued = Process.delete(@queue) || []
    if committed?, do: queued |> Enum.reverse() |> Enum.each(& &1.())
    :ok
  end
end

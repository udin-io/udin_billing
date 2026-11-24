defmodule UdinBilling.Test.UserLabels do
  @moduledoc """
  The app side of `:user_labels` for tests: labels users by email and records every call in
  the `__MODULE__.Calls` agent (when a test started it), so tests can count queries.
  """

  @doc "Labels each id with its user's email."
  @spec by_email([String.t()]) :: %{String.t() => String.t()}
  def by_email(ids) do
    if Process.whereis(__MODULE__.Calls), do: Agent.update(__MODULE__.Calls, &[ids | &1])

    UdinBilling.Test.User
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&(&1.id in ids))
    |> Map.new(&{&1.id, "label " <> to_string(&1.email)})
  end

  @doc "A broken hook: answers something that isn't a map."
  @spec broken([String.t()]) :: atom()
  def broken(_ids), do: :not_a_map
end

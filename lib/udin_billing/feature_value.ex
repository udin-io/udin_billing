defmodule UdinBilling.FeatureValue do
  @moduledoc """
  The one place that understands feature values, so plans, purchases, subscriptions and
  access checks all agree.

  Values, as stored in plan/purchase snapshots and returned by access checks:
    * switch: `true` / `false`
    * counter: a non-negative integer, or `"unlimited"`

  A feature missing from a snapshot is off (switch) or 0 (counter).
  """

  @type value :: boolean() | non_neg_integer() | String.t()

  @unlimited "unlimited"

  @doc "The stored form of an unlimited counter."
  @spec unlimited() :: String.t()
  def unlimited, do: @unlimited

  @doc """
  Validates `value` for a feature of `kind` and returns its stored form.
  Accepts `:unlimited` or `"unlimited"` for counters, and strings from forms or JSON
  (`"15"`, `"true"`).
  """
  @spec normalize(:switch | :counter, term()) :: {:ok, value()} | {:error, String.t()}
  def normalize(:switch, value) when is_boolean(value), do: {:ok, value}
  # Admin forms and JSON send strings.
  def normalize(:switch, "true"), do: {:ok, true}
  def normalize(:switch, "false"), do: {:ok, false}
  def normalize(:switch, _value), do: {:error, "a switch must be true or false"}
  def normalize(:counter, value) when is_integer(value) and value >= 0, do: {:ok, value}
  def normalize(:counter, value) when value in [:unlimited, @unlimited], do: {:ok, @unlimited}

  def normalize(:counter, value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, ""} when number >= 0 -> {:ok, number}
      _ -> {:error, "a counter must be a whole number >= 0 or unlimited"}
    end
  end

  def normalize(:counter, _value),
    do: {:error, "a counter must be a whole number >= 0 or unlimited"}

  @doc "Columns of a `UdinBilling.PlanFeature` row for a stored value."
  @spec to_row(value()) :: %{
          enabled: boolean(),
          limit: non_neg_integer() | nil,
          unlimited: boolean()
        }
  def to_row(value) when is_boolean(value), do: %{enabled: value, limit: nil, unlimited: false}
  def to_row(@unlimited), do: %{enabled: true, limit: nil, unlimited: true}

  def to_row(limit) when is_integer(limit),
    do: %{enabled: limit > 0, limit: limit, unlimited: false}

  @doc "Keys of switches that are on in a snapshot."
  @spec switches_on(map()) :: [String.t()]
  def switches_on(features), do: for({key, true} <- features, do: key)
end

defmodule UdinBilling.Catalog.Decoder do
  @moduledoc """
  Reads a catalog file (see `UdinBilling.Catalog`) into checked attributes.

  ## Why a separate step
  A catalog comes from outside the database (a file in the repo, text pasted in the
  dashboard), so nothing in it is trusted. Every enum value is mapped through a fixed
  list (no atom is ever created from input), numbers and prices are parsed, and every
  problem is reported with its place, e.g. `plans[weekly].kind: unknown value "daily"`.
  Business rules (prices, periods, feature values) are checked again by the resources'
  own validations when the catalog is applied.
  """
  alias UdinBilling.FeatureValue

  @format "udin_billing.catalog"
  @version 1

  @feature_kinds %{"switch" => :switch, "counter" => :counter}
  @plan_kinds %{"free" => :free, "one_time" => :one_time, "recurring" => :recurring}
  @units %{"day" => :day, "week" => :week, "month" => :month, "year" => :year}
  @statuses %{"active" => :active, "inactive" => :inactive}
  @after_subscription %{"continue" => :continue, "fresh_start" => :fresh_start}

  @type feature :: %{
          key: String.t(),
          kind: :switch | :counter,
          name: map(),
          description: map(),
          sort_order: integer()
        }
  @type plan :: %{required(:code) => String.t(), optional(atom()) => term()}
  @typedoc "`plans` is nil when the file has no `plans` key: a features-only file."
  @type t :: %{features: [feature()], plans: [plan()] | nil}

  @doc "The file's `format` marker."
  @spec format() :: String.t()
  def format, do: @format

  @doc "The file version this library writes and reads."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc "Parses catalog JSON text. Returns `{:ok, catalog}` or `{:error, [message]}`."
  @spec decode(String.t()) :: {:ok, t()} | {:error, [String.t()]}
  def decode(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} -> from_map(map)
      {:error, error} -> {:error, ["not valid JSON: #{Exception.message(error)}"]}
    end
  end

  @doc "Checks an already-parsed catalog map (string keys, as in the file)."
  @spec from_map(term()) :: {:ok, t()} | {:error, [String.t()]}
  def from_map(%{"format" => @format, "version" => @version} = map) do
    {features, feature_errors} = collect(map["features"], "features", &feature/2)
    kinds = Map.new(features, &{&1.key, &1.kind})
    {plans, plan_errors} = plans(map, kinds)

    case feature_errors ++ plan_errors ++ duplicates(features, plans || []) do
      [] -> {:ok, %{features: features, plans: plans}}
      errors -> {:error, errors}
    end
  end

  def from_map(%{"format" => @format, "version" => version}),
    do:
      {:error,
       ["unsupported catalog version #{inspect(version)}. This library reads #{@version}"]}

  def from_map(_other),
    do: {:error, [~s(not a billing catalog: expected "format": "#{@format}")]}

  # No "plans" key: the file manages features only and plans are left to admins.
  defp plans(%{"plans" => items}, kinds), do: collect(items, "plans", &plan(&1, &2, kinds))
  defp plans(_map, _kinds), do: {nil, []}

  # -- features ---------------------------------------------------------------

  defp feature(%{} = item, place) do
    {%{}, []}
    |> required(:key, string(item["key"]), place, "key")
    |> required(:kind, Map.get(@feature_kinds, item["kind"]), place, "kind")
    |> required(:name, translations(item["name"]), place, "name")
    |> required(:description, translations(item["description"] || %{}), place, "description")
    |> required(:sort_order, integer(item["sort_order"] || 0), place, "sort_order")
    |> label(item["key"])
  end

  defp feature(_item, place), do: {:error, ["#{place}: expected an object"]}

  # -- plans ------------------------------------------------------------------

  defp plan(%{} = item, place, kinds) do
    {%{}, []}
    |> required(:code, string(item["code"]), place, "code")
    |> required(:name, translations(item["name"]), place, "name")
    |> required(:description, translations(item["description"] || %{}), place, "description")
    |> required(:kind, Map.get(@plan_kinds, item["kind"]), place, "kind")
    |> required(:price, decimal(item["price"]), place, "price")
    |> required(:currency, string(item["currency"]), place, "currency")
    |> optional_decimal(:original_price, item["original_price"], place, "original_price")
    |> optional_period(:validity, item, place)
    |> optional_period(:cycle, item, place)
    |> required(:status, Map.get(@statuses, item["status"] || "active"), place, "status")
    |> required(:is_default, boolean(item["is_default"] || false), place, "is_default")
    |> required(:sort_order, integer(item["sort_order"] || 0), place, "sort_order")
    |> required(:metadata, map(item["metadata"] || %{}), place, "metadata")
    |> required(
      :after_subscription,
      Map.get(@after_subscription, item["after_subscription"] || "continue"),
      place,
      "after_subscription"
    )
    |> required(
      :provider_product_ids,
      product_ids(item["provider_product_ids"] || %{}),
      place,
      "provider_product_ids"
    )
    |> required(:features, plan_features(item["features"] || %{}, kinds), place, "features")
    |> label(item["code"])
  end

  defp plan(_item, place, _kinds), do: {:error, ["#{place}: expected an object"]}

  defp optional_period(acc, name, item, place) do
    unit_key = "#{name}_unit"
    count_key = "#{name}_count"

    case {item[unit_key], item[count_key]} do
      {nil, nil} ->
        put_value(acc, [{:"#{name}_unit", nil}, {:"#{name}_count", nil}])

      {unit, count} ->
        acc
        |> required(:"#{name}_unit", Map.get(@units, unit), place, unit_key)
        |> required(:"#{name}_count", positive(count), place, count_key)
    end
  end

  defp optional_decimal(acc, key, nil, _place, _field), do: put_value(acc, [{key, nil}])

  defp optional_decimal(acc, key, value, place, field),
    do: required(acc, key, decimal(value), place, field)

  # Values for features the file defines are checked here; values for features only in
  # the database are checked by the plan's own validation when applied.
  defp plan_features(%{} = values, kinds) do
    Enum.reduce_while(values, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case kinds do
        %{^key => kind} ->
          case FeatureValue.normalize(kind, value) do
            {:ok, normalized} -> {:cont, {:ok, Map.put(acc, key, normalized)}}
            {:error, message} -> {:halt, {:error, "#{key}: #{message}"}}
          end

        _ ->
          {:cont, {:ok, Map.put(acc, key, value)}}
      end
    end)
    |> case do
      {:ok, normalized} -> normalized
      {:error, message} -> {:invalid, message}
    end
  end

  defp plan_features(_values, _kinds), do: nil

  # -- helpers ----------------------------------------------------------------

  defp collect(nil, _section, _fun), do: {[], []}

  defp collect(items, section, fun) when is_list(items) do
    items
    |> Enum.with_index()
    |> Enum.reduce({[], []}, fn {item, index}, {ok, errors} ->
      case fun.(item, "#{section}[#{index}]") do
        {:ok, value} -> {[value | ok], errors}
        {:error, messages} -> {ok, errors ++ messages}
      end
    end)
    |> then(fn {ok, errors} -> {Enum.reverse(ok), errors} end)
  end

  defp collect(_items, section, _fun), do: {[], ["#{section}: expected a list"]}

  defp required({attrs, errors}, _key, {:invalid, message}, place, field),
    do: {attrs, errors ++ ["#{place}.#{field}: #{message}"]}

  defp required({attrs, errors}, _key, nil, place, field),
    do: {attrs, errors ++ ["#{place}.#{field}: missing or not allowed"]}

  defp required({attrs, errors}, key, value, _place, _field),
    do: {Map.put(attrs, key, value), errors}

  defp put_value({attrs, errors}, pairs), do: {Enum.into(pairs, attrs), errors}

  # Errors name the item by its key/code when it has one: "plans[weekly].price".
  defp label({attrs, []}, _name), do: {:ok, attrs}

  defp label({_attrs, errors}, name) when is_binary(name) do
    {:error, Enum.map(errors, &Regex.replace(~r/\[\d+\]/, &1, "[#{name}]", global: false))}
  end

  defp label({_attrs, errors}, _name), do: {:error, errors}

  defp duplicates(features, plans) do
    dupes(Enum.map(features, & &1.key), "feature key") ++
      dupes(Enum.map(plans, & &1.code), "plan code")
  end

  defp dupes(values, what) do
    values
    |> Enum.frequencies()
    |> Enum.filter(fn {_value, count} -> count > 1 end)
    |> Enum.map(fn {value, _count} -> "#{what} #{inspect(value)} appears more than once" end)
  end

  defp string(value) when is_binary(value) and value != "", do: value
  defp string(_value), do: nil

  defp integer(value) when is_integer(value), do: value
  defp integer(_value), do: nil

  defp positive(value) when is_integer(value) and value > 0, do: value
  defp positive(_value), do: nil

  defp boolean(value) when is_boolean(value), do: value
  defp boolean(_value), do: nil

  defp map(value) when is_map(value), do: value
  defp map(_value), do: nil

  defp translations(%{} = texts) do
    if Enum.all?(texts, fn {locale, text} -> is_binary(locale) and is_binary(text) end),
      do: texts,
      else: {:invalid, "expected texts per language, e.g. {\"en\": \"Weekly\"}"}
  end

  defp translations(_value), do: nil

  defp decimal(value) when is_binary(value) do
    case Decimal.parse(value) do
      {decimal, ""} -> decimal
      _ -> {:invalid, "expected a price like \"150.00\""}
    end
  end

  defp decimal(value) when is_integer(value), do: Decimal.new(value)
  defp decimal(_value), do: nil

  defp product_ids(%{} = ids) do
    if Enum.all?(ids, fn {provider, id} -> is_binary(provider) and valid_ids?(id) end),
      do: ids,
      else: {:invalid, "expected provider => product id (or a list of ids)"}
  end

  defp product_ids(_value), do: nil

  defp valid_ids?(id) when is_binary(id), do: true
  defp valid_ids?(ids) when is_list(ids), do: Enum.all?(ids, &is_binary/1)
  defp valid_ids?(_id), do: false
end

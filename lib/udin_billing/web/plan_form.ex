defmodule UdinBilling.Web.PlanForm do
  @moduledoc """
  Converts between a plan and the plan editor's form params, for creating and editing in
  `UdinBilling.Web.PlanFormLive`.

  ## Why a separate module
  The editor shows friendlier controls than the plan's fields ("lasts 1 month" or "never
  ends", a switch or "15 / unlimited / not included" per feature). Keeping the mapping
  here, as pure functions, means it's tested on its own and the LiveView only renders.

  Every value from the form is mapped through fixed lists (kinds, units, providers), so
  user input never creates atoms. Texts users see (name, description) have one field per
  configured language; see `UdinBilling.Web.Fields`.
  """
  use Gettext, backend: UdinBilling.Gettext

  import UdinBilling.Web.Fields,
    only: [put: 3, put_required: 5, put_translations: 4, text: 1, integer: 1, decimal: 1]

  alias UdinBilling.{Config, FeatureValue, Plan}
  alias UdinBilling.Web.Fields

  @kinds %{"free" => :free, "one_time" => :one_time, "recurring" => :recurring}
  @units %{"day" => :day, "week" => :week, "month" => :month, "year" => :year}
  @after_subscription %{"continue" => :continue, "fresh_start" => :fresh_start}

  @type params :: %{String.t() => term()}
  @type errors :: %{String.t() => String.t()}

  @doc "Unit choices for selects, as `{label, value}`."
  @spec unit_options() :: [{String.t(), String.t()}]
  def unit_options,
    do: [
      {dgettext("plan_form", "day(s)"), "day"},
      {dgettext("plan_form", "week(s)"), "week"},
      {dgettext("plan_form", "month(s)"), "month"},
      {dgettext("plan_form", "year(s)"), "year"}
    ]

  @doc "Plan kinds the app allows (`config :udin_billing, :modes`), as `{label, value}`."
  @spec kind_options() :: [{String.t(), String.t()}]
  def kind_options do
    labels = %{
      free: dgettext("plan_form", "Free plan"),
      one_time: dgettext("plan_form", "One-time plan"),
      recurring: dgettext("plan_form", "Subscription plan")
    }

    for kind <- [:free, :one_time, :recurring],
        Config.mode_enabled?(kind),
        do: {labels[kind], Atom.to_string(kind)}
  end

  @doc """
  The free plan's choices for what a user gets back after a subscription ends, as
  `{value, title, explanation}` for the editor.
  """
  @spec after_subscription_options() :: [{String.t(), String.t(), String.t()}]
  def after_subscription_options do
    [
      {"continue", dgettext("plan_form", "Continue where they left off"),
       dgettext(
         "plan_form",
         "Free units they used before subscribing stay used. A one-time free allowance is never given again. A monthly one carries on with its current month. This stops people from collecting free units by subscribing and cancelling."
       )},
      {"fresh_start", dgettext("plan_form", "Fresh start"),
       dgettext(
         "plan_form",
         "Each time a subscription ends, the user gets a new free allowance. A one-time allowance is given again, and a monthly one starts a new month that day. This is friendlier when users move between paid and free often."
       )}
    ]
  end

  @doc "The app's currencies as `{label, value}` for a select (`config :udin_billing, :currencies`)."
  @spec currency_options() :: [{String.t(), String.t()}]
  def currency_options, do: Enum.map(Config.currencies(), &{&1, &1})

  @doc "Provider names configured in this app (for product id fields)."
  @spec providers() :: [String.t()]
  def providers do
    :udin_billing |> Application.get_env(:providers, %{}) |> Map.keys() |> Enum.sort()
  end

  @doc "Form params for `plan` (nil for a new plan), with a value for every catalog feature."
  @spec from_plan(struct() | nil, [struct()]) :: params()
  def from_plan(nil, catalog) do
    %{
      "code" => "",
      "name" => Fields.blank_translations(),
      "description" => Fields.blank_translations(),
      "kind" => default_kind(),
      "price" => "",
      "original_price" => "",
      "currency" => Config.default_currency(),
      "validity_mode" => "period",
      "validity_count" => "1",
      "validity_unit" => "month",
      "cycle_mode" => "none",
      "cycle_count" => "1",
      "cycle_unit" => "month",
      "status" => "active",
      "is_default" => "false",
      "sort_order" => "0",
      "recommended" => "false",
      "after_subscription" => "continue",
      "product_ids" => Map.new(providers(), &{&1, ""}),
      "features" => Map.new(catalog, &{&1.key, feature_params(&1, nil)})
    }
  end

  def from_plan(%Plan{} = plan, catalog) do
    %{
      "code" => plan.code,
      "name" => Fields.translation_params(plan.name),
      "description" => Fields.translation_params(plan.description),
      "kind" => Atom.to_string(plan.kind),
      "price" => Decimal.to_string(plan.price, :normal),
      "original_price" =>
        if(plan.original_price, do: Decimal.to_string(plan.original_price, :normal), else: ""),
      "currency" => plan.currency,
      "validity_mode" => if(plan.validity_unit, do: "period", else: "forever"),
      "validity_count" => to_string(plan.validity_count || 1),
      "validity_unit" => Atom.to_string(plan.validity_unit || :month),
      "cycle_mode" => if(plan.cycle_unit, do: "period", else: "none"),
      "cycle_count" => to_string(plan.cycle_count || 1),
      "cycle_unit" => Atom.to_string(plan.cycle_unit || :month),
      "status" => Atom.to_string(plan.status),
      "is_default" => to_string(plan.is_default),
      "sort_order" => to_string(plan.sort_order),
      "recommended" => to_string(plan.metadata["recommended"] == true),
      "after_subscription" => Atom.to_string(plan.after_subscription),
      "product_ids" =>
        Map.new(providers(), fn provider ->
          {provider,
           plan.provider_product_ids |> Map.get(provider) |> List.wrap() |> Enum.join(", ")}
        end),
      "features" =>
        Map.new(catalog, &{&1.key, feature_params(&1, Map.get(plan.features, &1.key))})
    }
  end

  @doc """
  Form params to start a copy of `plan` (e.g. a yearly version of a monthly plan): same
  values, a new code, not the default plan.
  """
  @spec copy_of(struct(), [struct()]) :: params()
  def copy_of(%Plan{} = plan, catalog) do
    plan
    |> from_plan(catalog)
    |> Map.merge(%{"code" => plan.code <> "-copy", "is_default" => "false"})
  end

  @doc """
  Form params for a new version of a sold `plan`: a copy with a new code (`-v2`, `-v3`,
  ...), on sale, not the default, and without payment provider product ids (each version
  needs its own products at the provider).
  """
  @spec new_version_of(struct(), [struct()]) :: params()
  def new_version_of(%Plan{} = plan, catalog) do
    plan
    |> from_plan(catalog)
    |> Map.merge(%{
      "code" => next_version_code(plan.code),
      "is_default" => "false",
      "status" => "active",
      "product_ids" => Map.new(providers(), &{&1, ""})
    })
  end

  @doc "`\"basic\"` → `\"basic-v2\"`, `\"basic-v2\"` → `\"basic-v3\"`."
  @spec next_version_code(String.t()) :: String.t()
  def next_version_code(code) do
    case Regex.run(~r/\A(.*)-v(\d+)\z/, code) do
      [_, base, n] -> "#{base}-v#{String.to_integer(n) + 1}"
      nil -> code <> "-v2"
    end
  end

  @doc """
  Merges submitted form params into `current` (so fields the browser didn't send, like an
  unchecked switch, keep the form's full shape).
  """
  @spec merge(params(), params()) :: params()
  def merge(current, submitted) do
    Map.merge(current, submitted, fn
      _key, %{} = old, %{} = new -> merge(old, new)
      _key, _old, new -> new
    end)
  end

  @doc """
  Plan attributes for `UdinBilling.Admin.create_plan/2` / `update_plan/3` from form params.
  Returns `{:error, %{field => message}}` for values the form itself can tell are wrong
  (fields like `"price"`, `"name.ar"`, `"features.<key>"`); the plan's own validations
  run on save.
  """
  @spec to_attrs(params(), [struct()]) :: {:ok, map()} | {:error, errors()}
  def to_attrs(params, catalog) do
    case parse(params, catalog) do
      {attrs, errors} when errors == %{} -> {:ok, attrs}
      {_attrs, errors} -> {:error, errors}
    end
  end

  @doc """
  `attrs` from the form, plus what the form doesn't show of `plan`, so saving never wipes
  it: metadata other than the badge (e.g. set by a catalog import or by code), and the
  product ids of providers not configured in this environment (a store configured only in
  production keeps its ids when the plan is edited on staging).
  """
  @spec keep_hidden(map(), struct()) :: map()
  def keep_hidden(attrs, plan) do
    attrs
    |> Map.update(:metadata, plan.metadata, &Map.merge(plan.metadata || %{}, &1))
    |> Map.update(:provider_product_ids, %{}, fn shown ->
      plan.provider_product_ids
      |> Kernel.||(%{})
      |> Map.drop(providers())
      |> Map.merge(shown)
    end)
  end

  @doc """
  Every attribute the params give, with every error. Used by the editor to preview a plan
  while some fields are still wrong; `to_attrs/2` is the strict version for saving.
  """
  @spec parse(params(), [struct()]) :: {map(), errors()}
  def parse(params, catalog) do
    kind = Map.get(@kinds, params["kind"])

    {%{}, %{}}
    |> put_required(:code, text(params["code"]), "code", dgettext("plan_form", "required"))
    |> put_translations(:name, params["name"], true)
    |> put_translations(:description, params["description"], false)
    |> put_required(:kind, kind, "kind", dgettext("plan_form", "choose a type"))
    |> put_required(
      :price,
      price(kind, params["price"]),
      "price",
      dgettext("plan_form", "a number like 150 or 99.50")
    )
    |> put_original_price(kind, params["original_price"])
    |> put_currency(params["currency"])
    |> put_period(:validity, params)
    |> put_period(:cycle, params)
    |> put(:status, if(params["status"] == "inactive", do: :inactive, else: :active))
    |> put(:is_default, kind == :free and Fields.checked?(params["is_default"]))
    |> put(:sort_order, integer(params["sort_order"]) || 0)
    |> put(:metadata, %{"recommended" => Fields.checked?(params["recommended"])})
    |> put(:after_subscription, after_subscription(kind, params["after_subscription"]))
    |> put(:provider_product_ids, product_ids(params["product_ids"]))
    |> put_features(params["features"] || %{}, catalog)
  end

  @doc """
  What the plan includes, in catalog order, with feature names in `locale`: switches that
  are on and counters above zero, as `%{key, name, value}` where `value` is `true`, a
  count, or `"unlimited"`.
  """
  @spec included(map(), [struct()], String.t()) :: [
          %{key: String.t(), name: String.t(), value: true | pos_integer() | String.t()}
        ]
  def included(attrs, catalog, locale) do
    features = Map.get(attrs, :features, %{})

    for feature <- catalog,
        value = Map.get(features, feature.key),
        value not in [nil, false, 0] do
      %{
        key: feature.key,
        name: Plan.localized(feature, :name, locale) || humanize(feature.key),
        value: value
      }
    end
  end

  @doc "A feature key as words: `\"extra_storage\"` → `\"Extra storage\"`."
  @spec humanize(String.t()) :: String.t()
  def humanize(key), do: key |> String.replace("_", " ") |> String.capitalize()

  # -- feature params ---------------------------------------------------------

  defp feature_params(%{kind: :switch}, value), do: %{"on" => to_string(value == true)}

  defp feature_params(%{kind: :counter}, value) do
    case value do
      "unlimited" ->
        %{"mode" => "unlimited", "limit" => ""}

      count when is_integer(count) and count > 0 ->
        %{"mode" => "limited", "limit" => to_string(count)}

      _ ->
        %{"mode" => "off", "limit" => ""}
    end
  end

  defp put_features({attrs, errors}, submitted, catalog) do
    {features, feature_errors} =
      Enum.reduce(catalog, {%{}, %{}}, fn feature, {acc, errs} ->
        case feature_value(feature, Map.get(submitted, feature.key, %{})) do
          {:ok, nil} -> {acc, errs}
          {:ok, value} -> {Map.put(acc, feature.key, value), errs}
          {:error, message} -> {acc, Map.put(errs, "features.#{feature.key}", message)}
        end
      end)

    {Map.put(attrs, :features, features), Map.merge(errors, feature_errors)}
  end

  defp feature_value(%{kind: :switch}, %{"on" => "true"}), do: {:ok, true}
  defp feature_value(%{kind: :switch}, _params), do: {:ok, nil}

  defp feature_value(%{kind: :counter}, %{"mode" => "unlimited"}),
    do: {:ok, FeatureValue.unlimited()}

  defp feature_value(%{kind: :counter}, %{"mode" => "limited", "limit" => limit}) do
    case integer(limit) do
      count when is_integer(count) and count > 0 -> {:ok, count}
      _ -> {:error, dgettext("plan_form", "enter a whole number above 0")}
    end
  end

  defp feature_value(%{kind: :counter}, _params), do: {:ok, nil}

  # -- periods ----------------------------------------------------------------

  defp put_period({attrs, errors}, name, params) do
    count = integer(params["#{name}_count"])
    unit = Map.get(@units, params["#{name}_unit"])
    keys = {:"#{name}_unit", :"#{name}_count"}

    cond do
      params["#{name}_mode"] != "period" ->
        {put_unit_count(attrs, keys, nil, nil), errors}

      is_integer(count) and count > 0 and unit != nil ->
        {put_unit_count(attrs, keys, unit, count), errors}

      true ->
        {attrs,
         Map.put(
           errors,
           "#{name}",
           dgettext("plan_form", "enter a number of days, weeks, months or years")
         )}
    end
  end

  defp put_unit_count(attrs, {unit_key, count_key}, unit, count),
    do: attrs |> Map.put(unit_key, unit) |> Map.put(count_key, count)

  # -- helpers ----------------------------------------------------------------

  # Only the free plan comes back after a subscription; paid plans keep the default.
  defp after_subscription(:free, value), do: Map.get(@after_subscription, value, :continue)
  defp after_subscription(_kind, _value), do: :continue

  # Only the app's configured currencies: with one, there's nothing to choose.
  defp put_currency(acc, submitted) do
    case Config.currencies() do
      [only] ->
        put(acc, :currency, only)

      allowed ->
        code = submitted |> text() |> upcase()

        put_required(
          acc,
          :currency,
          if(code in allowed, do: code),
          "currency",
          dgettext("plan_form", "choose a currency")
        )
    end
  end

  # Optional; blank means "not on sale". Free plans have no sale.
  defp put_original_price(acc, :free, _value), do: put(acc, :original_price, nil)

  defp put_original_price(acc, _kind, value) do
    case text(value) do
      nil ->
        put(acc, :original_price, nil)

      _text ->
        put_required(
          acc,
          :original_price,
          decimal(value),
          "original_price",
          dgettext("plan_form", "a number like 200")
        )
    end
  end

  # The free plan costs nothing, so its price field is hidden and fixed at 0.
  defp price(:free, _value), do: Decimal.new(0)
  defp price(_kind, value), do: decimal(value)

  defp product_ids(map) when is_map(map) do
    for {provider, value} <- map,
        provider in providers(),
        ids = split_ids(value),
        ids != [],
        into: %{},
        do: {provider, if(match?([_], ids), do: hd(ids), else: ids)}
  end

  defp product_ids(_other), do: %{}

  defp split_ids(value) do
    value
    |> to_string()
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp upcase(nil), do: nil
  defp upcase(value), do: String.upcase(value)

  defp default_kind do
    case kind_options() do
      [] ->
        "one_time"

      options ->
        options |> Enum.reject(&(elem(&1, 1) == "free")) |> List.first(hd(options)) |> elem(1)
    end
  end
end

defmodule UdinBilling.Web.Examples do
  @moduledoc """
  The examples the dashboard's help texts show ("For example: 40 Reel imports for 180
  EGP"), taken from the project's own catalog.

  ## Why
  The dashboard is one library used by several apps. If its help texts named one app's
  things, every other app's admins would read someone else's words. So the texts only
  ever say `%{feature}`, `%{price}` and so on, and this module fills them in with the
  project's real feature, plan and currency, in the admin's language.

  ## Where each value comes from
    * `feature` and `feature_key`: the first counter feature of the catalog.
    * `plan_name`, `plan_code` and `price`: the first paid plan.
    * `amount`: how many units that plan gives of that feature.
    * `currency`: the app's default currency.

  Anything the catalog can't give yet (a new project) is a neutral word ("units",
  "Standard", 100). A project can replace any of them:

      config :udin_billing, dashboard_examples: %{feature: "tokens", price: "50"}
  """
  use Gettext, backend: UdinBilling.Gettext
  require Ash.Query

  alias UdinBilling.{Config, Feature, Plan, Translations}

  @keys [:feature, :feature_key, :plan_name, :plan_code, :price, :amount, :currency]

  @type t :: %{
          feature: String.t(),
          feature_key: String.t(),
          plan_name: String.t(),
          plan_code: String.t(),
          price: String.t(),
          amount: integer(),
          currency: String.t()
        }

  @doc "The examples in `lang`, for the dashboard's help texts."
  @spec build(String.t()) :: t()
  def build(lang) do
    Gettext.with_locale(UdinBilling.Gettext, lang, fn ->
      neutral()
      |> Map.merge(from_catalog(lang))
      |> Map.merge(configured())
    end)
  end

  defp neutral do
    %{
      feature: gettext("units"),
      feature_key: "units",
      plan_name: gettext("Standard"),
      plan_code: "standard",
      price: "100",
      amount: 10,
      currency: Config.default_currency()
    }
  end

  defp from_catalog(lang) do
    feature = first_counter()
    plan = first_paid_plan()

    %{}
    |> put_feature(feature, lang)
    |> put_plan(plan, feature, lang)
  end

  defp first_counter do
    Feature
    |> Ash.Query.filter(kind == :counter)
    |> Ash.Query.sort(sort_order: :asc, inserted_at: :asc)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(authorize?: false)
  end

  defp first_paid_plan do
    Plan
    |> Ash.Query.filter(kind != :free)
    |> Ash.Query.sort(sort_order: :asc, inserted_at: :asc)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(authorize?: false)
  end

  defp put_feature(examples, nil, _lang), do: examples

  defp put_feature(examples, feature, lang) do
    Map.merge(examples, %{
      feature: Translations.get(feature.name, lang) || feature.key,
      feature_key: feature.key
    })
  end

  defp put_plan(examples, nil, _feature, _lang), do: examples

  defp put_plan(examples, plan, feature, lang) do
    examples
    |> Map.merge(%{
      plan_name: Translations.get(plan.name, lang) || plan.code,
      plan_code: plan.code,
      price: price(plan.price)
    })
    |> put_amount(plan, feature)
  end

  defp put_amount(examples, plan, %Feature{key: key}) do
    case plan.features[key] do
      amount when is_integer(amount) and amount > 0 -> Map.put(examples, :amount, amount)
      _not_a_count -> examples
    end
  end

  defp put_amount(examples, _plan, nil), do: examples

  defp price(price) do
    if Decimal.integer?(price),
      do: price |> Decimal.round() |> Decimal.to_string(:normal),
      else: Decimal.to_string(price, :normal)
  end

  defp configured do
    case Application.get_env(:udin_billing, :dashboard_examples, %{}) do
      examples when is_map(examples) ->
        if Enum.all?(Map.keys(examples), &(&1 in @keys)),
          do: examples,
          else: invalid!(examples)

      other ->
        invalid!(other)
    end
  end

  defp invalid!(value) do
    raise ArgumentError,
          "invalid :udin_billing :dashboard_examples: #{inspect(value)}, " <>
            "expected a map with keys from #{inspect(@keys)}"
  end
end

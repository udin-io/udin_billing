defmodule UdinBilling.DataCase do
  @moduledoc """
  Test case with a sandboxed repo and billing fixtures.

  The catalog used by fixtures mirrors the two apps: counters `rides` (Family-Corp) and
  `reel_imports` (ReelsChef); switches `share_recipe`, `meal_plan`, `smart_aggregation`.
  """
  use ExUnit.CaseTemplate

  alias UdinBilling.{Feature, Plan}

  using do
    quote do
      import UdinBilling.DataCase

      alias UdinBilling.{Feature, Plan, PlanFeature}
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(UdinBilling.TestRepo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    catalog_fixture()
    :ok
  end

  @catalog [
    {"rides", :counter},
    {"reel_imports", :counter},
    {"share_recipe", :switch},
    {"meal_plan", :switch},
    {"smart_aggregation", :switch}
  ]

  @doc "Creates the shared feature catalog (idempotent within a test)."
  def catalog_fixture do
    for {key, kind} <- @catalog, into: %{} do
      case Feature.fetch_by_keys([key]) do
        %{^key => feature} ->
          {key, feature}

        _ ->
          {key,
           Ash.create!(Feature, %{key: key, kind: kind, name: %{"en" => key, "ar" => key}},
             authorize?: false
           )}
      end
    end
  end

  @doc "Runs `fun` with `:udin_billing` `key` set to `value`, restoring it afterwards."
  def with_env(key, value, fun) do
    previous = Application.fetch_env(:udin_billing, key)
    Application.put_env(:udin_billing, key, value)

    try do
      fun.()
    after
      case previous do
        {:ok, old} -> Application.put_env(:udin_billing, key, old)
        :error -> Application.delete_env(:udin_billing, key)
      end
    end
  end

  @doc "Creates a user."
  def user_fixture, do: user_fixture(%{})

  def user_fixture(attrs) do
    Ash.create!(
      UdinBilling.Test.User,
      Map.merge(%{email: "user#{System.unique_integer([:positive])}@example.com"}, attrs),
      authorize?: false
    )
  end

  @doc "Creates a plan: by default a Family-Corp weekly bundle, 10 rides, 150 EGP."
  def plan_fixture(attrs \\ %{}) do
    defaults = %{
      code: "plan-#{System.unique_integer([:positive])}",
      name: %{"en" => "Weekly", "ar" => "أسبوعي"},
      kind: :one_time,
      price: Decimal.new("150.00"),
      currency: "EGP",
      validity_unit: :week,
      validity_count: 1,
      features: %{"rides" => 10}
    }

    Ash.create!(Plan, Map.merge(defaults, attrs), authorize?: false)
  end

  @doc "Creates the default free plan: 3 reel imports a month, every switch off."
  def free_plan_fixture(attrs \\ %{}) do
    plan_fixture(
      Map.merge(
        %{
          code: "free",
          name: %{"en" => "Free", "ar" => "مجاني"},
          kind: :free,
          price: Decimal.new(0),
          is_default: true,
          validity_unit: nil,
          validity_count: nil,
          cycle_unit: :month,
          cycle_count: 1,
          features: %{"reel_imports" => 3, "share_recipe" => false}
        },
        attrs
      )
    )
  end

  @doc "Creates a ReelsChef-style monthly subscription plan sold through the fake provider."
  def subscription_plan_fixture(attrs \\ %{}) do
    plan_fixture(
      Map.merge(
        %{
          code: "basic-monthly-#{System.unique_integer([:positive])}",
          name: %{"en" => "Basic", "ar" => "أساسي"},
          kind: :recurring,
          price: Decimal.new("180"),
          validity_unit: :month,
          validity_count: 1,
          cycle_unit: :month,
          cycle_count: 1,
          provider_product_ids: %{"fake" => "basic_monthly"},
          features: %{"reel_imports" => 15, "share_recipe" => true, "meal_plan" => true}
        },
        attrs
      )
    )
  end
end

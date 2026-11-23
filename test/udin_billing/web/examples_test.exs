defmodule UdinBilling.Web.ExamplesTest do
  @moduledoc """
  The examples in the dashboard's help texts come from each project's own catalog, so
  one project's words never show up in another.
  """
  use UdinBilling.DataCase, async: false

  alias UdinBilling.Web.Examples

  defp empty_catalog do
    for table <- ~w(billing_plan_features billing_plans billing_features),
        do: UdinBilling.TestRepo.delete_all(table)
  end

  defp feature!(key, en, ar),
    do:
      Ash.create!(Feature, %{key: key, kind: :counter, name: %{"en" => en, "ar" => ar}},
        authorize?: false
      )

  test "a project that sells reel imports sees reel imports" do
    empty_catalog()
    feature!("reel_imports", "Reel imports", "استيراد الريلز")

    plan_fixture(%{
      code: "pro",
      name: %{"en" => "Pro", "ar" => "برو"},
      price: Decimal.new(180),
      features: %{"reel_imports" => 40}
    })

    assert %{
             feature: "Reel imports",
             feature_key: "reel_imports",
             plan_name: "Pro",
             plan_code: "pro",
             price: "180",
             amount: 40,
             currency: "EGP"
           } = Examples.build("en")

    assert %{feature: "استيراد الريلز", plan_name: "برو"} = Examples.build("ar")
  end

  test "a project that sells rides sees rides, never reels" do
    empty_catalog()
    feature!("rides", "Ride credits", "رصيد الرحلات")

    plan_fixture(%{code: "weekly", price: Decimal.new(150), features: %{"rides" => 10}})

    examples = Examples.build("en")
    assert examples.feature == "Ride credits"
    assert examples.feature_key == "rides"
    assert examples.amount == 10
    refute inspect(examples) =~ "reel"
  end

  test "a project with no catalog yet sees neutral examples" do
    empty_catalog()

    assert %{feature: "units", feature_key: "units", plan_code: "standard", price: "100"} =
             Examples.build("en")

    assert Examples.build("ar").feature == "وحدات"
  end

  test "each project can set its own examples" do
    with_env(:dashboard_examples, %{feature: "tokens", price: "50"}, fn ->
      assert %{feature: "tokens", price: "50"} = Examples.build("en")
    end)
  end

  test "a malformed setting fails loudly" do
    with_env(:dashboard_examples, %{nope: "x"}, fn ->
      assert_raise ArgumentError, ~r/dashboard_examples/, fn -> Examples.build("en") end
    end)
  end
end

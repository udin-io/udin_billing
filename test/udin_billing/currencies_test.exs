defmodule UdinBilling.CurrenciesTest do
  @moduledoc """
  Plans can only use the currencies the app configures (`:currencies`, default: just
  `:default_currency`).
  """
  use UdinBilling.ConnCase

  alias UdinBilling.Config

  require Ash.Query

  defp plan_attrs(currency) do
    %{
      code: "c-#{System.unique_integer([:positive])}",
      name: %{"en" => "C", "ar" => "ج"},
      kind: :one_time,
      price: Decimal.new(10),
      currency: currency,
      validity_unit: :week,
      validity_count: 1
    }
  end

  test "without a list, the default currency is the only one" do
    assert Config.currencies() == ["EGP"]
    assert {:ok, _} = Ash.create(Plan, plan_attrs("EGP"), authorize?: false)
    assert {:error, error} = Ash.create(Plan, plan_attrs("USD"), authorize?: false)
    assert Exception.message(error) =~ "currency"
  end

  test "a configured list allows exactly those" do
    with_env(:currencies, ["EGP", "USD"], fn ->
      assert {:ok, _} = Ash.create(Plan, plan_attrs("USD"), authorize?: false)
      assert {:error, _} = Ash.create(Plan, plan_attrs("SAR"), authorize?: false)
    end)
  end

  test "a malformed list, or a default outside it, fails loudly" do
    with_env(:currencies, ["egp"], fn ->
      assert_raise ArgumentError, ~r/currencies/, fn -> Config.currencies() end
    end)

    with_env(:currencies, ["USD"], fn ->
      assert_raise ArgumentError, ~r/default_currency/, fn -> Config.default_currency() end
    end)
  end

  describe "the plan editor" do
    test "with one currency there's nothing to choose: no field, the plan gets it" do
      {:ok, view, _html} = live(admin_conn(), "/admin/billing/plans/new")
      refute has_element?(view, "#plan-currency")

      view
      |> form("#plan-form", plan: %{code: "one-cur", name: %{en: "W", ar: "و"}, price: "10"})
      |> render_submit()

      assert Plan
             |> Ash.Query.filter(code == "one-cur")
             |> Ash.read_one!(authorize?: false)
             |> Map.fetch!(:currency) == "EGP"
    end

    test "with several, a select offers exactly the configured ones" do
      with_env(:currencies, ["EGP", "USD"], fn ->
        {:ok, view, _html} = live(admin_conn(), "/admin/billing/plans/new")

        assert has_element?(view, "select#plan-currency option[value='EGP']")
        assert has_element?(view, "select#plan-currency option[value='USD']")
        refute has_element?(view, "select#plan-currency option[value='SAR']")
      end)
    end
  end
end

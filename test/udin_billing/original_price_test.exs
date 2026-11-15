defmodule UdinBilling.OriginalPriceTest do
  @moduledoc """
  A plan on sale shows its original price crossed out next to the price. Display only:
  buyers are always charged `price`.
  """
  use UdinBilling.DataCase, async: false

  test "is optional and must be higher than the price" do
    assert plan_fixture().original_price == nil
    assert plan_fixture(%{original_price: Decimal.new(200)}).original_price |> Decimal.equal?(200)

    for too_low <- [150, 100] do
      assert {:error, error} =
               Ash.create(
                 Plan,
                 %{
                   code: "sale-#{too_low}",
                   name: %{"en" => "Sale", "ar" => "تخفيض"},
                   kind: :one_time,
                   price: Decimal.new(150),
                   original_price: Decimal.new(too_low),
                   validity_unit: :week,
                   validity_count: 1
                 },
                 authorize?: false
               )

      assert Exception.message(error) =~ "original_price"
    end
  end

  test "travels in the catalog file" do
    plan_fixture(%{code: "weekly", price: Decimal.new(150), original_price: Decimal.new(200)})
    catalog = UdinBilling.Catalog.export()

    assert [%{"original_price" => "200"}] = catalog["plans"]
    {:ok, decoded} = UdinBilling.Catalog.decode(UdinBilling.Catalog.encode(catalog))
    assert [%{original_price: original}] = decoded.plans
    assert Decimal.equal?(original, 200)
  end
end

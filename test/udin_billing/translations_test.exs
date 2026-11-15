defmodule UdinBilling.TranslationsTest do
  use UdinBilling.DataCase, async: false

  alias UdinBilling.Translations

  # Test config: locales ["en", "ar"], "en" is the default.

  describe "get/2" do
    test "returns the requested language, then the default, then any text" do
      assert Translations.get(%{"en" => "Weekly", "ar" => "أسبوعي"}, "ar") == "أسبوعي"
      assert Translations.get(%{"en" => "Weekly", "ar" => " "}, "ar") == "Weekly"
      assert Translations.get(%{"ar" => "أسبوعي"}, "fr") == "أسبوعي"
      assert Translations.get(%{}, "en") == nil
      assert Translations.get(nil, "en") == nil
    end
  end

  describe "validate/2" do
    test "a required text needs every configured language" do
      assert :ok = Translations.validate(%{"en" => "Basic", "ar" => "أساسي"}, true)
      assert {:error, message} = Translations.validate(%{"en" => "Basic"}, true)
      assert message =~ "ar"
      assert {:error, _} = Translations.validate(%{"en" => "Basic", "ar" => "  "}, true)
      assert {:error, _} = Translations.validate(%{}, true)
    end

    test "an optional text may be empty but never half translated" do
      assert :ok = Translations.validate(%{}, false)
      assert :ok = Translations.validate(nil, false)
      assert :ok = Translations.validate(%{"en" => "", "ar" => ""}, false)
      assert {:error, message} = Translations.validate(%{"ar" => "وصف"}, false)
      assert message =~ "en"
    end

    test "languages the app doesn't configure are refused" do
      assert {:error, message} =
               Translations.validate(%{"en" => "a", "ar" => "b", "fr" => "c"}, true)

      assert message =~ "fr"
    end
  end

  describe "on records" do
    test "plan and feature names need English and Arabic; descriptions all or nothing" do
      assert {:error, error} =
               Ash.create(Plan, plan_attrs(%{name: %{"en" => "Plus"}}), authorize?: false)

      assert Exception.message(error) =~ "missing text for ar"

      assert {:error, _} =
               Ash.create(
                 Plan,
                 plan_attrs(%{description: %{"en" => "Best value"}}),
                 authorize?: false
               )

      assert {:ok, plan} =
               Ash.create(
                 Plan,
                 plan_attrs(%{description: %{"en" => "Best value", "ar" => "أفضل قيمة"}}),
                 authorize?: false
               )

      assert Plan.localized(plan, :name, "ar") == "بلس"

      assert {:error, _} =
               Ash.create(
                 Feature,
                 %{key: "household", kind: :switch, name: %{"en" => "Household"}},
                 authorize?: false
               )
    end
  end

  defp plan_attrs(attrs) do
    Map.merge(
      %{
        code: "plus-#{System.unique_integer([:positive])}",
        name: %{"en" => "Plus", "ar" => "بلس"},
        kind: :one_time,
        price: Decimal.new("100"),
        validity_unit: :month,
        validity_count: 1
      },
      attrs
    )
  end
end

defmodule UdinBilling.Web.ErrorTextTest do
  use UdinBilling.DataCase, async: false

  alias UdinBilling.Web.ErrorText

  @arabic ~r/[\x{0600}-\x{06FF}]/u

  test "known library messages are translated, with their values filled in" do
    assert ErrorText.translate("free plans must cost 0", "ar") =~ @arabic
    assert ErrorText.translate("free plans must cost 0", "en") == "free plans must cost 0"
    assert ErrorText.translate("currency must be one of EGP, USD", "ar") =~ "EGP, USD"
    assert ErrorText.translate("currency must be one of EGP, USD", "en") =~ "EGP, USD"

    message =
      "this plan has buyers, so price, cycle_unit can't change: " <>
        "create a new version and take this one off sale"

    assert ErrorText.translate(message, "ar") =~ "السعر"
    assert ErrorText.translate(message, "en") =~ "price, refill unit"
  end

  test "every message the library raises has an Arabic translation" do
    for message <- ErrorText.known_messages() do
      arabic = ErrorText.translate(message, "ar")
      assert arabic =~ @arabic, "no Arabic for #{inspect(message)}"
    end
  end

  test "a message it doesn't know is shown as it is" do
    assert ErrorText.translate("something new", "ar") == "something new"
  end

  test "messages joined for one field are translated one by one" do
    assert ErrorText.translate_all("is required, is invalid", "ar") =~ "، "
    assert ErrorText.translate_all("is required, is invalid", "en") == "is required, is invalid"
  end
end

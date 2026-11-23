defmodule UdinBilling.Web.TextTest do
  @moduledoc """
  The dashboard's words: buyer-facing periods in English and Arabic, and the guards that
  keep every translation complete, plain and free of any one project's vocabulary.
  """
  use UdinBilling.DataCase, async: false

  alias UdinBilling.Web.Text

  @gettext_dir Path.expand("../../../priv/gettext", __DIR__)

  test "built-in English and Arabic for what buyers see" do
    assert Text.validity(:day, 1, "en") == "valid 1 day"
    assert Text.validity(:day, 1, "ar") == "صالحة لمدة يوم واحد"
    assert Text.validity(:week, 2, "ar") == "صالحة لمدة أسبوعين"
    assert Text.validity(:week, 3, "ar") == "صالحة لمدة 3 أسابيع"
    assert Text.per(:month, 1, "en") == "/ month"
    assert Text.per(:month, 1, "ar") == "/ شهر"
    assert Text.per(:month, 3, "en") == "/ 3 months"
    assert Text.resets(:month, 1, "ar") == "يتجدد الرصيد كل شهر."
    assert Text.unlimited("ar") == "غير محدود"
    assert Text.never_expires("en") == "never expires"
    assert Text.free("ar") == "مجاني"
  end

  test "a language without translations shows English" do
    assert Text.validity(:day, 1, "fr") == "valid 1 day"
  end

  describe "Arabic number words" do
    test "follow Arabic grammar: one, two, 3 to 10, 11 to 99, then 100 and over" do
      for {unit, one, two, few, many, other} <- [
            {:day, "يوم واحد", "يومين", "3 أيام", "11 يومًا", "100 يوم"},
            {:week, "أسبوع واحد", "أسبوعين", "3 أسابيع", "11 أسبوعًا", "100 أسبوع"},
            {:month, "شهر واحد", "شهرين", "3 أشهر", "11 شهرًا", "100 شهر"},
            {:year, "سنة واحدة", "سنتين", "3 سنوات", "11 سنة", "100 سنة"}
          ] do
        assert Text.period(unit, 1, "ar") == one
        assert Text.period(unit, 2, "ar") == two
        assert Text.period(unit, 3, "ar") == few
        assert Text.period(unit, 10, "ar") == String.replace(few, "3", "10")
        assert Text.period(unit, 11, "ar") == many
        assert Text.period(unit, 99, "ar") == String.replace(many, "11", "99")
        assert Text.period(unit, 100, "ar") == other
        assert Text.period(unit, 102, "ar") == String.replace(other, "100", "102")
        assert Text.period(unit, 103, "ar") == String.replace(few, "3", "103")
      end
    end

    test "a repeat reads naturally" do
      assert Text.resets(:week, 2, "ar") == "يتجدد الرصيد كل أسبوعين."
      assert Text.per(:month, 2, "ar") == "/ شهرين"
    end

    test "English keeps one and many" do
      assert Text.period(:day, 2, "en") == "2 days"
      assert Text.period(:year, 1, "en") == "1 year"
    end
  end

  describe "every translation file" do
    test "has Arabic for every text, with the same placeholders" do
      for {file, message} <- arabic_messages() do
        for {msgid, msgstr} <- pairs(message) do
          assert String.trim(msgstr) != "", "#{file}: no Arabic for #{inspect(msgid)}"
          assert placeholders(msgstr) -- placeholders(msgid) == [], "#{file}: #{inspect(msgid)}"

          # A plural form may drop the count ("يوم واحد"), a single text may not drop anything.
          unless match?(%Expo.Message.Plural{}, message),
            do: assert(placeholders(msgid) == placeholders(msgstr), "#{file}: #{inspect(msgid)}")
        end
      end
    end

    test "Arabic is written in Arabic" do
      for {file, message} <- arabic_messages(), {msgid, msgstr} <- pairs(message) do
        letters = String.replace(msgstr, ~r/%\{\w+\}|[\d\s[:punct:]]/u, "")

        assert letters == "" or letters =~ ~r/[\x{0600}-\x{06FF}]/u or letters == msgid,
               "#{file}: #{inspect(msgid)} is not Arabic"
      end
    end

    test "is plain words: no dashes, no semicolons" do
      for {file, message} <- all_messages(), {msgid, msgstr} <- pairs(message) do
        for text <- [msgid, msgstr], banned <- ["—", "–", ";", " - ", "TODO"] do
          refute text =~ banned, "#{file}: #{inspect(text)} contains #{inspect(banned)}"
        end
      end
    end

    test "uses no one project's vocabulary: examples come from the project's own catalog" do
      words =
        ~r/\b(reel|reels|ride|rides|rider|riders|recipe|recipes|bundle|bundles)\b|ريل|رحل|وصف/iu

      for {file, message} <- all_messages(), {msgid, msgstr} <- pairs(message) do
        for text <- [msgid, msgstr] do
          refute text =~ words, "#{file}: #{inspect(text)} names a project's own words"
        end
      end
    end
  end

  # -- reading the .po files ----------------------------------------------------

  defp all_messages, do: po_files("**/*.po") ++ po_files("../default.pot")

  defp arabic_messages, do: po_files("ar/LC_MESSAGES/*.po")

  defp po_files(glob) do
    @gettext_dir
    |> Path.join(glob)
    |> Path.wildcard()
    |> Enum.flat_map(fn file ->
      for message <- Expo.PO.parse_file!(file).messages, do: {Path.basename(file), message}
    end)
  end

  defp pairs(%Expo.Message.Singular{msgid: id, msgstr: str}), do: [{text(id), text(str)}]

  defp pairs(%Expo.Message.Plural{msgid: id, msgid_plural: plural, msgstr: forms}),
    do: for({_n, str} <- forms, do: {text(id) <> " | " <> text(plural), text(str)})

  defp text(parts), do: parts |> List.wrap() |> IO.iodata_to_binary()

  defp placeholders(text), do: ~r/%\{(\w+)\}/ |> Regex.scan(text) |> Enum.uniq() |> Enum.sort()
end

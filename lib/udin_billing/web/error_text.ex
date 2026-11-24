defmodule UdinBilling.Web.ErrorText do
  @moduledoc """
  The library's validation and form messages in the admin's language.

  ## Why
  The messages come from resources and forms in English (`"free plans must cost 0"`), and
  they are also used outside the dashboard (an API, a console), so they stay English at
  the source. The dashboard translates them when it shows them to an admin.

  ## How it works
  Each message the library can raise has a rule: a pattern for its fixed words and the
  gettext call that renders it, with the parts that vary (a currency list, a plan code)
  filled in. A message with no rule is shown as it is. The texts are in the `errors`
  domain of `UdinBilling.Gettext`. `known_messages/0` lists one example of each rule so a
  test can check every one has an Arabic translation.
  """
  use Gettext, backend: UdinBilling.Gettext

  @doc "`message` in `locale`; unchanged when the library has no translation for it."
  @spec translate(String.t(), String.t()) :: String.t()
  def translate(message, locale) when is_binary(message) do
    Gettext.with_locale(UdinBilling.Gettext, locale, fn -> render(message) end)
  end

  @doc "Like `translate/2` for several messages joined with \", \" (one field, many problems)."
  @spec translate_all(String.t(), String.t()) :: String.t()
  def translate_all(text, locale) do
    case translate(text, locale) do
      ^text ->
        text |> String.split(", ") |> Enum.map_join(separator(locale), &translate(&1, locale))

      translated ->
        translated
    end
  end

  # Arabic separates a list with "،".
  defp separator("ar"), do: "، "
  defp separator(_locale), do: ", "

  @doc "One example message for each rule."
  @spec known_messages() :: [String.t()]
  def known_messages, do: Enum.map(rules(), fn {example, _pattern, _render} -> example end)

  defp render(message) do
    Enum.find_value(rules(), message, fn {_example, pattern, render} ->
      case Regex.named_captures(pattern, message) do
        nil -> nil
        captures -> render.(captures)
      end
    end)
  end

  defp rules do
    [
      {"currency must be one of EGP, USD", ~r/\Acurrency must be one of (?<list>.+)\z/,
       &dgettext("errors", "currency must be one of %{list}", list: &1["list"])},
      {"paymob product p1 is already used by plan pro",
       ~r/\A(?<provider>.+) product (?<id>.+) is already used by plan (?<code>.+)\z/,
       &dgettext("errors", "%{provider} product %{id} is already used by plan %{code}",
         provider: &1["provider"],
         id: &1["id"],
         code: &1["code"]
       )},
      {"not enough units left", ~r/\Anot enough units left\z/,
       fn _ -> dgettext("errors", "not enough units left") end},
      {"this plan has buyers, so price can't change: create a new version and take this one off sale",
       ~r/\Athis plan has buyers, so (?<terms>.+) can't change: create a new version and take this one off sale\z/,
       &dgettext(
         "errors",
         "this plan has buyers, so %{terms} can't change: create a new version and take this one off sale",
         terms: terms(&1["terms"])
       )},
      {"a plan still uses this feature. Remove it from plans first",
       ~r/\Aa plan still uses this feature\. Remove it from plans first\z/,
       fn _ ->
         dgettext("errors", "a plan still uses this feature. Remove it from plans first")
       end},
      {"the app's code uses this feature, so it can't be deleted",
       ~r/\Athe app's code uses this feature, so it can't be deleted\z/,
       fn _ -> dgettext("errors", "the app's code uses this feature, so it can't be deleted") end},
      {"must be higher than the price", ~r/\Amust be higher than the price\z/,
       fn _ -> dgettext("errors", "must be higher than the price") end},
      {"unknown feature, add it to the feature catalog first",
       ~r/\Aunknown feature, add it to the feature catalog first\z/,
       fn _ -> dgettext("errors", "unknown feature, add it to the feature catalog first") end},
      {"recurring plans are disabled, enabled: free, one_time",
       ~r/\A(?<kind>\S+) plans are disabled, enabled: (?<modes>.+)\z/,
       &dgettext("errors", "%{kind} plans are disabled, enabled: %{modes}",
         kind: &1["kind"],
         modes: &1["modes"]
       )},
      {"paid amount doesn't match the price", ~r/\Apaid amount doesn't match the price\z/,
       fn _ -> dgettext("errors", "paid amount doesn't match the price") end},
      {"user not found", ~r/\Auser not found\z/,
       fn _ -> dgettext("errors", "user not found") end},
      {"currency must be an uppercase ISO 4217 code, e.g. EGP",
       ~r/\Acurrency must be an uppercase ISO 4217 code, e\.g\. EGP\z/,
       fn _ -> dgettext("errors", "currency must be an uppercase ISO 4217 code, e.g. EGP") end},
      {"recurring plans need a billing period", ~r/\Arecurring plans need a billing period\z/,
       fn _ -> dgettext("errors", "recurring plans need a billing period") end},
      {"free plans must cost 0", ~r/\Afree plans must cost 0\z/,
       fn _ -> dgettext("errors", "free plans must cost 0") end},
      {"paid plans must have a price", ~r/\Apaid plans must have a price\z/,
       fn _ -> dgettext("errors", "paid plans must have a price") end},
      {"only a free plan can be the default", ~r/\Aonly a free plan can be the default\z/,
       fn _ -> dgettext("errors", "only a free plan can be the default") end},
      {"use lowercase letters, digits and underscores, starting with a letter",
       ~r/\Ause lowercase letters, digits and underscores, starting with a letter\z/,
       fn _ ->
         dgettext(
           "errors",
           "use lowercase letters, digits and underscores, starting with a letter"
         )
       end},
      {"the refill can't be longer than the billing period",
       ~r/\Athe refill can't be longer than the billing period\z/,
       fn _ -> dgettext("errors", "the refill can't be longer than the billing period") end},
      {"enter a whole number above 0", ~r/\Aenter a whole number above 0\z/,
       fn _ -> dgettext("errors", "enter a whole number above 0") end},
      {"missing text for ar, en", ~r/\Amissing text for (?<langs>.+)\z/,
       &dgettext("errors", "missing text for %{langs}", langs: &1["langs"])},
      {~s(unknown language "fr", configured: en, ar),
       ~r/\Aunknown language (?<lang>.+), configured: (?<langs>.+)\z/,
       &dgettext("errors", "unknown language %{lang}, configured: %{langs}",
         lang: &1["lang"],
         langs: &1["langs"]
       )},
      {"is required", ~r/\Ais required\z/, fn _ -> dgettext("errors", "is required") end},
      {"is invalid", ~r/\Ais invalid\z/, fn _ -> dgettext("errors", "is invalid") end},
      {"has already been taken", ~r/\Ahas already been taken\z/,
       fn _ -> dgettext("errors", "has already been taken") end},
      {"must be more than or equal to 0", ~r/\Amust be more than or equal to (?<min>.+)\z/,
       &dgettext("errors", "must be more than or equal to %{min}", min: &1["min"])},
      {"must be less than or equal to 10", ~r/\Amust be less than or equal to (?<max>.+)\z/,
       &dgettext("errors", "must be less than or equal to %{max}", max: &1["max"])}
    ]
  end

  # The names of the plan fields a sold plan can't change, in the admin's words.
  defp terms(list) do
    list |> String.split(", ") |> Enum.map_join(", ", &term/1)
  end

  defp term("kind"), do: dgettext("errors", "plan type")
  defp term("price"), do: dgettext("errors", "price")
  defp term("currency"), do: dgettext("errors", "currency")
  defp term("validity_unit"), do: dgettext("errors", "billing period unit")
  defp term("validity_count"), do: dgettext("errors", "billing period length")
  defp term("cycle_unit"), do: dgettext("errors", "refill unit")
  defp term("cycle_count"), do: dgettext("errors", "refill length")
  defp term(other), do: other
end

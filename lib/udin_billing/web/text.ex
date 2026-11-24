defmodule UdinBilling.Web.Text do
  @moduledoc """
  The words that describe a plan to its buyers: the plan preview and the cards the
  dashboard shows ("valid 1 week", "/ month", "Unlimited", "Free"), in the **preview
  language** you pick, which can differ from the dashboard's own language.

  ## Why a module and not plain gettext calls
  A plan card is shown in the buyer's language while the admin works in theirs. Every
  function here takes the language and runs inside `Gettext.with_locale/3`, so the page's
  own language is never touched. A language with no translation shows English.

  ## Numbers
  Periods use `ngettext`, so each language's plural rules apply: Arabic has one, two,
  3 to 10, 11 to 99 and 100 and over ("يوم واحد", "يومين", "3 أيام", "11 يومًا", "100 يوم").
  The translations are in `priv/gettext/<language>/LC_MESSAGES/default.po`.
  """
  use Gettext, backend: UdinBilling.Gettext

  @units [:day, :week, :month, :year]

  @doc "\"Free\" in `locale`."
  @spec free(String.t()) :: String.t()
  def free(locale), do: in_locale(locale, fn -> gettext("Free") end)

  @doc "\"Unlimited\" in `locale`."
  @spec unlimited(String.t()) :: String.t()
  def unlimited(locale), do: in_locale(locale, fn -> gettext("Unlimited") end)

  @doc "What a plan card shows while its price isn't set."
  @spec price_not_set(String.t()) :: String.t()
  def price_not_set(locale), do: in_locale(locale, fn -> gettext("Price not set") end)

  @doc "\"never expires\" in `locale`."
  @spec never_expires(String.t()) :: String.t()
  def never_expires(locale), do: in_locale(locale, fn -> gettext("never expires") end)

  @doc "What a plan card says when no feature is included yet."
  @spec nothing_included(String.t()) :: String.t()
  def nothing_included(locale), do: in_locale(locale, fn -> gettext("Nothing included yet.") end)

  @doc "What a plan card calls a plan that has no name yet."
  @spec untitled(String.t()) :: String.t()
  def untitled(locale), do: in_locale(locale, fn -> gettext("Untitled plan") end)

  @doc "How long a plan lasts: `\"valid 1 week\"`, `\"صالحة لمدة يوم واحد\"`."
  @spec validity(atom(), pos_integer(), String.t()) :: String.t()
  def validity(unit, count, locale) when unit in @units do
    in_locale(locale, fn -> gettext("valid %{period}", period: period_text(unit, count)) end)
  end

  @doc "How often a subscription renews, after the price: `\"/ month\"`, `\"/ 3 months\"`."
  @spec per(atom(), pos_integer(), String.t()) :: String.t()
  def per(unit, count, locale) when unit in @units do
    in_locale(locale, fn -> gettext("/ %{period}", period: every_text(unit, count)) end)
  end

  @doc "When counters refill: `\"Counters reset every month.\"`."
  @spec resets(atom(), pos_integer(), String.t()) :: String.t()
  def resets(unit, count, locale) when unit in @units do
    in_locale(locale, fn ->
      gettext("Counters reset every %{period}.", period: every_text(unit, count))
    end)
  end

  @doc "A length of time: `\"1 day\"`, `\"3 weeks\"`, `\"يوم واحد\"`."
  @spec period(atom(), pos_integer(), String.t()) :: String.t()
  def period(unit, count, locale) when unit in @units,
    do: in_locale(locale, fn -> period_text(unit, count) end)

  # "every month" / "every 3 months": the unit alone for 1, the length otherwise.
  defp every_text(unit, 1), do: unit_text(unit)
  defp every_text(unit, count), do: period_text(unit, count)

  defp unit_text(:day), do: pgettext("one unit of time", "day")
  defp unit_text(:week), do: pgettext("one unit of time", "week")
  defp unit_text(:month), do: pgettext("one unit of time", "month")
  defp unit_text(:year), do: pgettext("one unit of time", "year")

  defp period_text(:day, count), do: ngettext("%{count} day", "%{count} days", count)
  defp period_text(:week, count), do: ngettext("%{count} week", "%{count} weeks", count)
  defp period_text(:month, count), do: ngettext("%{count} month", "%{count} months", count)
  defp period_text(:year, count), do: ngettext("%{count} year", "%{count} years", count)

  defp in_locale(locale, fun), do: Gettext.with_locale(UdinBilling.Gettext, locale, fun)
end

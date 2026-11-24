defmodule UdinBilling.Translations do
  @moduledoc """
  Text in several languages, stored as a map of locale to text:
  `%{"en" => "Weekly", "ar" => "أسبوعي"}`.

  ## Why
  Every text a user sees (plan names and descriptions, feature names and descriptions, the
  item name on the payment page) is shown in the user's language. Each app lists its
  languages in `config :udin_billing, :locales` (e.g. `["en", "ar"]`; the first is the
  default). The admin dashboard shows one field per configured language.

  ## Rules
  - Required texts (names) need every configured language, so no user ever sees a
    missing or wrong-language name.
  - Optional texts (descriptions) may be left empty, but if any language is filled, all
    must be: a half-translated screen is rejected at save time.
  - `get/2` still falls back (default language, then any) for rows saved before a
    language was added to the config.
  """
  alias UdinBilling.Config

  @type t :: %{String.t() => String.t()}

  @doc """
  The text for `locale`, falling back to the default locale, then to any translation.
  Nil when there's no text at all.
  """
  @spec get(t() | nil, String.t() | nil) :: String.t() | nil
  def get(nil, _locale), do: nil

  def get(translations, locale) do
    present(translations[locale]) || present(translations[Config.default_locale()]) ||
      Enum.find_value(translations, fn {_locale, text} -> present(text) end)
  end

  @doc """
  Checks `translations` for a record field: only configured languages; every configured
  language when `required?` or when any text is given. Returns `:ok` or
  `{:error, message}`.
  """
  @spec validate(t() | nil, boolean()) :: :ok | {:error, String.t()}
  def validate(translations, required?) do
    translations = translations || %{}
    locales = Config.locales()

    cond do
      unknown = Enum.find(Map.keys(translations), &(&1 not in locales)) ->
        {:error, "unknown language #{inspect(unknown)}, configured: #{Enum.join(locales, ", ")}"}

      not required? and filled(translations) == [] ->
        :ok

      (missing = locales -- filled(translations)) != [] ->
        {:error, "missing text for #{Enum.join(missing, ", ")}"}

      true ->
        :ok
    end
  end

  @doc "The configured languages that are missing from `translations` (empty text counts as missing)."
  @spec missing(t() | nil) :: [String.t()]
  def missing(translations), do: Config.locales() -- filled(translations || %{})

  defp filled(translations), do: for({locale, text} <- translations, present(text), do: locale)

  defp present(text) when is_binary(text) do
    if String.trim(text) == "", do: nil, else: text
  end

  defp present(_text), do: nil
end

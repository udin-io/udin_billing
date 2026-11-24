defmodule UdinBilling.Web.Fields do
  @moduledoc """
  Parses raw form values (strings from the browser) for the dashboard's forms
  (`UdinBilling.Web.PlanForm`, `UdinBilling.Web.FeatureForm`).

  ## Why
  Both forms take translated texts, numbers and trimmed strings, and must report a
  missing language on its own field (`"name.ar"`) so the editor can mark that exact input.
  Parsing lives here once instead of in each form.

  Errors accumulate in a `{attrs, errors}` pair, so a form reports every problem at once.
  """
  alias UdinBilling.{Config, Translations}

  @type acc :: {map(), %{String.t() => String.t()}}

  @doc "Languages shown as separate fields (`config :udin_billing, :locales`)."
  @spec locales() :: [String.t()]
  def locales, do: Config.locales()

  @doc "An empty text per configured language: `%{\"en\" => \"\", \"ar\" => \"\"}`."
  @spec blank_translations() :: %{String.t() => String.t()}
  def blank_translations, do: Map.new(locales(), &{&1, ""})

  @doc "Stored translations as form values, with every configured language present."
  @spec translation_params(map() | nil) :: %{String.t() => String.t()}
  def translation_params(stored), do: Map.merge(blank_translations(), stored || %{})

  @doc """
  Puts translated text `key` from `submitted` (`%{"en" => ..., "ar" => ...}`). Required
  texts need every language; optional ones every language or none. Each missing language
  is an error on `"<key>.<locale>"`.
  """
  @spec put_translations(acc(), atom(), term(), boolean()) :: acc()
  def put_translations({attrs, errors}, key, submitted, required?) do
    texts = translations(submitted)
    missing = Translations.missing(texts)

    if missing == [] or (not required? and texts == %{}) do
      {Map.put(attrs, key, texts), errors}
    else
      message = if required?, do: "required", else: "fill every language or leave all empty"
      {attrs, Enum.reduce(missing, errors, &Map.put(&2, "#{key}.#{&1}", message))}
    end
  end

  @doc """
  Puts `value` under `key`, or, when it's nil (couldn't be parsed), `message` under
  `field` in the errors.
  """
  @spec put_required(acc(), atom(), term(), String.t(), String.t()) :: acc()
  def put_required({attrs, errors}, _key, nil, field, message),
    do: {attrs, Map.put(errors, field, message)}

  def put_required({attrs, errors}, key, value, _field, _message),
    do: {Map.put(attrs, key, value), errors}

  @doc "Puts `value` under `key` unconditionally."
  @spec put(acc(), atom(), term()) :: acc()
  def put({attrs, errors}, key, value), do: {Map.put(attrs, key, value), errors}

  @doc "Trimmed text, nil when blank."
  @spec text(term()) :: String.t() | nil
  def text(nil), do: nil

  def text(value) do
    case value |> to_string() |> String.trim() do
      "" -> nil
      trimmed -> trimmed
    end
  end

  @doc "A whole number from text, nil when it isn't one."
  @spec integer(term()) :: integer() | nil
  def integer(value) do
    with text when is_binary(text) <- text(value),
         {number, ""} <- Integer.parse(text) do
      number
    else
      _ -> nil
    end
  end

  @doc "A non-negative decimal from text, nil when it isn't one."
  @spec decimal(term()) :: Decimal.t() | nil
  def decimal(value) do
    with text when is_binary(text) <- text(value),
         {decimal, ""} <- Decimal.parse(text),
         false <- Decimal.negative?(decimal) do
      decimal
    else
      _ -> nil
    end
  end

  @doc "`\"true\"` → true, anything else → false (switch inputs post \"true\"/\"false\")."
  @spec checked?(term()) :: boolean()
  def checked?(value), do: value == "true"

  defp translations(submitted) when is_map(submitted) do
    for {locale, value} <- submitted,
        locale in locales(),
        text = text(value),
        text != nil,
        into: %{},
        do: {locale, text}
  end

  defp translations(_submitted), do: %{}
end

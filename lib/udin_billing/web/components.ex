if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule UdinBilling.Web.Components do
    @moduledoc """
    The billing dashboard's building blocks: page shell, buttons, inputs, badges, cards.

    ## Why its own components and styles
    The dashboard is mounted inside different apps, each with its own CSS. It ships its own small, scoped stylesheet (every class starts with `ub-`) so it
    looks the same everywhere and never clashes with the host's styles. Light and dark
    themes follow the system setting.
    """
    use Phoenix.Component
    use Gettext, backend: UdinBilling.Gettext

    alias Phoenix.LiveView.JS

    # {key, path, shown when}: :always, or :dev_tools for the developer pages.
    @nav [
      {:plans, "", :always},
      {:features, "/features", :dev_tools},
      {:users, "/users", :always},
      {:payments, "/payments", :always},
      {:webhooks, "/webhooks", :dev_tools},
      {:catalog, "/catalog", :dev_tools}
    ]

    defp nav_label(:plans), do: gettext("Plans")
    defp nav_label(:features), do: gettext("Features")
    defp nav_label(:users), do: gettext("Users")
    defp nav_label(:payments), do: gettext("Payments")
    defp nav_label(:webhooks), do: gettext("Webhooks")
    defp nav_label(:catalog), do: gettext("Catalog")

    attr :base, :string, required: true, doc: "The dashboard's mount path"
    attr :active, :atom, required: true
    attr :title, :string, required: true
    attr :flash, :map, default: %{}
    attr :dev_tools, :boolean, required: true, doc: "Show the developer pages' tabs"
    attr :lang, :string, default: nil, doc: "The dashboard's language (`@ub_lang`)"

    attr :current, :map,
      default: %{path: nil, query: %{}},
      doc: "The current path and query (`@ub_current`), kept by the language switch"

    slot :actions
    slot :inner_block, required: true

    @doc "The page shell: header, navigation, language switch, flash and content."
    def shell(assigns) do
      lang = assigns.lang || UdinBilling.Config.default_locale()

      assigns =
        assigns
        |> assign(:lang, lang)
        |> assign(
          :nav,
          for(
            {key, path, shown_when} <- @nav,
            shown?(shown_when, assigns),
            do: {key, path}
          )
        )
        |> assign(:languages, UdinBilling.Config.locales())

      ~H"""
      <%!-- The dashboard sets its own direction from its language (right to left for Arabic),
           whatever the host page uses. The stylesheet never forces a direction, and uses
           start and end instead of left and right, so it mirrors as a whole. --%>
      <div class="ub" dir={dir(@lang)} lang={@lang}>
        <.styles />
        <header class="ub-top">
          <div class="ub-brand">{gettext("Billing")}</div>
          <nav class="ub-nav" aria-label={gettext("Billing sections")}>
            <.link
              :for={{key, path} <- @nav}
              navigate={href(@lang, @base, path)}
              class={["ub-nav-link", key == @active && "is-active"]}
              aria-current={key == @active && "page"}
            >
              {nav_label(key)}
            </.link>
          </nav>
          <div
            :if={length(@languages) > 1}
            id="ub-lang-switch"
            class="ub-seg"
            role="group"
            aria-label={gettext("Language")}
          >
            <%!-- A full page load, not a patch: texts are translated when a page is mounted,
                 so a new language needs a fresh page. --%>
            <.link
              :for={locale <- @languages}
              href={switch_path(@current, @base, locale)}
              class={["ub-seg-link", locale == @lang && "is-active"]}
              aria-current={locale == @lang && "true"}
              lang={locale}
            >
              {native_name(locale)}
            </.link>
          </div>
        </header>
        <main class="ub-main">
          <div class="ub-page-head">
            <h1 class="ub-h1">{@title}</h1>
            <div class="ub-actions">{render_slot(@actions)}</div>
          </div>
          <.flash_messages flash={@flash} />
          {render_slot(@inner_block)}
        </main>
      </div>
      """
    end

    @doc """
    A link inside the dashboard that keeps the admin's language: `path` (which may carry a
    query) under `base`, with `lang=` added. It is always added, because an admin whose own
    language isn't the app's default would otherwise be sent back to it.
    """
    @spec href(String.t() | nil, String.t(), String.t()) :: String.t()
    def href(lang, base, path) do
      lang = lang || UdinBilling.Config.default_locale()
      base <> path <> if(String.contains?(path, "?"), do: "&", else: "?") <> "lang=" <> lang
    end

    # The page you are on, in another language: same path and query, other `lang`.
    defp switch_path(%{path: path, query: query}, base, locale) do
      (path || base) <> "?" <> URI.encode_query(Map.put(query, "lang", locale))
    end

    defp shown?(:always, _assigns), do: true
    defp shown?(:dev_tools, assigns), do: assigns.dev_tools

    attr :flash, :map, required: true

    defp flash_messages(assigns) do
      ~H"""
      <div :for={{kind, message} <- @flash} class={"ub-flash ub-flash-#{kind}"} role="status">
        {message}
      </div>
      """
    end

    attr :variant, :string, default: "secondary", values: ~w(primary secondary danger ghost)
    attr :type, :string, default: "button"
    attr :rest, :global, include: ~w(disabled form name value navigate patch href)
    slot :inner_block, required: true

    @doc "A button. With `navigate`/`patch`/`href` it renders as a link styled as a button."
    def button(%{rest: %{navigate: _}} = assigns), do: link_button(assigns)
    def button(%{rest: %{patch: _}} = assigns), do: link_button(assigns)
    def button(%{rest: %{href: _}} = assigns), do: link_button(assigns)

    def button(assigns) do
      ~H"""
      <button type={@type} class={"ub-btn ub-btn-#{@variant}"} {@rest}>
        {render_slot(@inner_block)}
      </button>
      """
    end

    defp link_button(assigns) do
      ~H"""
      <.link class={"ub-btn ub-btn-#{@variant}"} {@rest}>{render_slot(@inner_block)}</.link>
      """
    end

    attr :id, :string, required: true
    attr :name, :string, required: true
    attr :label, :string, default: nil
    attr :value, :any, default: nil
    attr :type, :string, default: "text"
    attr :error, :string, default: nil
    attr :hint, :string, default: nil
    attr :options, :list, default: [], doc: "For type=select: `[{label, value}]`"
    attr :dir, :string, default: nil, doc: "Text direction, e.g. \"rtl\" for Arabic"

    attr :rest, :global,
      include:
        ~w(placeholder min max step required autocomplete disabled lang inputmode readonly rows spellcheck)

    @doc "A labelled input, select or textarea with its error and hint."
    def input(assigns) do
      ~H"""
      <div class={["ub-field", @error && "has-error"]}>
        <label :if={@label} for={@id} class="ub-label">{@label}</label>
        <select :if={@type == "select"} id={@id} name={@name} class="ub-input" {@rest}>
          <option
            :for={{label, value} <- @options}
            value={value}
            selected={to_string(value) == to_string(@value)}
          >
            {label}
          </option>
        </select>
        <textarea
          :if={@type == "textarea"}
          id={@id}
          name={@name}
          class="ub-input ub-textarea"
          dir={@dir}
          {@rest}
        >{@value}</textarea>
        <input
          :if={@type not in ["select", "textarea"]}
          id={@id}
          name={@name}
          type={@type}
          value={@value}
          class="ub-input"
          dir={@dir}
          {@rest}
        />
        <p :if={@hint && !@error} class="ub-hint">{@hint}</p>
        <p :if={@error} class="ub-error" role="alert">{@error}</p>
      </div>
      """
    end

    attr :id, :string, required: true
    attr :name, :string, required: true
    attr :checked, :boolean, default: false
    attr :label, :string, required: true
    attr :value_on, :string, default: "true"
    attr :value_off, :string, default: "false"
    attr :rest, :global, include: ~w(disabled)

    @doc "An on/off switch posting `value_on` / `value_off` (default \"true\" / \"false\")."
    def toggle(assigns) do
      ~H"""
      <label class="ub-toggle" for={@id}>
        <%!-- A disabled checkbox isn't submitted: the hidden input then carries the current value. --%>
        <input
          type="hidden"
          name={@name}
          value={hidden_value(@rest[:disabled], @checked, @value_on, @value_off)}
        />
        <input
          type="checkbox"
          id={@id}
          name={@name}
          value={@value_on}
          checked={@checked}
          role="switch"
          {@rest}
        />
        <span class="ub-toggle-track" aria-hidden="true"><span class="ub-toggle-thumb"></span></span>
        <span class="ub-toggle-label">{@label}</span>
      </label>
      """
    end

    attr :id, :string, required: true
    attr :name, :string, required: true
    attr :value, :string, default: nil
    attr :options, :list, required: true, doc: "`[{value, title, explanation}]`"

    @doc "A set of radio choices, each with a title and a plain-language explanation."
    def choice_cards(assigns) do
      ~H"""
      <div class="ub-choices" role="radiogroup" style="grid-column: 1 / -1">
        <label :for={{value, title, explanation} <- @options} class="ub-choice" for={"#{@id}-#{value}"}>
          <input
            type="radio"
            id={"#{@id}-#{value}"}
            name={@name}
            value={value}
            checked={value == @value}
          />
          <span class="ub-choice-text">
            <span class="ub-choice-title">{title}</span>
            <span class="ub-hint">{explanation}</span>
          </span>
        </label>
      </div>
      """
    end

    defp hidden_value(true, true, value_on, _value_off), do: value_on
    defp hidden_value(_disabled, _checked, _value_on, value_off), do: value_off

    attr :tone, :string, default: "neutral", values: ~w(neutral good warn bad accent)
    slot :inner_block, required: true

    @doc "A small status or category label."
    def badge(assigns) do
      ~H"""
      <span class={"ub-badge ub-badge-#{@tone}"}>{render_slot(@inner_block)}</span>
      """
    end

    attr :class, :any, default: nil
    attr :rest, :global
    slot :inner_block, required: true

    @doc "A bordered panel."
    def card(assigns) do
      ~H"""
      <section class={["ub-card", @class]} {@rest}>{render_slot(@inner_block)}</section>
      """
    end

    attr :title, :string, required: true
    attr :hint, :string, default: nil
    slot :inner_block, required: true

    @doc "A titled group of form fields."
    def fieldset(assigns) do
      ~H"""
      <fieldset class="ub-fieldset">
        <legend class="ub-legend">{@title}</legend>
        <p :if={@hint} class="ub-hint">{@hint}</p>
        <div class="ub-fieldset-body">{render_slot(@inner_block)}</div>
      </fieldset>
      """
    end

    attr :message, :string, required: true
    slot :action

    @doc "An empty state with an optional call to action."
    def empty(assigns) do
      ~H"""
      <div class="ub-empty">
        <p>{@message}</p>
        {render_slot(@action)}
      </div>
      """
    end

    @doc "Hides an element by id (no hook needed)."
    def hide(id), do: JS.hide(to: "##{id}")

    @doc "The text direction for a locale's inputs."
    @spec dir(String.t()) :: String.t()
    def dir(locale) when locale in ~w(ar fa he ur), do: "rtl"
    def dir(_locale), do: "ltr"

    @doc "A language's own name, for the dashboard's language switch."
    @spec native_name(String.t()) :: String.t()
    def native_name("en"), do: "English"
    def native_name("ar"), do: "العربية"
    def native_name("fr"), do: "Français"
    def native_name(locale), do: String.upcase(locale)

    @doc "A language label for a locale code."
    @spec language(String.t()) :: String.t()
    def language("en"), do: "English"
    def language("ar"), do: "العربية (Arabic)"
    def language("fr"), do: "Français (French)"
    def language(locale), do: String.upcase(locale)

    @doc "A plan's price as buyers see it, in `locale` (\"Free\" for the free plan)."
    @spec buyer_price(map(), String.t()) :: String.t()
    def buyer_price(%{kind: :free}, locale), do: UdinBilling.Web.Text.free(locale)

    def buyer_price(%{price: %Decimal{} = price, currency: currency}, _locale)
        when is_binary(currency),
        do: money(price, currency)

    def buyer_price(_attrs, locale), do: UdinBilling.Web.Text.price_not_set(locale)

    @doc "A plan's original price before a sale (`\"200 EGP\"`), or nil when it isn't on sale."
    @spec buyer_original_price(map()) :: String.t() | nil
    def buyer_original_price(%{original_price: %Decimal{} = original, currency: currency})
        when is_binary(currency),
        do: money(original, currency)

    def buyer_original_price(_attrs), do: nil

    @doc """
    A plan's period as buyers see it, in `locale`: `"/ month"` for a subscription,
    `"· valid 1 week"` or `"· never expires"` otherwise; empty while the form is incomplete.
    """
    @spec buyer_period(map(), String.t()) :: String.t()
    def buyer_period(attrs, locale) do
      case {Map.get(attrs, :kind), Map.get(attrs, :validity_unit),
            Map.get(attrs, :validity_count)} do
        {:recurring, unit, count} when not is_nil(unit) ->
          UdinBilling.Web.Text.per(unit, count, locale)

        {_kind, nil, _count} ->
          "· " <> UdinBilling.Web.Text.never_expires(locale)

        {_kind, unit, count} when is_integer(count) ->
          "· " <> UdinBilling.Web.Text.validity(unit, count, locale)

        _incomplete ->
          ""
      end
    end

    @doc "`350 EGP`; whole amounts without decimals."
    @spec money(Decimal.t(), String.t()) :: String.t()
    def money(amount, currency) do
      amount = if Decimal.integer?(amount), do: Decimal.round(amount), else: amount
      "#{Decimal.to_string(amount, :normal)} #{currency}"
    end

    attr :locale, :string, default: "en", doc: "Language of the \"Unlimited\" label"

    attr :value, :any,
      required: true,
      doc: "true, a count, \"unlimited\", or nil/false/0 (not included)"

    @doc "A feature value in tables: ✓, a count, ∞ Unlimited, or ✕ when not included."
    def feature_value(assigns) do
      ~H"""
      <span :if={@value == true} class="ub-check" aria-label={gettext("Included")}>✓</span>
      <span :if={@value == "unlimited"} class="ub-check">
        ∞ {UdinBilling.Web.Text.unlimited(@locale)}
      </span>
      <span :if={is_integer(@value) and @value > 0}>{@value}</span>
      <span :if={@value in [nil, false, 0]} class="ub-cross" aria-label={gettext("Not included")}>
        ✕
      </span>
      """
    end

    attr :texts, :map, required: true, doc: "Stored translations"

    @doc "Every configured language's text of a field, each in its own direction; missing ones flagged."
    def translated(assigns) do
      assigns = assign(assigns, :locales, UdinBilling.Config.locales())

      ~H"""
      <div class="ub-stack ub-gap-2">
        <div :for={locale <- @locales} class="ub-translated">
          <span class="ub-locale">{locale}</span>
          <span :if={present?(@texts[locale])} dir={dir(locale)} lang={locale}>{@texts[locale]}</span>
          <.badge :if={!present?(@texts[locale])} tone="warn">{gettext("missing")}</.badge>
        </div>
      </div>
      """
    end

    attr :field, :atom, required: true, doc: ":name or :description"
    attr :form, :string, required: true, doc: "Form param prefix, e.g. \"plan\""
    attr :values, :map, required: true, doc: "Current texts per language"
    attr :errors, :map, required: true
    attr :label, :string, required: true
    attr :required, :boolean, default: false
    attr :multiline, :boolean, default: false

    @doc """
    One input per configured language for a text users see (e.g. a plan's name in English
    and Arabic), each in the language's direction, with its own error.
    """
    def translations_input(assigns) do
      assigns = assign(assigns, :locales, UdinBilling.Config.locales())

      ~H"""
      <div class="ub-locales">
        <.input
          :for={locale <- @locales}
          id={"#{@form}-#{@field}-#{locale}"}
          name={"#{@form}[#{@field}][#{locale}]"}
          type={if @multiline, do: "textarea", else: "text"}
          label={"#{@label} · #{language(locale)}"}
          value={@values[locale]}
          error={@errors["#{@field}.#{locale}"]}
          dir={dir(locale)}
          lang={locale}
          hint={
            if @required,
              do: gettext("Required"),
              else: gettext("Optional. Fill every language or none.")
          }
        />
      </div>
      """
    end

    @doc "Field-keyed messages from an Ash error, for showing next to inputs (`\"base\"` for the rest)."
    @spec error_messages(term()) :: %{String.t() => String.t()}
    def error_messages(%{errors: errors}) when is_list(errors) do
      Enum.reduce(errors, %{}, fn error, acc ->
        key = error |> Map.get(:field) |> then(&if(&1, do: to_string(&1), else: "base"))
        Map.update(acc, key, message(error), &(&1 <> ", " <> message(error)))
      end)
    end

    def error_messages(error), do: %{"base" => message(error)}

    @doc "Like `error_messages/1`, with each message in `lang` (see `UdinBilling.Web.ErrorText`)."
    @spec error_messages(term(), String.t() | nil) :: %{String.t() => String.t()}
    def error_messages(error, lang) do
      lang = lang || UdinBilling.Config.default_locale()

      error
      |> error_messages()
      |> Map.new(fn {field, text} ->
        {field, UdinBilling.Web.ErrorText.translate_all(text, lang)}
      end)
    end

    defp message(%{message: message, vars: vars}) when is_binary(message) do
      Enum.reduce(vars || [], message, fn {key, value}, text ->
        String.replace(text, "%{#{key}}", var_text(value))
      end)
    end

    defp message(error) when is_exception(error), do: Exception.message(error)
    defp message(error), do: inspect(error)

    defp var_text(value) when is_binary(value) or is_number(value) or is_atom(value),
      do: to_string(value)

    defp var_text(value), do: inspect(value)

    defp present?(text), do: is_binary(text) and String.trim(text) != ""

    defp styles(assigns) do
      ~H"""
      <style>
        .ub { --ub-bg: #f6f7f9; --ub-surface: #ffffff; --ub-ink: #16191f; --ub-muted: #5d6573;
          --ub-line: #dfe3ea; --ub-accent: #1f5fd6; --ub-accent-ink: #ffffff; --ub-accent-soft: #e8effc;
          --ub-good: #127a43; --ub-good-soft: #e3f4ea; --ub-warn: #8a5a00; --ub-warn-soft: #fbf1dc;
          --ub-bad: #b42318; --ub-bad-soft: #fde8e6; --ub-radius: 10px;
          font-family: ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, "Noto Sans Arabic", sans-serif;
          font-size: 14px; line-height: 1.5; color: var(--ub-ink); background: var(--ub-bg); min-height: 100vh; }
        /* Dark: the OS setting, unless the host app chose a theme with data-theme (Phoenix 1.8 / daisyUI). */
        @media (prefers-color-scheme: dark) {
          :root:not([data-theme="light"]) .ub { --ub-bg: #0f1216; --ub-surface: #171b21; --ub-ink: #e7eaf0; --ub-muted: #9aa3b2;
            --ub-line: #2a303a; --ub-accent: #6d9eff; --ub-accent-ink: #0b1220; --ub-accent-soft: #1b2740;
            --ub-good: #5cc98b; --ub-good-soft: #13281d; --ub-warn: #e3b25c; --ub-warn-soft: #2b2312;
            --ub-bad: #ff8a80; --ub-bad-soft: #2f1716; color-scheme: dark; }
        }
        [data-theme="dark"] .ub { --ub-bg: #0f1216; --ub-surface: #171b21; --ub-ink: #e7eaf0; --ub-muted: #9aa3b2;
            --ub-line: #2a303a; --ub-accent: #6d9eff; --ub-accent-ink: #0b1220; --ub-accent-soft: #1b2740;
            --ub-good: #5cc98b; --ub-good-soft: #13281d; --ub-warn: #e3b25c; --ub-warn-soft: #2b2312;
            --ub-bad: #ff8a80; --ub-bad-soft: #2f1716; color-scheme: dark; }
        .ub *, .ub *::before, .ub *::after { box-sizing: border-box; }
        .ub-top { display: flex; align-items: center; gap: 24px; padding: 12px 24px; background: var(--ub-surface);
          border-bottom: 1px solid var(--ub-line); position: sticky; top: 0; z-index: 2; flex-wrap: wrap; }
        .ub-brand { font-weight: 700; font-size: 15px; }
        .ub-nav { display: flex; gap: 4px; flex-wrap: wrap; }
        .ub-nav-link { padding: 6px 12px; border-radius: 8px; color: var(--ub-muted); text-decoration: none; font-weight: 500; }
        .ub-nav-link:hover { background: var(--ub-bg); color: var(--ub-ink); }
        .ub-nav-link.is-active { background: var(--ub-accent-soft); color: var(--ub-accent); }
        .ub-main { max-width: 1200px; margin: 0 auto; padding: 24px; display: flex; flex-direction: column; gap: 20px; }
        .ub-page-head { display: flex; align-items: center; justify-content: space-between; gap: 16px; flex-wrap: wrap; }
        .ub-h1 { font-size: 22px; font-weight: 700; margin: 0; }
        .ub-h2 { font-size: 16px; font-weight: 650; margin: 0; }
        .ub-actions { display: flex; gap: 8px; flex-wrap: wrap; }
        .ub-muted { color: var(--ub-muted); }
        .ub-small { font-size: 12.5px; }
        .ub-mono { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; font-size: 12.5px; }
        .ub-card { background: var(--ub-surface); border: 1px solid var(--ub-line); border-radius: var(--ub-radius); padding: 18px; }
        .ub-grid { display: grid; gap: 16px; grid-template-columns: repeat(auto-fill, minmax(290px, 1fr)); }
        .ub-row { display: flex; gap: 12px; align-items: center; flex-wrap: wrap; }
        .ub-stack { display: flex; flex-direction: column; gap: 12px; }
        .ub-split { display: grid; gap: 20px; grid-template-columns: minmax(0, 1fr) 320px; align-items: start; }
        @media (max-width: 900px) { .ub-split { grid-template-columns: 1fr; } }
        .ub-sticky { position: sticky; top: 72px; }
        .ub-btn { display: inline-flex; align-items: center; gap: 6px; padding: 8px 14px; border-radius: 8px;
          border: 1px solid var(--ub-line); background: var(--ub-surface); color: var(--ub-ink); font: inherit;
          font-weight: 600; cursor: pointer; text-decoration: none; line-height: 1.2; }
        .ub-btn:hover { border-color: var(--ub-muted); }
        .ub-btn:focus-visible, .ub-input:focus-visible, .ub-nav-link:focus-visible, .ub-toggle input:focus-visible + .ub-toggle-track {
          outline: 2px solid var(--ub-accent); outline-offset: 2px; }
        .ub-btn[disabled] { opacity: .5; cursor: not-allowed; }
        .ub-btn-primary { background: var(--ub-accent); border-color: var(--ub-accent); color: var(--ub-accent-ink); }
        .ub-btn-danger { color: var(--ub-bad); }
        .ub-btn-ghost { border-color: transparent; background: transparent; color: var(--ub-muted); padding-inline: 8px; }
        .ub-btn-ghost:hover { color: var(--ub-ink); border-color: transparent; background: var(--ub-bg); }
        .ub-field { display: flex; flex-direction: column; gap: 4px; min-width: 0; }
        .ub-label { font-weight: 600; font-size: 13px; }
        .ub-input { font: inherit; padding: 8px 10px; border-radius: 8px; border: 1px solid var(--ub-line);
          background: var(--ub-surface); color: var(--ub-ink); width: 100%; }
        .ub-input[readonly], .ub-input:disabled { background: var(--ub-bg); color: var(--ub-muted); cursor: not-allowed; }
        .ub-seg label:has(input:disabled), .ub-toggle:has(input:disabled) { opacity: .6; cursor: not-allowed; }
        .ub-sr-only { position: absolute; width: 1px; height: 1px; padding: 0; margin: -1px; overflow: hidden; clip: rect(0, 0, 0, 0); white-space: nowrap; border: 0; }
        .ub-textarea { min-height: 72px; resize: vertical; }
        .has-error .ub-input { border-color: var(--ub-bad); }
        .ub-hint { margin: 0; color: var(--ub-muted); font-size: 12.5px; }
        .ub-error { margin: 0; color: var(--ub-bad); font-size: 12.5px; font-weight: 600; }
        .ub-fieldset { border: 1px solid var(--ub-line); border-radius: var(--ub-radius); padding: 16px; margin: 0;
          background: var(--ub-surface); min-width: 0; }
        .ub-legend { font-weight: 700; padding: 0 6px; }
        .ub-fieldset-body { display: grid; gap: 12px; grid-template-columns: repeat(auto-fill, minmax(200px, 1fr)); margin-top: 8px; }
        .ub-fieldset-body.is-wide { grid-template-columns: 1fr; }
        .ub-toggle { display: inline-flex; align-items: center; gap: 10px; cursor: pointer; }
        .ub-toggle input[type=checkbox] { position: absolute; opacity: 0; width: 1px; height: 1px; }
        .ub-toggle-track { width: 38px; height: 22px; border-radius: 99px; background: var(--ub-line); position: relative; flex: none; transition: background .15s; }
        .ub-toggle-thumb { position: absolute; top: 3px; inset-inline-start: 3px; width: 16px; height: 16px; border-radius: 50%; background: #fff; transition: transform .15s; }
        .ub-toggle input:checked + .ub-toggle-track { background: var(--ub-accent); }
        .ub-toggle input:checked + .ub-toggle-track .ub-toggle-thumb { transform: translateX(16px); }
        .ub[dir=rtl] .ub-toggle input:checked + .ub-toggle-track .ub-toggle-thumb { transform: translateX(-16px); }
        @media (prefers-reduced-motion: reduce) { .ub-toggle-track, .ub-toggle-thumb { transition: none; } }
        .ub-badge { display: inline-block; padding: 2px 8px; border-radius: 99px; font-size: 12px; font-weight: 600; white-space: nowrap; }
        .ub-badge-neutral { background: var(--ub-bg); color: var(--ub-muted); border: 1px solid var(--ub-line); }
        .ub-badge-good { background: var(--ub-good-soft); color: var(--ub-good); }
        .ub-badge-warn { background: var(--ub-warn-soft); color: var(--ub-warn); }
        .ub-badge-bad { background: var(--ub-bad-soft); color: var(--ub-bad); }
        .ub-badge-accent { background: var(--ub-accent-soft); color: var(--ub-accent); }
        .ub-flash { padding: 10px 14px; border-radius: 8px; font-weight: 600; }
        .ub-flash-info { background: var(--ub-good-soft); color: var(--ub-good); }
        .ub-flash-error { background: var(--ub-bad-soft); color: var(--ub-bad); }
        .ub-table-wrap { overflow-x: auto; border: 1px solid var(--ub-line); border-radius: var(--ub-radius); background: var(--ub-surface); }
        .ub-table { width: 100%; border-collapse: collapse; font-variant-numeric: tabular-nums; }
        .ub-table th, .ub-table td { padding: 10px 12px; border-bottom: 1px solid var(--ub-line); text-align: start; vertical-align: middle; }
        .ub-table th { font-size: 12px; text-transform: uppercase; letter-spacing: .04em; color: var(--ub-muted); background: var(--ub-bg); }
        .ub-table tr:last-child td { border-bottom: 0; }
        .ub-table .ub-center { text-align: center; }
        .ub-plan { display: flex; flex-direction: column; gap: 10px; }
        .ub-plan.is-inactive { opacity: .65; }
        .ub-plan-head { display: flex; justify-content: space-between; gap: 8px; align-items: start; }
        .ub-choices { display: grid; gap: 10px; grid-template-columns: repeat(auto-fit, minmax(260px, 1fr)); }
        .ub-choice { display: flex; gap: 10px; align-items: flex-start; padding: 12px 14px; border: 1px solid var(--ub-line);
          border-radius: 10px; cursor: pointer; background: var(--ub-surface); }
        .ub-choice:has(input:checked) { border-color: var(--ub-accent); background: var(--ub-accent-soft); }
        .ub-choice input { margin-top: 3px; accent-color: var(--ub-accent); }
        .ub-choice-text { display: flex; flex-direction: column; gap: 4px; }
        .ub-choice-title { font-weight: 650; }
        .ub-price-line { display: flex; gap: 6px; align-items: baseline; flex-wrap: wrap; }
        .ub-price { font-size: 22px; font-weight: 750; font-variant-numeric: tabular-nums; }
        .ub-list { margin: 0; padding-inline-start: 18px; display: flex; flex-direction: column; gap: 2px; }
        .ub-feature-row { display: grid; grid-template-columns: minmax(0, 1fr) auto; gap: 12px; align-items: center;
          padding: 10px 0; border-bottom: 1px solid var(--ub-line); }
        .ub-feature-row:last-child { border-bottom: 0; }
        .ub-seg { display: inline-flex; border: 1px solid var(--ub-line); border-radius: 8px; overflow: hidden; }
        .ub-seg label { padding: 6px 10px; cursor: pointer; font-size: 13px; font-weight: 600; color: var(--ub-muted); }
        .ub-seg input { position: absolute; opacity: 0; width: 1px; height: 1px; }
        .ub-seg label:has(input:checked) { background: var(--ub-accent-soft); color: var(--ub-accent); }
        .ub-seg label:has(input:focus-visible) { outline: 2px solid var(--ub-accent); outline-offset: -2px; }
        .ub-num { width: 90px; }
        .ub-empty { text-align: center; padding: 32px; color: var(--ub-muted); display: flex; flex-direction: column; gap: 12px; align-items: center; }
        .ub-preview h3 { margin: 0; font-size: 18px; }
        .ub-check { color: var(--ub-good); font-weight: 700; }
        .ub-cross { color: var(--ub-muted); }
        details.ub-details summary { cursor: pointer; color: var(--ub-accent); font-weight: 600; }
        .ub-pre { white-space: pre-wrap; word-break: break-word; background: var(--ub-bg); padding: 10px; border-radius: 8px; margin: 8px 0 0; }
        .ub-locales { display: grid; gap: 12px; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); }
        .ub-translated { display: flex; gap: 8px; align-items: baseline; }
        .ub-locale { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; font-size: 11px;
          text-transform: uppercase; color: var(--ub-muted); border: 1px solid var(--ub-line); border-radius: 4px; padding: 0 4px; }
        .ub-gap-2 { gap: 2px; }
        .ub-seg-link { padding: 6px 12px; font-size: 13px; font-weight: 600; color: var(--ub-muted); text-decoration: none; }
        .ub-seg-link + .ub-seg-link, .ub-seg label + label { border-inline-start: 1px solid var(--ub-line); }
        .ub-seg-link.is-active { background: var(--ub-accent-soft); color: var(--ub-accent); }
        .ub-seg-group { display: flex; flex-direction: column; gap: 8px; }
        .ub-inline { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; }
        .ub-inline .ub-input { width: auto; }
        .ub-section-title { font-size: 13px; text-transform: uppercase; letter-spacing: .05em; color: var(--ub-muted); margin: 8px 0 0; }
        .ub-preview-locale { display: flex; flex-direction: column; gap: 8px; }
        .ub-note { background: var(--ub-accent-soft); color: var(--ub-ink); padding: 10px 12px; border-radius: 8px; font-size: 13px; }
      </style>
      """
    end
  end
end

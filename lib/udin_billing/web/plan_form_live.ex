if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule UdinBilling.Web.PlanFormLive do
    @moduledoc """
    Creates and edits a plan, with a live preview of what buyers will see.

    ## Layout
    The form is split into the questions an admin answers when designing a plan: what it's
    called (in every language), what type it is, what it costs, how long it lasts, when
    counters reset, what it includes, and which payment provider products sell it. The preview on
    the side updates on every keystroke and can be switched between languages.

    ## How it works
    Raw form params live in `@params`; `UdinBilling.Web.PlanForm` turns them into plan
    attributes and per-field errors (pure, tested on its own). Errors appear after the
    first save attempt, then update live. Saving goes through `UdinBilling.Admin`, which
    checks the admin again and runs the plan's own validations; their errors are shown on
    the matching fields.

    Editing never changes what existing buyers have: their terms were copied at purchase.

    ## Language
    Every visible text is in the `plan_form` gettext domain, in the dashboard language
    (`@ub_lang`). Under each field a short help text says what it is and gives an example
    built from the project's own catalog (`@ub_examples`), so the page never names one
    project's things. The preview uses its own language, chosen with the buttons on it.
    """
    use Phoenix.LiveView
    use Gettext, backend: UdinBilling.Gettext

    import UdinBilling.Web.Components

    alias UdinBilling.{Admin, Config, Plan}
    alias UdinBilling.Web.{PlanForm, Text}

    @impl true
    def mount(_params, _session, socket), do: {:ok, socket}

    # The form is loaded here, not in `mount/3`: the auth hook sets the page's language when
    # the params arrive, so texts made here (title, flash) are already in it. The hook may
    # patch `lang` out of the address right after opening, which runs this again. The second
    # run only refreshes the title, so it never resets what the admin has typed.
    @impl true
    def handle_params(_params, _uri, %{assigns: %{mode: mode}} = socket),
      do: {:noreply, assign(socket, :page_title, title(mode))}

    def handle_params(params, _uri, socket) do
      actor = socket.assigns.ub_actor
      {:ok, catalog} = Admin.list_features(actor)

      case start(socket.assigns.live_action, params, catalog, actor) do
        {:ok, mode, form_params} ->
          {:noreply,
           socket
           |> assign(catalog: catalog, mode: mode, submitted?: false, errors: %{})
           |> assign(plan: editing(mode), replacing: replacing(mode), locked: locked?(mode))
           |> assign(locales: Config.locales(), preview_locale: Config.default_locale())
           |> assign(page_title: title(mode))
           |> put_params(form_params)}

        {:error, _reason} ->
          {:noreply,
           socket
           |> put_flash(:error, dgettext("plan_form", "That plan doesn't exist."))
           |> push_navigate(to: dashboard_home(socket))}
      end
    end

    @impl true
    def handle_event("validate", %{"plan" => submitted}, socket) do
      {:noreply, put_params(socket, PlanForm.merge(socket.assigns.params, submitted))}
    end

    def handle_event("save", %{"plan" => submitted}, socket) do
      socket = put_params(socket, PlanForm.merge(socket.assigns.params, submitted))

      with {:ok, attrs} <- PlanForm.to_attrs(socket.assigns.params, socket.assigns.catalog),
           {:ok, message} <- persist(socket.assigns.mode, attrs, socket.assigns.ub_actor) do
        {:noreply,
         socket
         |> put_flash(:info, message)
         |> push_navigate(to: dashboard_home(socket))}
      else
        {:error, errors} when is_map(errors) and not is_struct(errors) ->
          {:noreply, show_errors(socket, localize(errors))}

        {:error, error} ->
          {:noreply, show_errors(socket, error_messages(error, socket.assigns.ub_lang))}
      end
    end

    def handle_event("preview_locale", %{"locale" => locale}, socket) do
      locale =
        if locale in socket.assigns.locales, do: locale, else: socket.assigns.preview_locale

      {:noreply, assign(socket, :preview_locale, locale)}
    end

    @impl true
    def render(assigns) do
      ~H"""
      <.shell
        base={@ub_base}
        lang={@ub_lang}
        current={@ub_current}
        dev_tools={@ub_dev_tools}
        active={:plans}
        title={@page_title}
        flash={@flash}
      >
        <:actions>
          <.button navigate={href(@ub_lang, @ub_base, "")}>
            {dgettext("plan_form", "Back to plans")}
          </.button>
        </:actions>

        <p class="ub-hint" id="plan-form-intro">
          {dgettext(
            "plan_form",
            "Design one plan here: its name, price, how long it lasts and what it includes. The preview shows what buyers will see."
          )}
        </p>
        <p :if={@plan && !@locked} class="ub-note">
          {dgettext(
            "plan_form",
            "Changes apply to new buyers. People who already bought this plan keep what they paid for."
          )}
        </p>
        <div
          :if={@locked}
          class="ub-note ub-row"
          id="plan-locked"
          style="justify-content: space-between"
        >
          <span>
            <b>{dgettext("plan_form", "This plan has buyers.")}</b>
            {dgettext(
              "plan_form",
              "Its price, type, periods and what it includes are locked. To change them, create a new version. It starts as a copy, and saving it takes this plan off sale. Current buyers keep this plan until their paid period ends."
            )}
          </span>
          <.button
            variant="primary"
            navigate={href(@ub_lang, @ub_base, "/plans/new?copy=#{@plan.id}&replace=true")}
          >
            {dgettext("plan_form", "Create new version")}
          </.button>
        </div>
        <p :if={@replacing} class="ub-note" id="plan-replacing">
          <b>{dgettext("plan_form", "New version of %{code}.", code: @replacing.code)}</b>
          {dgettext(
            "plan_form",
            "Saving creates this plan and takes %{code} off sale. Its buyers keep it until their paid period ends. Give this version its own payment provider product ids.",
            code: @replacing.code
          )}
        </p>
        <p :for={message <- unplaced(@shown)} class="ub-flash ub-flash-error" role="alert">{message}</p>

        <form id="plan-form" phx-change="validate" phx-submit="save" class="ub-split" novalidate>
          <div class="ub-stack" style="gap: 16px">
            <.fieldset
              title={dgettext("plan_form", "Name and description")}
              hint={
                dgettext(
                  "plan_form",
                  "What buyers see, in every language your app supports. Fill the same text in each language."
                )
              }
            >
              <div class="ub-stack" style="grid-column: 1 / -1">
                <.translations_input
                  field={:name}
                  form="plan"
                  label={dgettext("plan_form", "Name")}
                  values={@params["name"]}
                  errors={@shown}
                  required
                />
                <p class="ub-hint">
                  {dgettext("plan_form", "The title of the plan on the buyer's screen.")}
                  {dgettext("plan_form", "For example: %{plan_name}", plan_name: @ub_examples.plan_name)}
                </p>
                <.translations_input
                  field={:description}
                  form="plan"
                  label={dgettext("plan_form", "Description")}
                  values={@params["description"]}
                  errors={@shown}
                  multiline
                />
                <p class="ub-hint">
                  {dgettext(
                    "plan_form",
                    "One short line that says who the plan is for. You can leave it empty."
                  )}
                </p>
              </div>
            </.fieldset>

            <.fieldset title={dgettext("plan_form", "Type")}>
              <.input
                id="plan-kind"
                name="plan[kind]"
                type="select"
                disabled={@locked}
                label={dgettext("plan_form", "Plan type")}
                options={PlanForm.kind_options()}
                value={@params["kind"]}
                error={@shown["kind"]}
                hint={
                  help(
                    dgettext(
                      "plan_form",
                      "Free plans cost nothing. A one-time plan is paid once. A subscription charges again every period. The type can't change once the plan has buyers."
                    ),
                    dgettext(
                      "plan_form",
                      "For example: choose a subscription to charge %{price} %{currency} again every month.",
                      price: @ub_examples.price,
                      currency: @ub_examples.currency
                    )
                  )
                }
              />
              <.input
                id="plan-code"
                name="plan[code]"
                label={dgettext("plan_form", "Code")}
                value={@params["code"]}
                error={@shown["code"]}
                readonly={@plan != nil}
                dir="ltr"
                hint={code_hint(@plan, @ub_examples)}
                autocomplete="off"
              />
              <.input
                id="plan-sort"
                name="plan[sort_order]"
                type="number"
                label={dgettext("plan_form", "Display order")}
                value={@params["sort_order"]}
                dir="ltr"
                hint={
                  help(
                    dgettext(
                      "plan_form",
                      "A whole number. The lower the number, the earlier buyers see the plan."
                    ),
                    dgettext(
                      "plan_form",
                      "For example: a plan with 1 shows before a plan with 2."
                    )
                  )
                }
              />
              <div class="ub-stack" style="grid-column: 1 / -1">
                <.toggle_field
                  id="plan-status"
                  name="plan[status]"
                  checked={@params["status"] == "active"}
                  label={dgettext("plan_form", "On sale")}
                  value_on="active"
                  value_off="inactive"
                  hint={
                    help(
                      dgettext(
                        "plan_form",
                        "Turn it off to stop selling this plan. Buyers who already have it keep it."
                      ),
                      dgettext(
                        "plan_form",
                        "For example: turn off %{plan_name} when you stop offering it.",
                        plan_name: @ub_examples.plan_name
                      )
                    )
                  }
                />
                <.toggle_field
                  id="plan-recommended"
                  name="plan[recommended]"
                  checked={@params["recommended"] == "true"}
                  label={dgettext("plan_form", "Highlight as recommended")}
                  hint={
                    dgettext(
                      "plan_form",
                      "Adds a star to the plan so buyers notice it. It does not change the price or what is included."
                    )
                  }
                />
                <.toggle_field
                  :if={@params["kind"] == "free"}
                  id="plan-default"
                  name="plan[is_default]"
                  checked={@params["is_default"] == "true"}
                  label={dgettext("plan_form", "Default plan (everyone has it without buying)")}
                  hint={
                    help(
                      dgettext(
                        "plan_form",
                        "Every user gets this plan automatically. Only one free plan should be the default."
                      ),
                      dgettext(
                        "plan_form",
                        "For example: the starter plan that new users have before they buy %{plan_name}.",
                        plan_name: @ub_examples.plan_name
                      )
                    )
                  }
                />
              </div>
            </.fieldset>

            <.fieldset
              :if={@params["kind"] != "free"}
              title={dgettext("plan_form", "Price")}
              hint={
                dgettext(
                  "plan_form",
                  "The price buyers pay. Where a payment provider sets its own price, keep it the same."
                )
              }
            >
              <.input
                id="plan-price"
                name="plan[price]"
                readonly={@locked}
                label={dgettext("plan_form", "Price")}
                value={@params["price"]}
                error={@shown["price"]}
                inputmode="decimal"
                dir="ltr"
                placeholder={@ub_examples.price}
                hint={
                  help(
                    dgettext(
                      "plan_form",
                      "Numbers only. Use a dot for decimals. It can't change once the plan has buyers."
                    ),
                    dgettext(
                      "plan_form",
                      "For example: %{price} means buyers pay %{price} %{currency}.",
                      price: @ub_examples.price,
                      currency: @ub_examples.currency
                    )
                  )
                }
              />
              <.input
                id="plan-original-price"
                name="plan[original_price]"
                label={dgettext("plan_form", "Original price (optional)")}
                value={@params["original_price"]}
                error={@shown["original_price"]}
                inputmode="decimal"
                dir="ltr"
                hint={
                  help(
                    dgettext(
                      "plan_form",
                      "Fill it only during a sale. It shows crossed out next to the price. Buyers still pay the price. It must be higher than the price."
                    ),
                    dgettext(
                      "plan_form",
                      "For example: price %{price} and original price %{original}.",
                      price: @ub_examples.price,
                      original: double(@ub_examples.price)
                    )
                  )
                }
              />
              <%!-- Only the app's currencies; with one, there's nothing to choose. --%>
              <.input
                :if={length(PlanForm.currency_options()) > 1}
                id="plan-currency"
                name="plan[currency]"
                type="select"
                disabled={@locked}
                label={dgettext("plan_form", "Currency")}
                options={PlanForm.currency_options()}
                value={@params["currency"]}
                error={@shown["currency"]}
                hint={
                  help(
                    dgettext(
                      "plan_form",
                      "The currency of the price. It can't change once the plan has buyers."
                    ),
                    dgettext(
                      "plan_form",
                      "For example: choose %{currency} if the price is %{price} %{currency}.",
                      price: @ub_examples.price,
                      currency: @ub_examples.currency
                    )
                  )
                }
              />
            </.fieldset>

            <.period
              name="validity"
              title={
                if @params["kind"] == "recurring",
                  do: dgettext("plan_form", "Billing period"),
                  else: dgettext("plan_form", "How long it lasts")
              }
              hint={validity_hint(@params["kind"])}
              example={validity_example(@params["kind"])}
              params={@params}
              locked={@locked}
              error={@shown["validity"]}
              on_label={
                if @params["kind"] == "recurring",
                  do: dgettext("plan_form", "Renews every"),
                  else: dgettext("plan_form", "Lasts")
              }
              off_label={dgettext("plan_form", "Never ends")}
              off_value="forever"
            />

            <.period
              name="cycle"
              title={dgettext("plan_form", "Counter reset")}
              hint={reset_hint(@catalog)}
              example={
                dgettext(
                  "plan_form",
                  "For example: reset every 1 month, so each month buyers get %{amount} %{feature} again.",
                  amount: @ub_examples.amount,
                  feature: @ub_examples.feature
                )
              }
              params={@params}
              locked={@locked}
              error={@shown["cycle"]}
              on_label={dgettext("plan_form", "Reset every")}
              off_label={dgettext("plan_form", "Never resets (given once)")}
              off_value="none"
            />

            <.fieldset
              :if={@params["kind"] == "free"}
              title={dgettext("plan_form", "After a subscription ends")}
              hint={
                dgettext(
                  "plan_form",
                  "Subscribers don't get the free plan on top of their plan. This decides what they get when they're back on free."
                )
              }
            >
              <.choice_cards
                id="plan-after-subscription"
                name="plan[after_subscription]"
                value={@params["after_subscription"]}
                options={PlanForm.after_subscription_options()}
              />
              <p class="ub-hint" style="grid-column: 1 / -1">
                {dgettext(
                  "plan_form",
                  "For example: a user used all %{amount} free %{feature}, subscribed, then cancelled. With the first choice they get no new free %{feature}. With the second they get %{amount} again.",
                  amount: @ub_examples.amount,
                  feature: @ub_examples.feature
                )}
              </p>
            </.fieldset>

            <.fieldset
              title={dgettext("plan_form", "What's included")}
              hint={
                dgettext(
                  "plan_form",
                  "Anything not turned on here is off for this plan. What it includes can't change once the plan has buyers."
                )
              }
            >
              <div class="ub-stack" style="grid-column: 1 / -1; gap: 0">
                <.empty
                  :if={@catalog == []}
                  message={dgettext("plan_form", "No features yet. Add switches and counters first.")}
                >
                  <:action>
                    <.button
                      :if={@ub_dev_tools}
                      navigate={href(@ub_lang, @ub_base, "/features/new")}
                    >
                      {dgettext("plan_form", "Add a feature")}
                    </.button>
                  </:action>
                </.empty>
                <.feature_row
                  :for={feature <- @catalog}
                  feature={feature}
                  params={@params["features"][feature.key]}
                  locked={@locked}
                  error={@shown["features.#{feature.key}"]}
                  amount={@ub_examples.amount}
                />
                <.link
                  :if={@catalog != [] and @ub_dev_tools}
                  navigate={href(@ub_lang, @ub_base, "/features")}
                  class="ub-small"
                  style="margin-top: 8px"
                >
                  {dgettext("plan_form", "Manage features")}
                </.link>
              </div>
            </.fieldset>

            <.fieldset
              :if={@params["kind"] != "free" and @providers != []}
              title={dgettext("plan_form", "Payment provider products")}
              hint={
                dgettext(
                  "plan_form",
                  "The id each payment provider knows this plan by. Several ids: separate with commas."
                )
              }
            >
              <.input
                :for={provider <- @providers}
                id={"plan-product-#{provider}"}
                name={"plan[product_ids][#{provider}]"}
                label={provider}
                value={@params["product_ids"][provider]}
                autocomplete="off"
                dir="ltr"
                hint={
                  help(
                    dgettext(
                      "plan_form",
                      "Copy the id exactly as it appears at the provider. A wrong id means purchases won't match this plan. Leave it empty if you don't sell this plan there."
                    ),
                    dgettext("plan_form", "For example: %{id}", id: "#{@ub_examples.plan_code}_monthly")
                  )
                }
              />
            </.fieldset>
          </div>

          <aside class="ub-stack ub-sticky">
            <.preview attrs={@attrs} catalog={@catalog} locale={@preview_locale} locales={@locales} />
            <.button
              type="submit"
              variant="primary"
              phx-disable-with={dgettext("plan_form", "Saving…")}
            >
              {if @plan,
                do: dgettext("plan_form", "Save changes"),
                else: dgettext("plan_form", "Create plan")}
            </.button>
            <p class="ub-hint">
              {dgettext(
                "plan_form",
                "Saving applies right away to new buyers. Nothing is charged by saving."
              )}
            </p>
            <p :if={@submitted? and @errors != %{}} class="ub-error" role="alert">
              {dgettext("plan_form", "Fix the highlighted fields to save.")}
            </p>
          </aside>
        </form>
      </.shell>
      """
    end

    attr :id, :string, required: true
    attr :name, :string, required: true
    attr :checked, :boolean, default: false
    attr :label, :string, required: true
    attr :hint, :string, required: true
    attr :value_on, :string, default: "true"
    attr :value_off, :string, default: "false"
    attr :rest, :global, include: ~w(disabled)

    defp toggle_field(assigns) do
      ~H"""
      <div class="ub-stack" style="gap: 2px">
        <.toggle
          id={@id}
          name={@name}
          checked={@checked}
          label={@label}
          value_on={@value_on}
          value_off={@value_off}
          {@rest}
        />
        <p class="ub-hint">{@hint}</p>
      </div>
      """
    end

    attr :name, :string, required: true
    attr :title, :string, required: true
    attr :hint, :string, required: true
    attr :example, :string, required: true
    attr :params, :map, required: true
    attr :locked, :boolean, default: false
    attr :error, :string, default: nil
    attr :on_label, :string, required: true
    attr :off_label, :string, required: true
    attr :off_value, :string, required: true

    defp period(assigns) do
      assigns = assign(assigns, :on?, assigns.params["#{assigns.name}_mode"] == "period")

      ~H"""
      <.fieldset title={@title} hint={@hint}>
        <div class="ub-seg-group" style="grid-column: 1 / -1">
          <div class="ub-seg" role="radiogroup" aria-label={@title}>
            <label for={"plan-#{@name}-on"}>
              <input
                type="radio"
                id={"plan-#{@name}-on"}
                name={"plan[#{@name}_mode]"}
                value="period"
                checked={@on?}
                disabled={@locked}
              />
              {@on_label}
            </label>
            <label for={"plan-#{@name}-off"}>
              <input
                type="radio"
                id={"plan-#{@name}-off"}
                name={"plan[#{@name}_mode]"}
                value={@off_value}
                checked={!@on?}
                disabled={@locked}
              />
              {@off_label}
            </label>
          </div>
          <div :if={@on?} class="ub-inline">
            <input
              id={"plan-#{@name}-count"}
              name={"plan[#{@name}_count]"}
              type="number"
              min="1"
              value={@params["#{@name}_count"]}
              class="ub-input ub-num"
              aria-label={dgettext("plan_form", "How many")}
              disabled={@locked}
            />
            <select
              id={"plan-#{@name}-unit"}
              name={"plan[#{@name}_unit]"}
              class="ub-input"
              aria-label={dgettext("plan_form", "Unit")}
              disabled={@locked}
            >
              <option
                :for={{label, value} <- PlanForm.unit_options()}
                value={value}
                selected={value == @params["#{@name}_unit"]}
              >
                {label}
              </option>
            </select>
          </div>
          <p class="ub-hint">{@example}</p>
          <p :if={@error} class="ub-error" role="alert">{@error}</p>
        </div>
      </.fieldset>
      """
    end

    attr :feature, :map, required: true
    attr :params, :map, required: true
    attr :locked, :boolean, default: false
    attr :error, :string, default: nil
    attr :amount, :integer, required: true

    defp feature_row(%{feature: %{kind: :switch}} = assigns) do
      ~H"""
      <div class="ub-feature-row" id={"feature-#{@feature.key}"}>
        <.feature_label feature={@feature} />
        <div class="ub-stack" style="gap: 2px; align-items: flex-end">
          <.toggle
            id={"plan-feature-#{@feature.key}"}
            name={"plan[features][#{@feature.key}][on]"}
            checked={@params["on"] == "true"}
            label={gettext("Included")}
            disabled={@locked}
          />
          <p class="ub-hint">
            {dgettext("plan_form", "Turn it on to give this feature to buyers of this plan.")}
          </p>
        </div>
      </div>
      """
    end

    defp feature_row(%{feature: %{kind: :counter}} = assigns) do
      assigns = assign(assigns, :name, feature_name(assigns.feature))

      ~H"""
      <div class="ub-feature-row" id={"feature-#{@feature.key}"}>
        <.feature_label feature={@feature} />
        <div class="ub-stack" style="gap: 6px; align-items: flex-end">
          <div class="ub-inline">
            <div
              class="ub-seg"
              role="radiogroup"
              aria-label={dgettext("plan_form", "%{feature} amount", feature: @name)}
            >
              <label
                :for={
                  {label, value} <- [
                    {gettext("Not included"), "off"},
                    {dgettext("plan_form", "Limited"), "limited"},
                    {gettext("Unlimited"), "unlimited"}
                  ]
                }
                for={"plan-feature-#{@feature.key}-#{value}"}
              >
                <input
                  type="radio"
                  id={"plan-feature-#{@feature.key}-#{value}"}
                  name={"plan[features][#{@feature.key}][mode]"}
                  value={value}
                  checked={@params["mode"] == value}
                  disabled={@locked}
                />
                {label}
              </label>
            </div>
            <label
              :if={@params["mode"] == "limited"}
              for={"plan-feature-#{@feature.key}-limit"}
              class="ub-sr-only"
            >
              {dgettext("plan_form", "%{feature} limit", feature: @name)}
            </label>
            <input
              :if={@params["mode"] == "limited"}
              id={"plan-feature-#{@feature.key}-limit"}
              name={"plan[features][#{@feature.key}][limit]"}
              type="number"
              min="1"
              value={@params["limit"]}
              class="ub-input ub-num"
              aria-label={dgettext("plan_form", "%{feature} limit", feature: @name)}
              placeholder={@amount}
              disabled={@locked}
            />
          </div>
          <p class="ub-hint">
            {dgettext(
              "plan_form",
              "Not included, a set number of units, or unlimited. Limited needs a whole number above 0."
            )}
            {dgettext("plan_form", "For example: %{amount} %{feature}", amount: @amount, feature: @name)}
          </p>
          <p :if={@error} class="ub-error" role="alert">{@error}</p>
        </div>
      </div>
      """
    end

    attr :feature, :map, required: true

    defp feature_label(assigns) do
      ~H"""
      <div>
        <div style="font-weight: 600">{feature_name(@feature)}</div>
        <div class="ub-small ub-muted">
          <span class="ub-mono">{@feature.key}</span>
          · {if @feature.kind == :switch,
            do: dgettext("plan_form", "Switch"),
            else: dgettext("plan_form", "Counter")}
        </div>
      </div>
      """
    end

    attr :attrs, :map, required: true
    attr :catalog, :list, required: true
    attr :locale, :string, required: true
    attr :locales, :list, required: true

    defp preview(assigns) do
      assigns =
        assign(
          assigns,
          :included,
          PlanForm.included(assigns.attrs, assigns.catalog, assigns.locale)
        )

      ~H"""
      <.card class="ub-preview">
        <div class="ub-row" style="justify-content: space-between">
          <span class="ub-section-title" style="margin: 0">{dgettext("plan_form", "Preview")}</span>
          <div class="ub-seg" role="group" aria-label={dgettext("plan_form", "Preview language")}>
            <button
              :for={locale <- @locales}
              type="button"
              class={["ub-seg-link", locale == @locale && "is-active"]}
              style="border: 0; background: none; cursor: pointer; font: inherit"
              phx-click="preview_locale"
              phx-value-locale={locale}
              aria-pressed={to_string(locale == @locale)}
            >
              {String.upcase(locale)}
            </button>
          </div>
        </div>
        <p class="ub-hint">
          {dgettext(
            "plan_form",
            "This is how buyers will see the plan. Switch the language to check each translation. It does not change the language of this page."
          )}
        </p>
        <div class="ub-preview-locale" dir={dir(@locale)} lang={@locale} style="margin-top: 12px">
          <div class="ub-row" style="justify-content: space-between">
            <h3>{translation(@attrs, :name, @locale) || Text.untitled(@locale)}</h3>
            <span
              :if={get_in(@attrs, [:metadata, "recommended"])}
              title={dgettext("plan_form", "Recommended")}
              aria-label={dgettext("plan_form", "Recommended")}
            >
              <.badge tone="accent">★</.badge>
            </span>
          </div>
          <div class="ub-price-line">
            <s :if={buyer_original_price(@attrs)} class="ub-muted">
              <bdi>{buyer_original_price(@attrs)}</bdi>
            </s>
            <bdi class="ub-price">{buyer_price(@attrs, @locale)}</bdi>
            <bdi class="ub-muted">{buyer_period(@attrs, @locale)}</bdi>
          </div>
          <p :if={translation(@attrs, :description, @locale)} class="ub-muted" style="margin: 0">
            {translation(@attrs, :description, @locale)}
          </p>
          <ul :if={@included != []} class="ub-list">
            <li :for={item <- @included}>
              {item.name}<span :if={item.value != true}>: <.feature_value
                  value={item.value}
                  locale={@locale}
                /></span>
            </li>
          </ul>
          <p :if={@included == []} class="ub-muted ub-small" style="margin: 0">
            {Text.nothing_included(@locale)}
          </p>
          <p :if={@attrs[:cycle_unit]} class="ub-small ub-muted" style="margin: 0" dir="ltr">
            {Text.resets(@attrs[:cycle_unit], @attrs[:cycle_count], @locale)}
          </p>
        </div>
      </.card>
      """
    end

    # -- state --------------------------------------------------------------------

    # Modes: :create, {:edit, plan}, {:replace, old_plan} (a new version of a sold plan).
    defp start(:new, %{"copy" => id, "replace" => "true"}, catalog, actor) do
      with {:ok, plan} <- Admin.get_plan(id, actor),
           do: {:ok, {:replace, plan}, PlanForm.new_version_of(plan, catalog)}
    end

    defp start(:new, %{"copy" => id}, catalog, actor) do
      with {:ok, plan} <- Admin.get_plan(id, actor),
           do: {:ok, :create, PlanForm.copy_of(plan, catalog)}
    end

    defp start(:new, _params, catalog, _actor),
      do: {:ok, :create, PlanForm.from_plan(nil, catalog)}

    defp start(:edit, %{"id" => id}, catalog, actor) do
      with {:ok, plan} <- Admin.get_plan(id, actor),
           do: {:ok, {:edit, plan}, PlanForm.from_plan(plan, catalog)}
    end

    defp editing({:edit, plan}), do: plan
    defp editing(_mode), do: nil

    defp replacing({:replace, plan}), do: plan
    defp replacing(_mode), do: nil

    defp locked?({:edit, plan}), do: Plan.sold?(plan.id)
    defp locked?(_mode), do: false

    defp title({:edit, _plan}), do: dgettext("plan_form", "Edit plan")

    defp title({:replace, plan}),
      do: dgettext("plan_form", "New version of %{code}", code: plan.code)

    defp title(:create), do: dgettext("plan_form", "New plan")

    # Where saving (or a missing plan) sends the admin: the plan list, in their language.
    defp dashboard_home(socket), do: href(socket.assigns.ub_lang, socket.assigns.ub_base, "")

    # Parses on every change so the preview is always current; errors show only after
    # the first save attempt so a fresh form isn't covered in red.
    defp put_params(socket, params) do
      {attrs, errors} = PlanForm.parse(params, socket.assigns.catalog)
      errors = if socket.assigns.submitted?, do: localize(errors), else: socket.assigns.errors

      socket
      |> assign(params: params, attrs: attrs, errors: errors, providers: PlanForm.providers())
      |> assign(:shown, if(socket.assigns.submitted?, do: errors, else: %{}))
    end

    defp show_errors(socket, errors),
      do: assign(socket, submitted?: true, errors: errors, shown: errors)

    # `PlanForm` writes its own messages in the page's language, but the two it takes from
    # `UdinBilling.Web.Fields` (shared with other pages) are English at the source.
    defp localize(errors) do
      Map.new(errors, fn {field, message} -> {field, localize_message(message)} end)
    end

    defp localize_message("required"), do: dgettext("plan_form", "required")

    defp localize_message("fill every language or leave all empty"),
      do: dgettext("plan_form", "fill every language or leave all empty")

    defp localize_message(message), do: message

    # Errors with no input of their own (e.g. a database rule), shown above the form.
    defp unplaced(errors) do
      errors
      |> Enum.reject(fn {key, _message} ->
        key in ~w(code kind price original_price currency validity cycle) or
          String.starts_with?(key, ["name.", "description.", "features."])
      end)
      |> Enum.map(fn {key, message} ->
        if key == "base", do: message, else: "#{key}: #{message}"
      end)
    end

    defp persist(:create, attrs, actor) do
      with {:ok, plan} <- Admin.create_plan(attrs, actor),
           do: {:ok, dgettext("plan_form", "Saved %{code}.", code: plan.code)}
    end

    # Editing keeps what the form doesn't show (`PlanForm.keep_hidden/2`).
    defp persist({:edit, plan}, attrs, actor) do
      with {:ok, plan} <- Admin.update_plan(plan, PlanForm.keep_hidden(attrs, plan), actor),
           do: {:ok, dgettext("plan_form", "Saved %{code}.", code: plan.code)}
    end

    # A new version keeps the old plan's hidden metadata, but never its product ids: those
    # stay with the old plan, whose subscribers keep renewing it.
    defp persist({:replace, old}, attrs, actor) do
      attrs = Map.update(attrs, :metadata, old.metadata, &Map.merge(old.metadata || %{}, &1))

      with {:ok, %{new: new}} <- Admin.replace_plan(old, attrs, actor) do
        {:ok,
         dgettext("plan_form", "Created %{new}. %{old} is off sale.",
           new: new.code,
           old: old.code
         )}
      end
    end

    # -- display ------------------------------------------------------------------

    defp translation(attrs, field, locale),
      do: attrs |> Map.get(field) |> UdinBilling.Translations.get(locale)

    defp feature_name(feature),
      do:
        Plan.localized(feature, :name, Config.default_locale()) || PlanForm.humanize(feature.key)

    # Two help sentences (what it is, then an example or warning) as one hint.
    defp help(text, example), do: text <> " " <> example

    # Twice the example price, for the "original price" example. Falls back to the price
    # itself when a project's configured example isn't a plain number.
    defp double(price) do
      case Decimal.parse(price) do
        {number, ""} -> number |> Decimal.mult(2) |> Decimal.to_string(:normal)
        _other -> price
      end
    end

    defp code_hint(nil, examples) do
      help(
        dgettext(
          "plan_form",
          "A short id: lowercase letters, numbers and dashes. It can't change later."
        ),
        dgettext("plan_form", "For example: %{plan_code}", plan_code: examples.plan_code)
      )
    end

    defp code_hint(_plan, examples) do
      help(
        dgettext(
          "plan_form",
          "Fixed once created. Your app and payment providers refer to it."
        ),
        dgettext("plan_form", "For example: %{plan_code}", plan_code: examples.plan_code)
      )
    end

    # Names this app's own counters (from its feature catalog), so the default hint fits
    # any app.
    defp reset_hint(catalog) do
      names =
        for %{kind: :counter} = feature <- catalog,
            do: feature_name(feature)

      case names do
        [] ->
          dgettext(
            "plan_form",
            "When counters refill. A yearly plan can reset monthly. Unused units don't carry over. The refill can't be longer than the billing period."
          )

        names ->
          dgettext(
            "plan_form",
            "When counters (%{names}) refill. A yearly plan can reset monthly. Unused units don't carry over. The refill can't be longer than the billing period.",
            names: Enum.join(names, ", ")
          )
      end
    end

    defp validity_hint("recurring"),
      do:
        dgettext(
          "plan_form",
          "How often the subscription renews and charges. Access lasts until the paid period ends. It can't change once the plan has buyers."
        )

    defp validity_hint("free"),
      do: dgettext("plan_form", "Usually never ends. Counters refill on the reset below.")

    defp validity_hint(_kind),
      do:
        dgettext(
          "plan_form",
          "How long a buyer can use it after paying. It can't change once the plan has buyers."
        )

    defp validity_example("recurring"),
      do:
        dgettext(
          "plan_form",
          "For example: 1 month charges every month. 1 year charges once a year."
        )

    defp validity_example("free"),
      do: dgettext("plan_form", "For example: choose never ends for a plan that is always free.")

    defp validity_example(_kind),
      do: dgettext("plan_form", "For example: 7 days or 1 month after paying.")
  end
end

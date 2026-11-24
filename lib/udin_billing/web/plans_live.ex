if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule UdinBilling.Web.PlansLive do
    @moduledoc """
    The dashboard's home: every plan, grouped by type, as cards or as a plans × features
    comparison table.

    ## Two languages
    The dashboard's own language (`?lang=`, texts in the `plans` gettext domain) and the
    preview language of the cards (`?locale=`, buyer-facing words from
    `UdinBilling.Web.Text`) are independent. Every link keeps both.

    ## What an admin can do here
      * See what each plan includes, its price and period, and whether every language
        has its name (a missing translation is flagged on the card).
      * Switch the language the cards show (`?locale=ar`) to check how users see them.
      * Take a plan off sale or put it back (buyers keep what they bought).
      * Start a new plan, edit one, or duplicate one (e.g. yearly from monthly).
    """
    use Phoenix.LiveView
    use Gettext, backend: UdinBilling.Gettext

    import UdinBilling.Web.Components

    alias UdinBilling.{Admin, Config, Plan, Translations}
    alias UdinBilling.Web.PlanForm

    @groups [:recurring, :one_time, :free]

    @impl true
    def mount(_params, _session, socket) do
      {:ok, load(socket)}
    end

    @impl true
    def handle_params(params, _uri, socket) do
      {:noreply,
       socket
       |> assign(:view, if(params["view"] == "compare", do: "compare", else: "cards"))
       |> assign(:locale, pick_locale(params["locale"]))}
    end

    @impl true
    def handle_event("activate", %{"id" => id}, socket), do: change_status(socket, id, :activate)

    def handle_event("deactivate", %{"id" => id}, socket),
      do: change_status(socket, id, :deactivate)

    @impl true
    def render(assigns) do
      ~H"""
      <.shell
        base={@ub_base}
        lang={@ub_lang}
        current={@ub_current}
        dev_tools={@ub_dev_tools}
        active={:plans}
        title={gettext("Plans")}
        flash={@flash}
      >
        <:actions>
          <.button variant="primary" navigate={href(@ub_lang, @ub_base, "/plans/new")}>
            {dgettext("plans", "New plan")}
          </.button>
        </:actions>

        <p class="ub-note">
          {dgettext(
            "plans",
            "See every plan with its price, what it includes and whether it is on sale. Open a plan to change it, or start a new one."
          )}
        </p>

        <div class="ub-row" style="justify-content: space-between; align-items: flex-start">
          <div class="ub-stack" style="gap: 4px">
            <div class="ub-seg" role="group" aria-label={dgettext("plans", "View")}>
              <.link
                :for={{value, label} <- view_options()}
                patch={path(@ub_lang, @ub_base, value, @locale)}
                class={["ub-seg-link", @view == value && "is-active"]}
                aria-current={@view == value && "true"}
              >
                {label}
              </.link>
            </div>
            <p class="ub-hint" style="margin: 0">
              {dgettext(
                "plans",
                "Cards show one box for each plan. Compare puts all plans in one table, so you can see which plan has which feature."
              )}
            </p>
            <p class="ub-hint" style="margin: 0">
              {dgettext(
                "plans",
                "For example: Compare shows at a glance which plans include %{feature}.",
                @ub_examples
              )}
            </p>
          </div>
          <div class="ub-stack" style="gap: 4px">
            <div class="ub-small ub-muted">{dgettext("plans", "Preview language")}</div>
            <div class="ub-seg" role="group" aria-label={dgettext("plans", "Preview language")}>
              <.link
                :for={locale <- @locales}
                patch={path(@ub_lang, @ub_base, @view, locale)}
                class={["ub-seg-link", @locale == locale && "is-active"]}
                aria-current={@locale == locale && "true"}
              >
                {language(locale)}
              </.link>
            </div>
            <p class="ub-hint" style="margin: 0">
              {dgettext(
                "plans",
                "Shows how buyers in that language see the cards. It does not change the language of this dashboard."
              )}
            </p>
            <p class="ub-hint" style="margin: 0">
              {dgettext(
                "plans",
                "For example: choose Arabic to check that the plan %{plan_name} reads well for Arabic buyers.",
                @ub_examples
              )}
            </p>
          </div>
        </div>

        <.empty :if={@plans == []} message={dgettext("plans", "No plans yet. Create the first one.")}>
          <:action>
            <.button variant="primary" navigate={href(@ub_lang, @ub_base, "/plans/new")}>
              {dgettext("plans", "New plan")}
            </.button>
          </:action>
        </.empty>

        <details :if={@plans != [] and @view == "cards"} class="ub-details" id="plans-legend">
          <summary>{dgettext("plans", "What do the labels and buttons mean?")}</summary>
          <ul class="ub-list">
            <li>
              {dgettext("plans", "Off sale: nobody can buy this plan now. Current buyers keep it.")}
            </li>
            <li>
              {dgettext("plans", "Default: the free plan every new user starts on.")}
            </li>
            <li>
              {dgettext(
                "plans",
                "Has buyers: someone already bought it, so its price and period can't change."
              )}
            </li>
            <li>
              {dgettext("plans", "Recommended: the plan buyers are pointed to first.")}
            </li>
            <li>
              {dgettext("plans", "Missing: the name or text is not written in that language yet.")}
            </li>
            <li>
              {dgettext("plans", "Edit: change the plan's texts, price or features.")}
            </li>
            <li>
              {dgettext(
                "plans",
                "Duplicate: make a copy to start from, for example a yearly plan from a monthly one."
              )}
            </li>
            <li>
              {dgettext(
                "plans",
                "New version: for a plan that has buyers. It opens a copy where you can set the new price, then you take the old plan off sale."
              )}
            </li>
            <li>
              {dgettext(
                "plans",
                "Take off sale: stops new buyers. Current buyers keep what they bought. You can put the plan back on sale at any time."
              )}
            </li>
          </ul>
        </details>

        <div :if={@plans != [] and @view == "cards"} class="ub-stack" style="gap: 28px">
          <section :for={kind <- @groups} :if={@by_kind[kind]} class="ub-stack">
            <div>
              <h2 class="ub-h2">{group_title(kind)}</h2>
              <p class="ub-hint" style="margin: 0">{group_help(kind)}</p>
            </div>
            <div class="ub-grid">
              <.plan_card
                :for={plan <- @by_kind[kind]}
                plan={plan}
                catalog={@catalog}
                locale={@locale}
                base={@ub_base}
                lang={@ub_lang}
                sold={MapSet.member?(@sold, plan.id)}
              />
            </div>
          </section>
        </div>

        <.compare
          :if={@plans != [] and @view == "compare"}
          plans={@plans}
          catalog={@catalog}
          locale={@locale}
          base={@ub_base}
          lang={@ub_lang}
        />
      </.shell>
      """
    end

    defp view_options do
      [{"cards", dgettext("plans", "Cards")}, {"compare", dgettext("plans", "Compare")}]
    end

    defp group_title(:recurring), do: dgettext("plans", "Subscription plans")
    defp group_title(:one_time), do: dgettext("plans", "One-time plans")
    defp group_title(:free), do: dgettext("plans", "Free plan")

    defp group_help(:recurring),
      do:
        dgettext(
          "plans",
          "Buyers pay again every billing period until they cancel."
        )

    defp group_help(:one_time),
      do:
        dgettext(
          "plans",
          "Buyers pay once and get access for a fixed time or a fixed number of units."
        )

    defp group_help(:free),
      do: dgettext("plans", "Costs nothing. Users get it without paying.")

    attr :plan, :map, required: true
    attr :catalog, :list, required: true
    attr :locale, :string, required: true
    attr :base, :string, required: true
    attr :lang, :string, required: true
    attr :sold, :boolean, default: false

    defp plan_card(assigns) do
      assigns =
        assigns
        |> assign(:included, PlanForm.included(assigns.plan, assigns.catalog, assigns.locale))
        |> assign(:missing, Translations.missing(assigns.plan.name))

      ~H"""
      <.card class={["ub-plan", @plan.status == :inactive && "is-inactive"]} id={"plan-#{@plan.id}"}>
        <div class="ub-plan-head">
          <div>
            <div class="ub-h2" dir={dir(@locale)} lang={@locale}>
              {Plan.localized(@plan, :name, @locale)}
            </div>
            <div class="ub-mono ub-muted" dir="ltr">{@plan.code}</div>
          </div>
          <div class="ub-row" style="gap: 4px; justify-content: flex-end">
            <.badge :if={@plan.status == :inactive} tone="neutral">
              {dgettext("plans", "Off sale")}
            </.badge>
            <.badge :if={@plan.is_default} tone="good">{dgettext("plans", "Default")}</.badge>
            <.badge :if={@sold} tone="neutral">{dgettext("plans", "Has buyers")}</.badge>
            <.badge :if={@plan.metadata["recommended"] == true} tone="accent">
              {dgettext("plans", "Recommended")}
            </.badge>
            <.badge :if={@missing != []} tone="warn">
              {dgettext("plans", "Missing %{languages}", languages: Enum.join(@missing, ", "))}
            </.badge>
          </div>
        </div>

        <div class="ub-price-line">
          <s :if={buyer_original_price(@plan)} class="ub-muted">
            <bdi>{buyer_original_price(@plan)}</bdi>
          </s>
          <bdi class="ub-price">{buyer_price(@plan, @locale)}</bdi>
          <bdi class="ub-muted">{buyer_period(@plan, @locale)}</bdi>
        </div>
        <div :if={@plan.cycle_unit} class="ub-small ub-muted">
          {UdinBilling.Web.Text.resets(@plan.cycle_unit, @plan.cycle_count, @locale)}
        </div>

        <p
          :if={Plan.localized(@plan, :description, @locale)}
          class="ub-muted"
          style="margin: 0"
          dir={dir(@locale)}
          lang={@locale}
        >
          {Plan.localized(@plan, :description, @locale)}
        </p>

        <ul :if={@included != []} class="ub-list" dir={dir(@locale)} lang={@locale}>
          <li :for={item <- @included}>
            {item.name}<span :if={item.value != true}>: <.feature_value
                value={item.value}
                locale={@locale}
              /></span>
          </li>
        </ul>
        <p :if={@included == []} class="ub-muted ub-small" style="margin: 0">
          {UdinBilling.Web.Text.nothing_included(@locale)}
        </p>

        <div :if={@plan.provider_product_ids != %{}} class="ub-small ub-muted">
          <div>{dgettext("plans", "Ids at the payment provider")}</div>
          <div :for={{provider, ids} <- @plan.provider_product_ids}>
            {provider}: <span class="ub-mono" dir="ltr">{ids |> List.wrap() |> Enum.join(", ")}</span>
          </div>
        </div>

        <div class="ub-small ub-muted">
          {dgettext("plans", "Created %{created}, updated %{updated}",
            created: day(@plan.inserted_at),
            updated: day(@plan.updated_at)
          )}
        </div>

        <div class="ub-row" style="margin-top: auto">
          <.button navigate={href(@lang, @base, "/plans/#{@plan.id}/edit")}>
            {dgettext("plans", "Edit")}
          </.button>
          <.button
            :if={@sold}
            variant="ghost"
            navigate={href(@lang, @base, "/plans/new?copy=#{@plan.id}&replace=true")}
          >
            {dgettext("plans", "New version")}
          </.button>
          <.button
            :if={!@sold}
            variant="ghost"
            navigate={href(@lang, @base, "/plans/new?copy=#{@plan.id}")}
          >
            {dgettext("plans", "Duplicate")}
          </.button>
          <.button
            :if={@plan.status == :active}
            variant="ghost"
            phx-click="deactivate"
            phx-value-id={@plan.id}
            data-confirm={
              dgettext(
                "plans",
                "Take this plan off sale? Nobody can buy it anymore. Current buyers keep it until their paid period ends. You can put it back on sale later."
              )
            }
          >
            {dgettext("plans", "Take off sale")}
          </.button>
          <.button
            :if={@plan.status == :inactive}
            variant="ghost"
            phx-click="activate"
            phx-value-id={@plan.id}
          >
            {dgettext("plans", "Put on sale")}
          </.button>
        </div>
      </.card>
      """
    end

    attr :plans, :list, required: true
    attr :catalog, :list, required: true
    attr :locale, :string, required: true
    attr :base, :string, required: true
    attr :lang, :string, required: true

    defp compare(assigns) do
      ~H"""
      <p class="ub-hint">
        {dgettext(
          "plans",
          "Each row is a feature and each column is a plan. A check mark means included. A number is how many units the plan gives. Unlimited means no limit. A cross means not included."
        )}
      </p>
      <div class="ub-table-wrap">
        <table class="ub-table" id="plans-compare">
          <thead>
            <tr>
              <th scope="col">{dgettext("plans", "Feature")}</th>
              <th :for={plan <- @plans} scope="col" class="ub-center">
                <.link navigate={href(@lang, @base, "/plans/#{plan.id}/edit")} dir={dir(@locale)}>
                  {Plan.localized(plan, :name, @locale)}
                </.link>
                <div class="ub-small" style="text-transform: none">
                  {buyer_price(plan, @locale)} {buyer_period(plan, @locale)}
                </div>
              </th>
            </tr>
          </thead>
          <tbody>
            <tr :for={feature <- @catalog}>
              <th scope="row" style="text-transform: none; letter-spacing: 0">
                <span dir={dir(@locale)} lang={@locale}>
                  {Plan.localized(feature, :name, @locale) || PlanForm.humanize(feature.key)}
                </span>
                <div class="ub-mono ub-muted" dir="ltr">{feature.key}</div>
              </th>
              <td :for={plan <- @plans} class="ub-center">
                <.feature_value value={Map.get(plan.features, feature.key)} locale={@locale} />
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      """
    end

    defp load(socket) do
      actor = socket.assigns.ub_actor
      {:ok, catalog} = Admin.list_features(actor)
      {:ok, plans} = Admin.list_plans(actor)

      socket
      |> assign(:catalog, catalog)
      |> assign(:plans, plans)
      |> assign(:sold, Plan.sold_ids(Enum.map(plans, & &1.id)))
      |> assign(:by_kind, Enum.group_by(plans, & &1.kind))
      |> assign(:groups, @groups)
      |> assign(:locales, Config.locales())
    end

    defp change_status(socket, id, action) do
      actor = socket.assigns.ub_actor

      result =
        with {:ok, plan} <- Admin.get_plan(id, actor), do: set_status(action, plan, actor)

      case result do
        {:ok, plan} ->
          {:noreply, socket |> load() |> put_flash(:info, status_message(plan))}

        {:error, error} ->
          reason = error_text(error, socket.assigns.ub_lang)

          {:noreply,
           put_flash(
             socket,
             :error,
             dgettext("plans", "Couldn't change the plan: %{reason}", reason: reason)
           )}
      end
    end

    defp set_status(:activate, plan, actor), do: Admin.activate_plan(plan, actor)
    defp set_status(:deactivate, plan, actor), do: Admin.deactivate_plan(plan, actor)

    defp status_message(%{status: :active, code: code}),
      do: dgettext("plans", "%{code} is on sale.", code: code)

    defp status_message(%{code: code}), do: dgettext("plans", "%{code} is off sale.", code: code)

    defp error_text(error, lang),
      do: error |> error_messages(lang) |> Map.values() |> Enum.join(", ")

    defp pick_locale(locale) do
      if locale in Config.locales(), do: locale, else: Config.default_locale()
    end

    # Keeps both languages: `lang` (this dashboard) and `locale` (the cards' preview).
    defp path(lang, base, view, locale),
      do: href(lang, base, "?" <> URI.encode_query(view: view, locale: locale))

    defp day(at), do: Calendar.strftime(at, "%Y-%m-%d")
  end
end

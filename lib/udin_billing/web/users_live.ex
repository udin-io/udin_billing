if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule UdinBilling.Web.UsersLive do
    @moduledoc """
    One user's billing, for support: what they have now and a way to give them a plan.

    ## What an admin can do here
      * Look up a user by id (`?user_id=...`, so a support link can open it directly), or,
        when the app sets `:user_search`, by anything that app supports, such as a phone
        number (`?q=...`). One match opens the user, several are listed to choose from.
      * See each counter's balance and when it resets, the switches that are on, and the
        plans and purchases granting them.
      * Give a one-time plan for free (compensation, support gesture) with a reason; it's
        recorded as a purchase of amount 0 from provider `"admin"`, with the admin's id.
        Only while the developer tools are on (`UdinBilling.Config.developer_tools?/0`).
    """
    use Phoenix.LiveView
    use Gettext, backend: UdinBilling.Gettext

    import UdinBilling.Web.Components

    alias UdinBilling.{Admin, Config, Plan}
    alias UdinBilling.Web.PlanForm

    @impl true
    def mount(_params, _session, socket) do
      actor = socket.assigns.ub_actor
      {:ok, catalog} = Admin.list_features(actor)
      {:ok, plans} = Admin.list_plans(actor)

      {:ok,
       assign(socket,
         catalog: catalog,
         plans_by_id: Map.new(plans, &{&1.id, &1}),
         giftable: Enum.filter(plans, &(&1.kind == :one_time and &1.status == :active)),
         gift_error: nil,
         searchable: Config.user_search() != nil,
         user_label: nil,
         matches: []
       )}
    end

    @impl true
    def handle_params(params, _uri, socket) do
      {:noreply,
       socket
       |> assign(query: params["q"] || params["user_id"] || "", matches: [])
       |> find(params)}
    end

    # An id goes straight to the user, so support links keep working. Anything else goes
    # to the app's search when it has one, otherwise it's checked as an id and explained.
    @impl true
    def handle_event("lookup", %{"query" => query}, socket) do
      query = String.trim(query)

      params =
        if socket.assigns.searchable and not uuid?(query),
          do: [q: query],
          else: [user_id: query]

      {:noreply, push_patch(socket, to: page_path(socket, "/users?" <> URI.encode_query(params)))}
    end

    # "Give a plan" is a developer tool: refused when the tools are off, even if the
    # event is sent without the form on the page.
    def handle_event("gift", _params, %{assigns: %{ub_dev_tools: false}} = socket),
      do:
        {:noreply,
         put_flash(socket, :error, dgettext("users", "Developer tools are turned off here."))}

    def handle_event("gift", %{"gift" => %{"plan_id" => plan_id, "reason" => reason}}, socket) do
      %{user_id: user_id, ub_actor: actor} = socket.assigns

      with {:reason, reason} when reason != "" <- {:reason, String.trim(reason)},
           {:plan, %{} = plan} <-
             {:plan, Enum.find(socket.assigns.giftable, &(&1.id == plan_id))},
           {:ok, _purchase} <- Admin.grant_plan(user_id, plan.id, reason, actor) do
        {:noreply,
         socket
         |> assign(:gift_error, nil)
         |> lookup(user_id)
         |> put_flash(:info, dgettext("users", "Gave %{code} to this user.", code: plan.code))}
      else
        {:reason, _} ->
          {:noreply,
           assign(socket, :gift_error, dgettext("users", "Write why you are giving this plan."))}

        {:plan, nil} ->
          {:noreply, assign(socket, :gift_error, dgettext("users", "Choose a plan."))}

        {:error, error} ->
          {:noreply, assign(socket, :gift_error, error_text(error, socket.assigns.ub_lang))}
      end
    end

    @impl true
    def render(assigns) do
      ~H"""
      <.shell
        base={@ub_base}
        lang={@ub_lang}
        current={@ub_current}
        dev_tools={@ub_dev_tools}
        active={:users}
        title={dgettext("users", "Users")}
        flash={@flash}
      >
        <p class="ub-muted" id="users-intro">
          {dgettext(
            "users",
            "Look up one user to see what they have now: their counters, their switches and which plans give them. You can also give them a plan for free."
          )}
        </p>

        <form id="user-lookup" phx-submit="lookup" class="ub-inline">
          <.input
            id="user-query"
            name="query"
            label={lookup_label(@searchable)}
            value={@query}
            placeholder={if !@searchable, do: "3f2b9c1e-7a4d-4e10-9b6a-0c5d2e8f1a37"}
            dir="ltr"
            hint={lookup_hint(@searchable)}
            autocomplete="off"
          />
          <.button type="submit" variant="primary">{dgettext("users", "Look up")}</.button>
        </form>

        <p :if={@lookup_error} class="ub-flash ub-flash-error" role="alert">{@lookup_error}</p>

        <div :if={@matches != []} class="ub-card ub-stack" id="user-matches">
          <p class="ub-muted" style="margin: 0">
            {dgettext("users", "Several users match. Choose one.")}
          </p>
          <.link
            :for={match <- @matches}
            patch={href(@ub_lang, @ub_base, "/users?" <> URI.encode_query(user_id: match.id))}
            dir="auto"
          >
            {match.label}
          </.link>
        </div>

        <h2 :if={@overview && @user_label} id="user-label" class="ub-h2" dir="auto">
          {@user_label}
        </h2>

        <div :if={@overview} class="ub-split">
          <div class="ub-stack">
            <h2 class="ub-h2">{dgettext("users", "Counters")}</h2>
            <p class="ub-small ub-muted">
              {dgettext(
                "users",
                "A counter is a number of units the user can spend. Left is what they can still use. Of is how many they got. The last column shows when the units refill or expire."
              )}
            </p>
            <div class="ub-table-wrap">
              <table class="ub-table" id="user-counters">
                <thead>
                  <tr>
                    <th scope="col">{dgettext("users", "Feature")}</th>
                    <th scope="col">{dgettext("users", "Left")}</th>
                    <th scope="col">{dgettext("users", "Of")}</th>
                    <th scope="col">{dgettext("users", "Refills or expires")}</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={{key, balance} <- Enum.sort(@overview.counters)}>
                    <td>{feature_name(@catalog, key)}</td>
                    <td>{amount(balance.remaining)}</td>
                    <td>{amount(balance.limit)}</td>
                    <td class="ub-small">{date(balance.resets_at) || dgettext("users", "No date")}</td>
                  </tr>
                </tbody>
              </table>
            </div>

            <h2 class="ub-h2">{dgettext("users", "Switches on")}</h2>
            <p class="ub-small ub-muted">
              {dgettext("users", "A switch is a feature that is simply on or off for this user.")}
            </p>
            <div class="ub-row">
              <span :if={@overview.switches == []} class="ub-muted">
                {dgettext("users", "None")}
              </span>
              <.badge :for={key <- @overview.switches} tone="good">
                {feature_name(@catalog, key)}
              </.badge>
            </div>

            <h2 class="ub-h2">{dgettext("users", "Granted by")}</h2>
            <p class="ub-small ub-muted">
              {dgettext(
                "users",
                "The plans that give this user their features. Source tells you how they got it: a subscription, a purchase, or the default plan everyone has."
              )}
            </p>
            <div class="ub-table-wrap">
              <table class="ub-table" id="user-sources">
                <thead>
                  <tr>
                    <th scope="col">{dgettext("users", "Plan")}</th>
                    <th scope="col">{dgettext("users", "Source")}</th>
                    <th scope="col">{dgettext("users", "Since")}</th>
                    <th scope="col">{dgettext("users", "Until")}</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={source <- @overview.sources}>
                    <td>{plan_name(@plans_by_id, source.plan_id)}</td>
                    <td>
                      <.badge>{source_label(source)}</.badge>
                    </td>
                    <td class="ub-small">{date(source.anchor) || dgettext("users", "No date")}</td>
                    <td class="ub-small">{date(source.ends_at) || dgettext("users", "No end")}</td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>

          <aside :if={@ub_dev_tools} class="ub-stack">
            <.card>
              <h2 class="ub-h2">{dgettext("users", "Give a plan")}</h2>
              <p class="ub-small ub-muted">
                {dgettext(
                  "users",
                  "A gift adds a one-time plan to this user for free. No payment is taken. It is saved as a purchase of 0 with your name and the reason, and you can't undo it here."
                )}
              </p>
              <.empty
                :if={@giftable == []}
                message={dgettext("users", "No one-time plans on sale to give.")}
              />
              <form :if={@giftable != []} id="gift-form" phx-submit="gift" class="ub-stack">
                <.input
                  id="gift-plan"
                  name="gift[plan_id]"
                  type="select"
                  label={dgettext("users", "Plan")}
                  options={Enum.map(@giftable, &{plan_name(@plans_by_id, &1.id), &1.id})}
                  hint={
                    dgettext(
                      "users",
                      "Only one-time plans on sale are listed. The user gets everything in the plan you choose. For example: %{plan_name}.",
                      plan_name: @ub_examples.plan_name
                    )
                  }
                />
                <.input
                  id="gift-reason"
                  name="gift[reason]"
                  type="textarea"
                  label={dgettext("users", "Reason")}
                  placeholder={dgettext("users", "For example: a sorry for a service problem")}
                  hint={
                    dgettext(
                      "users",
                      "Required. Say why you are giving this plan, so anyone can understand it later."
                    )
                  }
                />
                <p :if={@gift_error} class="ub-error" role="alert">{@gift_error}</p>
                <.button
                  type="submit"
                  variant="primary"
                  data-confirm={dgettext("users", "Give this plan for free?")}
                >
                  {dgettext("users", "Give plan")}
                </.button>
              </form>
            </.card>
          </aside>
        </div>
      </.shell>
      """
    end

    defp page_path(socket, path), do: href(socket.assigns.ub_lang, socket.assigns.ub_base, path)

    defp lookup_label(true), do: dgettext("users", "Find a user")
    defp lookup_label(false), do: dgettext("users", "User id")

    defp lookup_hint(true),
      do:
        dgettext(
          "users",
          "Paste the user's id, or type what your app lets you search by, such as a phone number or an email. Spaces around it are ignored."
        )

    defp lookup_hint(false),
      do:
        dgettext(
          "users",
          "Paste the user's id from your app. It is a long code with dashes. Spaces around it are ignored."
        )

    defp uuid?(text), do: match?({:ok, _}, Ecto.UUID.cast(text))

    defp find(socket, %{"user_id" => user_id}) when user_id not in [nil, ""],
      do: lookup(socket, user_id)

    defp find(socket, %{"q" => query}) when query not in [nil, ""], do: search(socket, query)
    defp find(socket, _params), do: lookup(socket, nil)

    # One match opens the user, several are listed (see the matches card), none is said.
    defp search(socket, query) do
      case Admin.search_users(query, socket.assigns.ub_actor) do
        {:ok, [%{id: user_id}]} ->
          lookup(socket, user_id)

        {:ok, []} ->
          assign(socket,
            user_id: nil,
            overview: nil,
            lookup_error: dgettext("users", "No user found for %{query}.", query: query)
          )

        {:ok, matches} ->
          assign(socket, user_id: nil, overview: nil, matches: matches, lookup_error: nil)

        {:error, :not_configured} ->
          lookup(socket, query)

        {:error, error} ->
          assign(socket,
            user_id: nil,
            overview: nil,
            lookup_error: error_text(error, socket.assigns.ub_lang)
          )
      end
    end

    defp lookup(socket, user_id) when user_id in [nil, ""],
      do: assign(socket, user_id: nil, overview: nil, lookup_error: nil)

    defp lookup(socket, user_id) do
      actor = socket.assigns.ub_actor

      with {:ok, uuid} <- Ecto.UUID.cast(user_id),
           {:ok, overview} <- Admin.user_overview(uuid, actor),
           {:ok, labels} <- Admin.user_labels([uuid], actor) do
        assign(socket,
          user_id: uuid,
          overview: overview,
          user_label: labels[uuid],
          lookup_error: nil
        )
      else
        :error ->
          assign(socket,
            user_id: nil,
            overview: nil,
            lookup_error: dgettext("users", "That isn't a valid user id.")
          )

        {:error, error} ->
          assign(socket,
            user_id: nil,
            overview: nil,
            lookup_error: error_text(error, socket.assigns.ub_lang)
          )
      end
    end

    defp feature_name(catalog, key) do
      case Enum.find(catalog, &(&1.key == key)) do
        nil ->
          key

        feature ->
          Plan.localized(feature, :name, Config.default_locale()) || PlanForm.humanize(key)
      end
    end

    defp plan_name(plans_by_id, plan_id) do
      case plans_by_id[plan_id] do
        nil -> dgettext("users", "Unknown plan")
        plan -> Plan.localized(plan, :name, Config.default_locale()) || plan.code
      end
    end

    defp source_label(%{subscription_id: id}) when not is_nil(id),
      do: dgettext("users", "Subscription")

    defp source_label(%{purchase_id: id}) when not is_nil(id), do: dgettext("users", "Purchase")
    defp source_label(_source), do: dgettext("users", "Default plan")

    defp amount(:unlimited), do: "∞ " <> dgettext("users", "Unlimited")
    defp amount(count), do: Integer.to_string(count)

    defp date(nil), do: nil

    defp date(%DateTime{} = at),
      do: dgettext("users", "%{date} UTC", date: Calendar.strftime(at, "%Y-%m-%d %H:%M"))

    defp error_text(:forbidden, _lang), do: dgettext("users", "You don't have access.")

    defp error_text(error, lang),
      do: error |> error_messages(lang) |> Map.values() |> Enum.join(", ")
  end
end

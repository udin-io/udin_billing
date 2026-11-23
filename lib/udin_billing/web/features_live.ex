if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule UdinBilling.Web.FeaturesLive do
    @moduledoc """
    The feature catalog: every switch (on/off) and counter (units per cycle) plans can
    include, with their names in every language.

    ## What an admin can do here
      * Add a feature before the app uses it (e.g. `household`), so plans can include it
        ahead of launch.
      * Rename a feature in each language. Its key and kind are fixed once created: the
        app's code and existing plans refer to them.
      * Delete a feature no plan uses (the catalog refuses otherwise and says so).
      * See which plans include each feature.

    The add/edit form opens on `/features/new` and `/features/:id/edit` (live actions on
    this page), so it can be linked to and the browser's back button closes it.
    """
    use Phoenix.LiveView
    use Gettext, backend: UdinBilling.Gettext

    on_mount {UdinBilling.Web.Auth, :developer_tools}

    import UdinBilling.Web.Components

    alias UdinBilling.{Admin, Config, Plan}
    alias UdinBilling.Web.FeatureForm

    @impl true
    def mount(_params, _session, socket) do
      {:ok,
       socket
       |> assign(locales: Config.locales(), required: Config.required_features(), errors: %{})
       |> load()}
    end

    @impl true
    def handle_params(params, _uri, socket) do
      {:noreply, open(socket, socket.assigns.live_action, params)}
    end

    @impl true
    def handle_event("validate", %{"feature" => submitted}, socket) do
      {:noreply, assign(socket, :params, Map.merge(socket.assigns.params, submitted))}
    end

    def handle_event("save", %{"feature" => submitted}, socket) do
      params = Map.merge(socket.assigns.params, submitted)
      feature = socket.assigns.feature

      with {:ok, attrs} <- FeatureForm.to_attrs(params, feature == nil),
           {:ok, saved} <- persist(feature, attrs, socket.assigns.ub_actor) do
        {:noreply,
         socket
         |> load()
         |> put_flash(:info, dgettext("features", "Saved %{key}.", key: saved.key))
         |> push_patch(to: page_path(socket, "/features"))}
      else
        {:error, errors} when is_map(errors) and not is_struct(errors) ->
          {:noreply, assign(socket, params: params, errors: errors)}

        {:error, error} ->
          {:noreply, assign(socket, params: params, errors: errors_for(error, socket))}
      end
    end

    def handle_event("delete", %{"id" => id}, socket) do
      actor = socket.assigns.ub_actor

      case Enum.find(socket.assigns.catalog, &(&1.id == id)) do
        nil ->
          {:noreply,
           put_flash(socket, :error, dgettext("features", "That feature no longer exists."))}

        feature ->
          case Admin.delete_feature(feature, actor) do
            :ok ->
              {:noreply,
               socket
               |> load()
               |> put_flash(:info, dgettext("features", "Deleted %{key}.", key: feature.key))}

            {:error, error} ->
              message = error |> errors_for(socket) |> Map.values() |> Enum.join(", ")

              {:noreply,
               put_flash(
                 socket,
                 :error,
                 dgettext("features", "Couldn't delete %{key}: %{message}",
                   key: feature.key,
                   message: message
                 )
               )}
          end
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
        active={:features}
        title={dgettext("features", "Features")}
        flash={@flash}
      >
        <:actions>
          <.button variant="primary" patch={href(@ub_lang, @ub_base, "/features/new")}>
            {dgettext("features", "New feature")}
          </.button>
        </:actions>

        <p class="ub-muted" id="features-intro">
          {dgettext(
            "features",
            "Features are what your plans can give a buyer. A feature is either a switch (on or off) or a counter (a number of units that refill)."
          )}
          {dgettext("features", "Add a feature here first, then include it in a plan.")}
        </p>

        <.card :if={@live_action in [:new, :edit]} id="feature-form-card">
          <h2 :if={@feature} class="ub-h2">
            {dgettext("features", "Edit %{key}", key: @feature.key)}
          </h2>
          <h2 :if={!@feature} class="ub-h2">{dgettext("features", "New feature")}</h2>
          <p
            :for={{key, message} <- @errors}
            :if={key not in placed()}
            class="ub-flash ub-flash-error"
            role="alert"
          >
            {message}
          </p>
          <form
            id="feature-form"
            phx-change="validate"
            phx-submit="save"
            class="ub-stack"
            style="margin-top: 12px"
            novalidate
          >
            <div class="ub-fieldset-body" style="margin: 0">
              <.input
                id="feature-key"
                name="feature[key]"
                label={dgettext("features", "Key")}
                value={@params["key"]}
                error={@errors["key"]}
                readonly={@feature != nil}
                dir="ltr"
                hint={key_hint(@feature, @ub_examples)}
                autocomplete="off"
              />
              <.input
                id="feature-kind"
                name="feature[kind]"
                type="select"
                label={dgettext("features", "Kind")}
                options={FeatureForm.kind_options()}
                value={@params["kind"]}
                error={@errors["kind"]}
                disabled={@feature != nil}
                hint={kind_hint(@feature, @ub_examples)}
              />
              <.input
                id="feature-sort"
                name="feature[sort_order]"
                type="number"
                label={dgettext("features", "Display order")}
                value={@params["sort_order"]}
                hint={
                  dgettext(
                    "features",
                    "A number that sets the order in lists. Lower numbers come first. For example: 1 shows before 2."
                  )
                }
              />
            </div>
            <p class="ub-hint">
              {dgettext(
                "features",
                "The name is what buyers see in each language. For example: %{feature}.",
                feature: @ub_examples.feature
              )}
            </p>
            <.translations_input
              field={:name}
              form="feature"
              label={dgettext("features", "Name")}
              values={@params["name"]}
              errors={@errors}
              required
            />
            <p class="ub-hint">
              {dgettext(
                "features",
                "The description is one short sentence that says what the feature gives. For example: %{amount} %{feature} to use each month.",
                amount: @ub_examples.amount,
                feature: @ub_examples.feature
              )}
            </p>
            <.translations_input
              field={:description}
              form="feature"
              label={dgettext("features", "Description")}
              values={@params["description"]}
              errors={@errors}
              multiline
            />
            <div class="ub-row">
              <.button
                type="submit"
                variant="primary"
                phx-disable-with={dgettext("features", "Saving…")}
              >
                {if @feature,
                  do: dgettext("features", "Save changes"),
                  else: dgettext("features", "Add feature")}
              </.button>
              <.button patch={href(@ub_lang, @ub_base, "/features")}>
                {dgettext("features", "Cancel")}
              </.button>
            </div>
          </form>
        </.card>

        <.empty
          :if={@catalog == []}
          message={
            dgettext(
              "features",
              "No features yet. Add the switches and counters your plans will include."
            )
          }
        />

        <div :if={@catalog != []} class="ub-table-wrap">
          <table class="ub-table" id="features">
            <thead>
              <tr>
                <th scope="col">{dgettext("features", "Key")}</th>
                <th scope="col">{dgettext("features", "Kind")}</th>
                <th scope="col">{dgettext("features", "Name")}</th>
                <th scope="col">{dgettext("features", "Included in")}</th>
                <th scope="col"><span class="ub-muted">{dgettext("features", "Actions")}</span></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={feature <- @catalog} id={"feature-#{feature.key}"}>
                <td>
                  <span class="ub-mono" dir="ltr">{feature.key}</span>
                  <.badge :if={feature.key in @required} tone="warn">
                    {dgettext("features", "Used by code")}
                  </.badge>
                </td>
                <td>
                  <.badge tone={if feature.kind == :counter, do: "accent", else: "neutral"}>
                    {kind_label(feature.kind)}
                  </.badge>
                </td>
                <td><.translated texts={feature.name} /></td>
                <td>
                  <span :if={@usage[feature.key] == []} class="ub-muted">
                    {dgettext("features", "No plans")}
                  </span>
                  <span
                    :for={plan <- @usage[feature.key] || []}
                    class="ub-badge ub-badge-neutral"
                    style="margin: 2px"
                  >
                    {Plan.localized(plan, :name, Config.default_locale())}
                  </span>
                </td>
                <td>
                  <div class="ub-row" style="gap: 4px">
                    <.button
                      variant="ghost"
                      patch={href(@ub_lang, @ub_base, "/features/#{feature.id}/edit")}
                    >
                      {dgettext("features", "Edit")}
                    </.button>
                    <.button
                      :if={@usage[feature.key] == [] and feature.key not in @required}
                      variant="ghost"
                      phx-click="delete"
                      phx-value-id={feature.id}
                      data-confirm={
                        dgettext(
                          "features",
                          "Delete %{key}? This can't be undone. Your app's code may still use it.",
                          key: feature.key
                        )
                      }
                    >
                      {dgettext("features", "Delete")}
                    </.button>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
        <div :if={@catalog != []} class="ub-stack">
          <p class="ub-small ub-muted">
            {dgettext(
              "features",
              "Delete removes the feature from this list only. It can't be undone, and it does not change your app's code. A feature can only be deleted when no plan includes it."
            )}
          </p>
          <p class="ub-small ub-muted">
            {dgettext(
              "features",
              "Used by code means your app's code checks this feature, so it can't be deleted."
            )}
          </p>
          <p class="ub-small ub-muted">
            {dgettext("features", "A name that is not filled in shows as")}
            <.badge tone="warn">{dgettext("features", "missing")}</.badge>. {dgettext(
              "features",
              "These languages are required: %{languages}.",
              languages: Enum.map_join(@locales, ", ", &language/1)
            )}
          </p>
        </div>
      </.shell>
      """
    end

    defp kind_label(:counter), do: dgettext("features", "Counter")
    defp kind_label(:switch), do: dgettext("features", "Switch")

    defp key_hint(nil, examples) do
      dgettext(
        "features",
        "Lowercase letters, numbers and underscores. Your app's code uses it, and it can't change after you save. For example: %{feature_key}",
        feature_key: examples.feature_key
      )
    end

    defp key_hint(_feature, _examples) do
      dgettext(
        "features",
        "Your app's code uses this key, so it can't be changed. To use another key, add a new feature."
      )
    end

    defp kind_hint(nil, examples) do
      dgettext(
        "features",
        "A switch is on or off. A counter is a number of units that refill, for example %{amount} %{feature} each month. This can't change after you save.",
        amount: examples.amount,
        feature: examples.feature
      )
    end

    defp kind_hint(_feature, _examples) do
      dgettext("features", "The kind can't be changed, because plans already depend on it.")
    end

    defp errors_for(:forbidden, _socket),
      do: %{"base" => dgettext("features", "You don't have access.")}

    defp errors_for(error, socket), do: error_messages(error, socket.assigns.ub_lang)

    defp page_path(socket, path), do: href(socket.assigns.ub_lang, socket.assigns.ub_base, path)

    defp open(socket, :new, _params),
      do: assign(socket, feature: nil, params: FeatureForm.from_feature(nil), errors: %{})

    defp open(socket, :edit, %{"id" => id}) do
      case Enum.find(socket.assigns.catalog, &(&1.id == id)) do
        nil ->
          socket
          |> put_flash(:error, dgettext("features", "That feature doesn't exist."))
          |> push_patch(to: page_path(socket, "/features"))

        feature ->
          assign(socket, feature: feature, params: FeatureForm.from_feature(feature), errors: %{})
      end
    end

    defp open(socket, :index, _params), do: assign(socket, feature: nil, params: %{}, errors: %{})

    defp load(socket) do
      actor = socket.assigns.ub_actor
      {:ok, catalog} = Admin.list_features(actor)
      {:ok, plans} = Admin.list_plans(actor)

      usage =
        Map.new(catalog, fn feature ->
          {feature.key,
           Enum.filter(plans, &(Map.get(&1.features, feature.key) not in [nil, false, 0]))}
        end)

      assign(socket, catalog: catalog, usage: usage)
    end

    defp persist(nil, attrs, actor), do: Admin.create_feature(attrs, actor)
    defp persist(feature, attrs, actor), do: Admin.update_feature(feature, attrs, actor)

    # Error keys that have an input of their own; anything else shows above the form.
    defp placed do
      ~w(key kind) ++
        for(field <- ~w(name description), locale <- Config.locales(), do: "#{field}.#{locale}")
    end
  end
end

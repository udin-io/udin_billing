if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule UdinBilling.Web.CatalogLive do
    @moduledoc """
    Moves the billing setup between environments from the dashboard: copy the current
    features and plans out as a catalog file, or paste one in, preview exactly what it
    would change, and apply it.

    Same rules as `mix udin_billing.catalog.import` (see `UdinBilling.Catalog`): matched by
    feature key and plan code, all or nothing, never deletes. Preview first, then apply;
    applying re-checks the pasted text, so a preview can't go stale silently.

    Every text is in the `catalog` gettext domain. The problems of a file come from the
    library in English: known ones are translated here, unknown ones are shown as they are.
    """
    use Phoenix.LiveView
    use Gettext, backend: UdinBilling.Gettext

    on_mount {UdinBilling.Web.Auth, :developer_tools}

    import UdinBilling.Web.Components

    alias UdinBilling.Admin

    @impl true
    def mount(_params, _session, socket) do
      {:ok,
       socket
       |> assign(json: "", preview: nil, errors: [], deactivate_missing: false)
       |> load_export()}
    end

    # The dashboard patches the address to drop `?lang=` after opening, which needs this
    # callback. The page has no state in the address, so there is nothing to read.
    @impl true
    def handle_params(_params, _uri, socket), do: {:noreply, socket}

    @impl true
    def handle_event("preview", %{"catalog" => params}, socket) do
      socket = assign_input(socket, params)

      case Admin.import_catalog(socket.assigns.json, socket.assigns.ub_actor, dry_run: true) do
        {:ok, changes} ->
          {:noreply, assign(socket, preview: changes, errors: changes.errors)}

        {:error, reasons} ->
          {:noreply, assign(socket, preview: nil, errors: reasons(reasons, socket))}
      end
    end

    def handle_event("apply", _params, socket) do
      %{json: json, ub_actor: actor, deactivate_missing: deactivate?} = socket.assigns

      case Admin.import_catalog(json, actor, deactivate_missing: deactivate?) do
        {:ok, changes} ->
          {:noreply,
           socket
           |> assign(json: "", preview: nil, errors: [])
           |> load_export()
           |> put_flash(:info, applied_message(count(changes)))}

        {:error, reasons} ->
          {:noreply, assign(socket, errors: reasons(reasons, socket))}
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
        active={:catalog}
        title={gettext("Catalog")}
        flash={@flash}
      >
        <p class="ub-note">
          {dgettext(
            "catalog",
            "Set up features and plans once, then move them to another environment as one file, for example from staging to production, instead of entering them again."
          )}
        </p>
        <p class="ub-hint">
          {dgettext(
            "catalog",
            "Plans and features are matched by plan code and feature key. Nothing is ever deleted."
          )}
        </p>

        <div class="ub-split">
          <.card class="ub-stack">
            <h2 class="ub-h2">{dgettext("catalog", "Import")}</h2>
            <p class="ub-hint">
              {dgettext(
                "catalog",
                "Paste a catalog file from another environment, preview what changes here, then apply it."
              )}
            </p>
            <form id="catalog-import" phx-submit="preview" class="ub-stack">
              <.input
                id="catalog-json"
                name="catalog[json]"
                type="textarea"
                label={dgettext("catalog", "Catalog file (JSON)")}
                hint={
                  dgettext(
                    "catalog",
                    "Paste the whole file. It is the text from the Export box of the other environment. For example: a file with the plan %{plan_code} adds that plan here if it is new, or updates it if it exists.",
                    @ub_examples
                  )
                }
                value={@json}
                rows="10"
                dir="ltr"
                spellcheck="false"
              />
              <.toggle
                id="catalog-deactivate-missing"
                name="catalog[deactivate_missing]"
                checked={@deactivate_missing}
                label={
                  dgettext(
                    "catalog",
                    "Take plans that aren't in the file off sale (buyers keep them)"
                  )
                }
              />
              <p class="ub-hint" style="margin: 0">
                {dgettext(
                  "catalog",
                  "Leave this off if you only want to add or update plans. Turn it on only when the file is the complete list of plans you want on sale here."
                )}
              </p>
              <p class="ub-hint" style="margin: 0">
                {dgettext(
                  "catalog",
                  "For example: this environment has the plan %{plan_code} and one more plan, and the file only has %{plan_code}. With this on, the other plan goes off sale.",
                  @ub_examples
                )}
              </p>
              <div class="ub-row">
                <.button type="submit">{dgettext("catalog", "Preview changes")}</.button>
              </div>
              <p class="ub-hint" style="margin: 0">
                {dgettext(
                  "catalog",
                  "Preview is a dry run. It checks the file and shows what would change, but it saves nothing."
                )}
              </p>
            </form>

            <div :if={@errors != []} class="ub-flash ub-flash-error" role="alert">
              <p style="margin: 0 0 6px">
                {dgettext("catalog", "Nothing can be applied until these are fixed:")}
              </p>
              <ul class="ub-list">
                <li :for={error <- @errors}>{import_error(error, @ub_lang)}</li>
              </ul>
            </div>

            <div :if={@preview && @errors == []} class="ub-stack" id="catalog-preview">
              <h3 class="ub-h2">{dgettext("catalog", "What will change")}</h3>
              <p class="ub-hint" style="margin: 0">
                {dgettext(
                  "catalog",
                  "Create adds something new. Update changes something that already exists here."
                )}
              </p>
              <.empty
                :if={changed(@preview) == [] and @preview.not_in_file.plans == []}
                message={dgettext("catalog", "This environment already matches the file.")}
              />
              <div :if={changed(@preview) != []} class="ub-table-wrap">
                <table class="ub-table">
                  <thead>
                    <tr>
                      <th scope="col">{dgettext("catalog", "Item")}</th>
                      <th scope="col">{dgettext("catalog", "Change")}</th>
                      <th scope="col">{dgettext("catalog", "Fields")}</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={change <- changed(@preview)}>
                      <td>
                        <span class="ub-inline" style="gap: 6px">
                          <span class="ub-muted">{type_label(change.type)}</span>
                          <span class="ub-mono" dir="ltr">{change.key}</span>
                        </span>
                      </td>
                      <td>
                        <.badge tone={if change.action == :create, do: "good", else: "accent"}>
                          {action_label(change.action)}
                        </.badge>
                      </td>
                      <td class="ub-small" dir="ltr">{Enum.join(change.fields, ", ")}</td>
                    </tr>
                  </tbody>
                </table>
              </div>
              <p
                :if={@preview.not_in_file.plans != [] and @deactivate_missing}
                class="ub-small ub-muted"
              >
                {dgettext(
                  "catalog",
                  "In this environment but not in the file: %{plans}. They will be taken off sale.",
                  plans: Enum.join(@preview.not_in_file.plans, ", ")
                )}
              </p>
              <p
                :if={@preview.not_in_file.plans != [] and not @deactivate_missing}
                class="ub-small ub-muted"
              >
                {dgettext(
                  "catalog",
                  "In this environment but not in the file: %{plans}. They are kept as they are.",
                  plans: Enum.join(@preview.not_in_file.plans, ", ")
                )}
              </p>
              <div
                :if={
                  changed(@preview) != [] or (@deactivate_missing and @preview.not_in_file.plans != [])
                }
                class="ub-stack"
                style="gap: 6px"
              >
                <p class="ub-error" role="note" style="margin: 0">
                  {dgettext(
                    "catalog",
                    "Apply changes the real plans and features of this environment, and buyers can see them. It is all or nothing: if one change fails, nothing is saved. It can't be undone with one click."
                  )}
                </p>
                <div class="ub-row">
                  <.button
                    variant="primary"
                    phx-click="apply"
                    data-confirm={
                      dgettext(
                        "catalog",
                        "Apply these changes to this environment? It can't be undone with one click."
                      )
                    }
                  >
                    {dgettext("catalog", "Apply changes")}
                  </.button>
                </div>
              </div>
            </div>
          </.card>

          <.card class="ub-stack">
            <h2 class="ub-h2">{dgettext("catalog", "Export")}</h2>
            <p class="ub-hint">
              {dgettext(
                "catalog",
                "This environment's features and plans. Copy this text and paste it into the Import box of another environment."
              )}
            </p>
            <p class="ub-hint">
              {dgettext("catalog", "To keep it with your code, save it as this file and commit it:")}
              <span class="ub-mono" dir="ltr">priv/billing/catalog.json</span>
            </p>
            <p class="ub-hint">
              {dgettext("catalog", "Or make the file with this command:")}
              <span class="ub-mono" dir="ltr">mix udin_billing.catalog.export</span>
            </p>
            <textarea
              id="catalog-export"
              class="ub-input ub-mono"
              rows="18"
              readonly
              spellcheck="false"
              dir="ltr"
              aria-label={dgettext("catalog", "Exported catalog file")}
            >{@export}</textarea>
          </.card>
        </div>
      </.shell>
      """
    end

    defp load_export(socket) do
      case Admin.export_catalog(socket.assigns.ub_actor) do
        {:ok, json} ->
          assign(socket, :export, json)

        {:error, error} ->
          reason =
            error |> error_messages(socket.assigns.ub_lang) |> Map.values() |> Enum.join(", ")

          socket
          |> assign(:export, "")
          |> put_flash(:error, dgettext("catalog", "Couldn't export: %{reason}", reason: reason))
      end
    end

    defp assign_input(socket, params) do
      assign(socket,
        json: params["json"] || "",
        deactivate_missing: params["deactivate_missing"] == "true"
      )
    end

    defp changed(%{changes: changes}), do: Enum.reject(changes, &(&1.action == :unchanged))

    defp count(changes), do: length(changed(changes))

    defp applied_message(count) do
      dngettext(
        "catalog",
        "Catalog applied: %{count} change.",
        "Catalog applied: %{count} changes.",
        count
      )
    end

    defp type_label(:feature), do: dgettext("catalog", "feature")
    defp type_label(:plan), do: dgettext("catalog", "plan")

    defp action_label(:create), do: dgettext("catalog", "create")
    defp action_label(:update), do: dgettext("catalog", "update")

    defp reasons(reasons, _socket) when is_list(reasons), do: reasons
    defp reasons(:forbidden, _socket), do: [gettext("You don't have access to billing.")]

    defp reasons(error, socket),
      do: error |> error_messages(socket.assigns.ub_lang) |> Map.values()

    # Problems of the file come from the library in English. The library's general rules
    # are translated by `ErrorText`, the file-specific ones here, and any other is shown
    # as it is.
    defp import_error(message, lang) do
      case UdinBilling.Web.ErrorText.translate(message, lang) do
        ^message -> Gettext.with_locale(UdinBilling.Gettext, lang, fn -> file_error(message) end)
        translated -> translated
      end
    end

    defp file_error(message) do
      Enum.find_value(file_rules(), message, fn {pattern, render} ->
        case Regex.named_captures(pattern, message) do
          nil -> nil
          captures -> render.(captures)
        end
      end)
    end

    defp file_rules do
      [
        {~r/\Anot valid JSON: (?<detail>.*)\z/s,
         &dgettext("catalog", "The file is not valid JSON: %{detail}", detail: &1["detail"])},
        {~r/\Anot a billing catalog: expected "format": "(?<format>.+)"\z/,
         &dgettext(
           "catalog",
           "This is not a billing catalog file. It must contain \"format\": \"%{format}\".",
           format: &1["format"]
         )},
        {~r/\Aunsupported catalog version (?<version>.+)\. This library reads (?<supported>.+)\z/,
         &dgettext(
           "catalog",
           "This catalog file version %{version} is not supported. The supported version is %{supported}.",
           version: &1["version"],
           supported: &1["supported"]
         )},
        {~r/\A(?<place>.+): expected an object\z/,
         &dgettext("catalog", "%{place} must be an object, written with curly braces.",
           place: &1["place"]
         )},
        {~r/\A(?<place>.+): missing or not allowed\z/,
         &dgettext("catalog", "%{place} is missing, or its value is not allowed.",
           place: &1["place"]
         )},
        {~r/\A(?<place>.+): expected a price like "150\.00"\z/,
         &dgettext("catalog", "%{place} must be a price written in quotes, like \"150.00\".",
           place: &1["place"]
         )},
        {~r/\A(?<place>.+): expected texts per language, e\.g\. .+\z/,
         &dgettext("catalog", "%{place} must have one text for each language.",
           place: &1["place"]
         )},
        {~r/\A(?<place>.+): expected provider => product id \(or a list of ids\)\z/,
         &dgettext(
           "catalog",
           "%{place} must give a product id, or a list of ids, for each payment provider.",
           place: &1["place"]
         )},
        {~r/\Afeature (?<key>\S+): kind is (?<current>\S+) and can't change to (?<wanted>\S+)\z/,
         &dgettext(
           "catalog",
           "Feature %{key} is a %{current} here and can't become a %{wanted}.",
           key: &1["key"],
           current: &1["current"],
           wanted: &1["wanted"]
         )},
        {~r/\Afeature (?<key>\S+) is required by the app's code but is in neither the file nor the database\z/,
         &dgettext(
           "catalog",
           "Feature %{key} is needed by the app's code, but it is in neither the file nor this environment.",
           key: &1["key"]
         )}
      ]
    end
  end
end

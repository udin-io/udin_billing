if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule UdinBilling.Web.Auth do
    @moduledoc """
    The dashboard's `on_mount` hook: lets admins in and sends everyone else away.

    Runs on every dashboard mount (first render and websocket connect), after the host's
    own hooks have put the signed-in user in assigns. Admin means
    `UdinBilling.Config.admin?/1` (the app's `:admin_check`), the same check every
    `UdinBilling.Admin` function makes again, so data is protected twice.

    When the app turns the dashboard off (`config :udin_billing, dashboard: false`, read
    at runtime), every page redirects, even for admins.

    On success it assigns `:ub_actor` (the admin, passed to `UdinBilling.Admin`),
    `:ub_base` (the dashboard's mount path, for links), `:ub_dev_tools` (whether the
    developer pages are on, `UdinBilling.Config.developer_tools?/0`), `:ub_lang` (the
    dashboard's language: `?lang=`, else the admin's own, else the app's default),
    `:ub_lang_choice` (a language chosen with `?lang=` for this visit only, never saved),
    `:ub_examples` (examples from the project's catalog for help texts, see
    `UdinBilling.Web.Examples`) and `:ub_current` (the current path and query, for the
    language switch). It also sets the gettext language of the page's process.

    Developer pages (Features, Catalog, Webhooks) also declare
    `on_mount {UdinBilling.Web.Auth, :developer_tools}`, which sends admins back to the
    plans when the developer tools are off.
    """
    use Gettext, backend: UdinBilling.Gettext

    import Phoenix.Component, only: [assign: 3]

    import Phoenix.LiveView,
      only: [
        attach_hook: 4,
        connected?: 1,
        push_navigate: 2,
        push_patch: 2,
        put_flash: 3,
        redirect: 2
      ]

    alias UdinBilling.Config
    alias UdinBilling.Web.Examples

    @doc "Admits admins; halts with a redirect otherwise. `config` comes from the router macro."
    @spec on_mount(map() | :developer_tools, map(), map(), Phoenix.LiveView.Socket.t()) ::
            {:cont | :halt, Phoenix.LiveView.Socket.t()}
    def on_mount(%{actor: key, base: base, unauthorized_redirect: to}, _params, _session, socket) do
      actor = socket.assigns[key]
      # `?lang=` isn't known here yet (the page reads it when its params arrive), so the
      # messages shown before any page opens use the admin's own language.
      lang = own_language(actor)
      Gettext.put_locale(UdinBilling.Gettext, lang)

      cond do
        not Config.dashboard_enabled?() ->
          {:halt,
           socket
           |> put_flash(:error, gettext("The billing dashboard is turned off."))
           |> redirect(to: to)}

        Config.admin?(actor) ->
          {:cont,
           socket
           |> assign(:ub_actor, actor)
           |> assign(:ub_base, base)
           |> assign(:ub_dev_tools, Config.developer_tools?())
           |> assign(:ub_lang, lang)
           |> assign(:ub_current, %{path: base, query: %{}})
           |> attach_hook(:ub_lang, :handle_params, &track_language/3)}

        true ->
          {:halt,
           socket
           |> put_flash(:error, gettext("You don't have access to billing."))
           |> redirect(to: to)}
      end
    end

    def on_mount(:developer_tools, _params, _session, socket) do
      if socket.assigns.ub_dev_tools do
        {:cont, socket}
      else
        {:halt,
         socket
         |> put_flash(:error, gettext("Developer pages are turned off here."))
         |> push_navigate(to: socket.assigns.ub_base)}
      end
    end

    # The dashboard's language for this visit: `?lang=` when it names one of the app's
    # languages, else the choice made earlier in this page's process, else the admin's own
    # language, else the app's default.
    #
    # A choice is only for this visit and never changes the admin's own language: once the
    # page is connected, `lang` is removed from the address (the process remembers it), so
    # reloading or opening the address again is the admin's own language. Links inside the
    # dashboard carry the choice to the next page, which removes it from its address too.
    # The process's gettext language and the examples in the help texts follow the choice.
    defp track_language(params, uri, socket) do
      uri = URI.parse(uri)
      # The first, unconnected render may arrive without the parsed query (it depends on the
      # host's pipeline), so the address itself is read too.
      params = Map.merge(URI.decode_query(uri.query || ""), params)
      explicit = explicit_language(params)
      lang = explicit || socket.assigns[:ub_lang_choice] || own_language(socket.assigns.ub_actor)
      Gettext.put_locale(UdinBilling.Gettext, lang)

      socket =
        socket
        |> assign(:ub_lang, lang)
        |> assign(:ub_lang_choice, explicit || socket.assigns[:ub_lang_choice])
        |> assign(:ub_examples, Examples.build(lang))
        |> assign(:ub_current, %{path: uri.path, query: Map.delete(params, "lang")})

      # The first, unconnected render (a plain GET) can't remember anything: it only shows.
      if explicit && connected?(socket),
        do: {:halt, push_patch(socket, to: address_without_lang(uri, params), replace: true)},
        else: {:cont, socket}
    end

    defp explicit_language(%{"lang" => lang}) when is_binary(lang),
      do: if(lang in Config.locales(), do: lang)

    defp explicit_language(_params), do: nil

    defp address_without_lang(uri, params) do
      case Map.delete(params, "lang") do
        query when query == %{} -> uri.path
        query -> uri.path <> "?" <> URI.encode_query(query)
      end
    end

    defp own_language(actor), do: Config.admin_locale(actor) || Config.default_locale()
  end
end

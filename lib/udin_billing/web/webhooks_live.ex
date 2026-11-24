if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule UdinBilling.Web.WebhooksLive do
    @moduledoc """
    Messages from the app's payment providers, for checking what arrived and
    fixing what didn't apply.

    ## What an admin can do here
      * Filter by status (`?status=failed` by default: the ones needing a human, e.g. a
        payment for an unknown purchase or a wrong amount).
      * Read the error and the verified message.
      * Replay a message after fixing its cause (e.g. adding the missing product id to a
        plan). Replays use the stored, already-verified message and still apply once.

    Every text is in the `webhooks` gettext domain. The raw message, ids and provider
    names are data and stay as they are.
    """
    use Phoenix.LiveView
    use Gettext, backend: UdinBilling.Gettext

    on_mount {UdinBilling.Web.Auth, :developer_tools}

    import UdinBilling.Web.Components

    alias UdinBilling.Admin

    @statuses %{
      "failed" => :failed,
      "received" => :received,
      "processed" => :processed,
      "ignored" => :ignored
    }
    @page_size 50

    @impl true
    def mount(_params, _session, socket), do: {:ok, socket}

    @impl true
    def handle_params(params, _uri, socket) do
      status = if Map.has_key?(@statuses, params["status"]), do: params["status"], else: "failed"

      {:noreply,
       socket |> assign(status: status, statuses: ~w(failed received processed ignored)) |> load()}
    end

    @impl true
    def handle_event("replay", %{"id" => id}, socket) do
      case Admin.replay_provider_event(id, socket.assigns.ub_actor) do
        {:ok, outcome} ->
          {:noreply, socket |> load() |> put_flash(outcome_kind(outcome), outcome_text(outcome))}

        {:error, error} ->
          reason = error_text(error, socket.assigns.ub_lang)

          {:noreply,
           socket
           |> load()
           |> put_flash(:error, dgettext("webhooks", "Replay failed: %{reason}", reason: reason))}
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
        active={:webhooks}
        title={gettext("Webhooks")}
        flash={@flash}
      >
        <p class="ub-note">
          {dgettext(
            "webhooks",
            "Payment providers send a message each time something happens, such as a payment or a refund. Check here that each message was applied, and fix the ones that were not."
          )}
        </p>

        <div class="ub-stack" style="gap: 4px">
          <div class="ub-seg" role="group" aria-label={dgettext("webhooks", "Status")}>
            <.link
              :for={status <- @statuses}
              patch={href(@ub_lang, @ub_base, "/webhooks?status=#{status}")}
              class={["ub-seg-link", @status == status && "is-active"]}
              aria-current={@status == status && "true"}
            >
              {status_label(status)}
            </.link>
          </div>
          <p class="ub-hint" id="status-help" style="margin: 0">{status_help(@status)}</p>
        </div>

        <details class="ub-details" id="webhooks-guide">
          <summary>{dgettext("webhooks", "What do the statuses and columns mean?")}</summary>
          <ul class="ub-list">
            <li :for={status <- @statuses}>
              <strong>{status_label(status)}</strong>: {status_help(status)}
            </li>
            <li>
              {dgettext(
                "webhooks",
                "Reference: the purchase or customer the message is about, as the provider names it."
              )}
            </li>
            <li>
              {dgettext(
                "webhooks",
                "Details: the error if there was one, and the saved message exactly as the provider sent it."
              )}
            </li>
            <li>
              {dgettext(
                "webhooks",
                "Replay: applies the saved message again, as if the provider had just sent it. Use it after you fix the cause. A message that was already applied is never applied twice."
              )}
            </li>
          </ul>
          <p class="ub-hint">
            {dgettext(
              "webhooks",
              "For example: a payment arrives for a plan the app does not know. Add the provider id to the plan %{plan_code}, then replay the message.",
              @ub_examples
            )}
          </p>
        </details>

        <.empty
          :if={@events == []}
          message={dgettext("webhooks", "No %{status} messages.", status: status_label(@status))}
        />

        <div :if={@events != []} class="ub-table-wrap">
          <table class="ub-table" id="provider-events">
            <thead>
              <tr>
                <th scope="col">{dgettext("webhooks", "Received")}</th>
                <th scope="col">{dgettext("webhooks", "Provider")}</th>
                <th scope="col">{dgettext("webhooks", "Type")}</th>
                <th scope="col">{dgettext("webhooks", "Status")}</th>
                <th scope="col">{dgettext("webhooks", "Reference")}</th>
                <th scope="col">{dgettext("webhooks", "Details")}</th>
                <th scope="col">
                  <span class="ub-muted">{dgettext("webhooks", "Actions")}</span>
                </th>
              </tr>
            </thead>
            <tbody>
              <tr :for={event <- @events} id={"event-#{event.id}"}>
                <td class="ub-small" dir="ltr">
                  {Calendar.strftime(event.inserted_at, "%Y-%m-%d %H:%M")}
                </td>
                <td>{event.provider}</td>
                <td>{type_label(event.event_type)}</td>
                <td>
                  <.badge tone={tone(event.status)}>{status_label(event.status)}</.badge>
                </td>
                <td class="ub-mono" dir="ltr">{event.reference || dgettext("webhooks", "none")}</td>
                <td>
                  <p :if={event.error} class="ub-error" style="margin: 0">
                    {translated_error(event.error, @ub_lang)}
                  </p>
                  <details class="ub-details">
                    <summary>
                      {dngettext(
                        "webhooks",
                        "Saved message, tried %{count} time",
                        "Saved message, tried %{count} times",
                        event.attempts
                      )}
                    </summary>
                    <pre class="ub-pre ub-mono" dir="ltr">{Jason.encode!(event.event, pretty: true)}</pre>
                  </details>
                </td>
                <td>
                  <.button
                    :if={event.status in [:failed, :received]}
                    variant="ghost"
                    phx-click="replay"
                    phx-value-id={event.id}
                    data-confirm={
                      dgettext(
                        "webhooks",
                        "Apply this message again? It can change payments and access, so read the error first. A message that was already applied is not applied twice."
                      )
                    }
                  >
                    {dgettext("webhooks", "Replay")}
                  </.button>
                  <p :if={event.status in [:failed, :received]} class="ub-hint" style="margin: 0">
                    {dgettext("webhooks", "Applies the message again.")}
                  </p>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
        <p :if={length(@events) == @page_size} class="ub-small ub-muted">
          {dngettext(
            "webhooks",
            "Showing the newest %{count} message.",
            "Showing the newest %{count} messages.",
            @page_size
          )}
        </p>
      </.shell>
      """
    end

    defp load(socket) do
      filters = [status: Map.fetch!(@statuses, socket.assigns.status)]

      case Admin.list_provider_events(socket.assigns.ub_actor, filters, page: [limit: @page_size]) do
        {:ok, %{results: events}} ->
          assign(socket, events: events, page_size: @page_size)

        {:error, error} ->
          socket
          |> assign(events: [], page_size: @page_size)
          |> put_flash(
            :error,
            dgettext("webhooks", "Couldn't load messages: %{reason}",
              reason: error_text(error, socket.assigns.ub_lang)
            )
          )
      end
    end

    defp tone(:failed), do: "bad"
    defp tone(:processed), do: "good"
    defp tone(:received), do: "warn"
    defp tone(_status), do: "neutral"

    defp status_label("failed"), do: status_label(:failed)
    defp status_label("received"), do: status_label(:received)
    defp status_label("processed"), do: status_label(:processed)
    defp status_label("ignored"), do: status_label(:ignored)
    defp status_label(:failed), do: dgettext("webhooks", "failed")
    defp status_label(:received), do: dgettext("webhooks", "received")
    defp status_label(:processed), do: dgettext("webhooks", "processed")
    defp status_label(:ignored), do: dgettext("webhooks", "ignored")

    defp status_help(status) when is_binary(status),
      do: status_help(String.to_existing_atom(status))

    defp status_help(:failed),
      do:
        dgettext(
          "webhooks",
          "The message arrived but could not be applied, for example a payment for an unknown purchase or with a wrong amount. A person needs to look at it."
        )

    defp status_help(:received),
      do:
        dgettext(
          "webhooks",
          "The message arrived but was not finished. It may still be waiting, or it stopped halfway. You can replay it."
        )

    defp status_help(:processed),
      do: dgettext("webhooks", "The message was applied. There is nothing to do.")

    defp status_help(:ignored),
      do:
        dgettext(
          "webhooks",
          "The message is about something this app does not use, so it was skipped on purpose. There is nothing to do."
        )

    defp type_label(:payment_succeeded), do: dgettext("webhooks", "Payment succeeded")
    defp type_label(:payment_failed), do: dgettext("webhooks", "Payment failed")
    defp type_label(:refunded), do: dgettext("webhooks", "Refunded")
    defp type_label(:customer_changed), do: dgettext("webhooks", "Customer changed")
    defp type_label(:ignored), do: dgettext("webhooks", "Other")

    defp outcome_kind(:failed), do: :error
    defp outcome_kind(_outcome), do: :info

    defp outcome_text(:processed), do: dgettext("webhooks", "Replayed. The message was applied.")

    defp outcome_text(:ignored),
      do: dgettext("webhooks", "Replayed. The message was skipped on purpose.")

    defp outcome_text(:duplicate),
      do: dgettext("webhooks", "Nothing changed. This message was already applied before.")

    defp outcome_text(:failed),
      do:
        dgettext(
          "webhooks",
          "Replayed, but it still can't be applied. Read the error and fix its cause first."
        )

    defp outcome_text(outcome),
      do: dgettext("webhooks", "Replayed: %{outcome}.", outcome: inspect(outcome))

    defp translated_error(error, lang), do: UdinBilling.Web.ErrorText.translate_all(error, lang)

    defp error_text(error, lang),
      do: error |> error_messages(lang) |> Map.values() |> Enum.join(", ")
  end
end

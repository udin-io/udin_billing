if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule UdinBilling.Web.PaymentsLive do
    @moduledoc """
    One-time payments, with the ones waiting for a refund first.

    ## Why
    Some money arrives that can't buy anything: a second charge for an order that's
    already paid, or a payment for a checkout that was already cancelled. The library
    keeps each as a `:refund_required` purchase that grants nothing. Admins need to see
    which ones, why, and which provider transaction to refund. Revenue only shows their
    total.

    ## What an admin sees
      * "Needs refund" (default): each payment to refund, with the reason, the provider's
        order and transaction, the user, and for a second charge a link to the payment
        that bought the plan.
      * "All payments": every one-time payment, newest first.
      * A short guide to each case, with an example.

    Refunds are made in the provider's dashboard (Paymob). When the provider reports the
    refund, the payment becomes refunded and leaves "Needs refund" by itself.

    ## Languages
    Every text is in the `payments` gettext domain. The reasons the library stores in the
    database are English (`"Paid twice for the same order. Refund this second payment."`),
    so the two known ones are recognised by their English start and shown translated. Any
    other stored text is shown as it was saved.
    """
    use Phoenix.LiveView
    use Gettext, backend: UdinBilling.Gettext

    import UdinBilling.Web.Components

    alias UdinBilling.{Admin, Plan}

    @views %{"refund" => [status: :refund_required], "all" => []}
    @statuses [:pending, :paid, :failed, :cancelled, :refund_required, :refunded]
    @page_size 50

    @twice_reason "Paid twice for the same order. Refund this second payment."
    @late_reason "Paid after the checkout was cancelled"

    @impl true
    def mount(_params, _session, socket), do: {:ok, assign(socket, :statuses, @statuses)}

    @impl true
    def handle_params(params, _uri, socket) do
      view = if Map.has_key?(@views, params["show"]), do: params["show"], else: "refund"
      {:noreply, socket |> assign(view: view) |> load()}
    end

    @impl true
    def render(assigns) do
      ~H"""
      <.shell
        base={@ub_base}
        lang={@ub_lang}
        current={@ub_current}
        dev_tools={@ub_dev_tools}
        active={:payments}
        title={gettext("Payments")}
        flash={@flash}
      >
        <p class="ub-note">
          {dgettext(
            "payments",
            "Money that users paid for one-time plans. Payments that need a refund come first, so you can return that money in the payment provider's dashboard."
          )}
        </p>

        <.refund_guide examples={@ub_examples} />

        <div class="ub-stack" style="gap: 4px">
          <div class="ub-seg" role="group" aria-label={dgettext("payments", "Payments shown")}>
            <.view_link lang={@ub_lang} base={@ub_base} view="refund" current={@view}>
              {dgettext("payments", "Needs refund")}
            </.view_link>
            <.view_link lang={@ub_lang} base={@ub_base} view="all" current={@view}>
              {dgettext("payments", "All payments")}
            </.view_link>
          </div>
          <p class="ub-hint" style="margin: 0">
            {dgettext(
              "payments",
              "Needs refund shows only the payments waiting for you. All payments shows every one-time payment, newest first."
            )}
          </p>
        </div>

        <.empty
          :if={@payments == [] and @view == "refund"}
          message={dgettext("payments", "Nothing to refund.")}
        />
        <.empty
          :if={@payments == [] and @view == "all"}
          message={dgettext("payments", "No payments yet.")}
        />

        <details :if={@payments != []} class="ub-details" id="payments-columns">
          <summary>{dgettext("payments", "What do the columns and statuses mean?")}</summary>
          <ul class="ub-list">
            <li>{dgettext("payments", "Paid: when the money arrived.")}</li>
            <li>
              {dgettext("payments", "User: the buyer's id. Click it to open their account.")}
            </li>
            <li>
              {dgettext(
                "payments",
                "Amount: what was really paid. It can differ from the plan's price."
              )}
            </li>
            <li>
              {dgettext("payments", "Why: the reason this payment needs your attention.")}
            </li>
            <li>
              {dgettext(
                "payments",
                "Provider order: the checkout at the payment provider. Two payments for one order share it."
              )}
            </li>
            <li>
              {dgettext(
                "payments",
                "Transaction: the id of this one payment at the provider. Use it to find the payment when you refund."
              )}
            </li>
            <li :for={status <- @statuses}>
              <strong>{status_text(status)}</strong>: {status_help(status)}
            </li>
          </ul>
        </details>

        <div :if={@payments != []} class="ub-table-wrap">
          <table class="ub-table" id="payments">
            <thead>
              <tr>
                <th scope="col">{dgettext("payments", "Paid")}</th>
                <th scope="col">{dgettext("payments", "User")}</th>
                <th scope="col">{dgettext("payments", "Plan")}</th>
                <th scope="col">{dgettext("payments", "Amount")}</th>
                <th scope="col">{dgettext("payments", "Status")}</th>
                <th scope="col">{dgettext("payments", "Why")}</th>
                <th scope="col">{dgettext("payments", "Provider order")}</th>
                <th scope="col">{dgettext("payments", "Transaction")}</th>
              </tr>
            </thead>
            <tbody>
              <.payment_row
                :for={payment <- @payments}
                payment={payment}
                user_label={@user_labels[payment.user_id]}
                base={@ub_base}
                lang={@ub_lang}
              />
            </tbody>
          </table>
        </div>
        <p :if={length(@payments) == @page_size} class="ub-small ub-muted">
          {dngettext(
            "payments",
            "Showing the newest %{count} payment.",
            "Showing the newest %{count} payments.",
            @page_size
          )}
        </p>
      </.shell>
      """
    end

    attr :base, :string, required: true
    attr :lang, :string, required: true
    attr :view, :string, required: true
    attr :current, :string, required: true
    slot :inner_block, required: true

    defp view_link(assigns) do
      ~H"""
      <.link
        patch={href(@lang, @base, "/payments?show=#{@view}")}
        class={["ub-seg-link", @current == @view && "is-active"]}
        aria-current={@current == @view && "true"}
      >
        {render_slot(@inner_block)}
      </.link>
      """
    end

    attr :payment, :map, required: true
    attr :user_label, :string, default: nil, doc: "The app's label for the user, else the id"
    attr :base, :string, required: true
    attr :lang, :string, required: true

    defp payment_row(assigns) do
      ~H"""
      <tr id={"payment-#{@payment.id}"}>
        <td class="ub-small" dir="ltr">{date(@payment.paid_at || @payment.inserted_at)}</td>
        <td class={["ub-small", !@user_label && "ub-mono"]} dir="ltr">
          <.link navigate={href(@lang, @base, "/users?user_id=#{@payment.user_id}")}>
            {@user_label || @payment.user_id}
          </.link>
        </td>
        <td>{Plan.localized(@payment.plan, :name, @lang)}</td>
        <td dir="ltr">{amount_paid(@payment)}</td>
        <td>
          <.badge tone={tone(@payment.status)}>{status_text(@payment.status)}</.badge>
        </td>
        <td>
          <p :if={@payment.failure_reason} style="margin: 0">
            {failure_text(@payment.failure_reason)}
          </p>
          <p :if={@payment.refund_reason} class="ub-small ub-muted" style="margin: 0">
            {dgettext("payments", "Refund reason: %{reason}",
              reason: refund_reason_text(@payment.refund_reason)
            )}
          </p>
          <.link
            :if={@payment.duplicate_of_id}
            patch={href(@lang, @base, "/payments?show=all") <> "#payment-#{@payment.duplicate_of_id}"}
            class="ub-small"
          >
            {dgettext("payments", "The payment that bought the plan")}
          </.link>
        </td>
        <td class="ub-mono" dir="ltr">{order_ref(@payment) || dgettext("payments", "none")}</td>
        <td class="ub-mono" dir="ltr">{@payment.payment_ref || dgettext("payments", "none")}</td>
      </tr>
      """
    end

    attr :examples, :map, required: true

    defp refund_guide(assigns) do
      ~H"""
      <.card id="refund-guide">
        <h2 style="margin-top: 0">{dgettext("payments", "Payments that need a refund")}</h2>
        <p class="ub-muted">
          {dgettext(
            "payments",
            "These payments reached us but bought nothing, so the user was charged for nothing."
          )}
        </p>
        <h3 class="ub-h2">{dgettext("payments", "How to refund")}</h3>
        <ol class="ub-list">
          <li>{dgettext("payments", "Find the payment in the table and copy its transaction.")}</li>
          <li>
            {dgettext(
              "payments",
              "Open the payment provider's dashboard and refund that transaction there."
            )}
          </li>
          <li>
            {dgettext(
              "payments",
              "When the provider reports the refund, the row turns refunded by itself. You do not need to change anything here."
            )}
          </li>
        </ol>
        <p class="ub-error" role="note">
          {dgettext(
            "payments",
            "A refund can't be undone. Check the transaction twice, and never refund the payment that bought the plan, or the user loses what they paid for."
          )}
        </p>
        <.refund_case title={dgettext("payments", "Paid twice for the same order")}>
          {dgettext(
            "payments",
            "The user was charged two times for one checkout, for example a double tap on Pay or paying by card and then by wallet. The first payment bought the plan and the second one waits here."
          )}
          <:example>
            {dgettext(
              "payments",
              "For example: order %{order} was paid by transactions %{first} and %{second}. The plan came from %{first}. Refund %{second} only, and the user keeps the plan.",
              order: "217503754",
              first: "192036465",
              second: "192036466"
            )}
          </:example>
        </.refund_case>
        <.refund_case title={dgettext("payments", "Paid after the checkout was cancelled")}>
          {dgettext(
            "payments",
            "The user paid after the checkout had already been cancelled or closed, so the money could not be used to buy the plan."
          )}
          <:example>
            {dgettext(
              "payments",
              "For example: a checkout for %{price} %{currency} was cancelled after an hour, then the user paid anyway. Nothing was given. Refund that payment.",
              @examples
            )}
          </:example>
        </.refund_case>
      </.card>
      """
    end

    attr :title, :string, required: true
    slot :inner_block, required: true
    slot :example, required: true

    defp refund_case(assigns) do
      ~H"""
      <details class="ub-details">
        <summary><strong>{@title}</strong></summary>
        <p>{render_slot(@inner_block)}</p>
        <p class="ub-small ub-muted">{render_slot(@example)}</p>
      </details>
      """
    end

    defp load(socket) do
      filters = Map.fetch!(@views, socket.assigns.view)
      opts = [load: [:plan, :duplicate_of], page: [limit: @page_size]]

      case Admin.list_purchases(socket.assigns.ub_actor, filters, opts) do
        {:ok, %{results: payments}} ->
          # One call to the app for every user on the page, not one per row.
          {:ok, labels} =
            Admin.user_labels(Enum.map(payments, & &1.user_id), socket.assigns.ub_actor)

          assign(socket, payments: payments, user_labels: labels, page_size: @page_size)

        {:error, error} ->
          socket
          |> assign(payments: [], user_labels: %{}, page_size: @page_size)
          |> put_flash(
            :error,
            dgettext("payments", "Couldn't load payments: %{reason}",
              reason: error_text(error, socket.assigns.ub_lang)
            )
          )
      end
    end

    # What was actually paid: kept in metadata when it differs from the price.
    defp amount_paid(%{metadata: %{"paid_amount" => amount, "paid_currency" => currency}}),
      do: "#{amount} #{currency}"

    defp amount_paid(payment),
      do: "#{Decimal.to_string(payment.amount, :normal)} #{payment.currency}"

    # A second charge shares its order with the payment that bought the plan, which holds
    # the order id (one purchase per order id).
    defp order_ref(%{provider_ref: ref}) when is_binary(ref), do: ref
    defp order_ref(%{duplicate_of: %{provider_ref: ref}}), do: ref
    defp order_ref(_payment), do: nil

    defp date(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")

    defp status_text(:pending), do: dgettext("payments", "pending")
    defp status_text(:paid), do: dgettext("payments", "paid")
    defp status_text(:failed), do: dgettext("payments", "failed")
    defp status_text(:cancelled), do: dgettext("payments", "cancelled")
    defp status_text(:refund_required), do: dgettext("payments", "needs refund")
    defp status_text(:refunded), do: dgettext("payments", "refunded")

    defp status_help(:pending),
      do: dgettext("payments", "The user started the checkout but has not paid yet.")

    defp status_help(:paid), do: dgettext("payments", "Paid, and the plan was given.")

    defp status_help(:failed), do: dgettext("payments", "The payment did not go through.")

    defp status_help(:cancelled),
      do: dgettext("payments", "The checkout was closed before any money arrived.")

    defp status_help(:refund_required),
      do: dgettext("payments", "Money arrived but nothing was given. You need to refund it.")

    defp status_help(:refunded),
      do: dgettext("payments", "The money was returned to the user.")

    # The reasons the library saves are English. The two it writes itself are recognised by
    # their start and shown in the admin's language, anything else is shown as saved.
    defp failure_text(@twice_reason), do: dgettext("payments", @twice_reason)

    defp failure_text(@late_reason <> "."),
      do: dgettext("payments", "Paid after the checkout was cancelled.")

    defp failure_text(@late_reason <> ": " <> detail) do
      dgettext("payments", "Paid after the checkout was cancelled: %{detail}",
        detail: String.trim_trailing(detail, ".")
      )
    end

    defp failure_text(stored), do: stored

    # "paymob refund" is what the library saves when a provider reports a refund.
    defp refund_reason_text(stored) do
      case Regex.run(~r/\A(\S+) refund\z/, stored) do
        [_all, provider] -> dgettext("payments", "Refunded by %{provider}", provider: provider)
        nil -> stored
      end
    end

    defp tone(:refund_required), do: "warn"
    defp tone(:paid), do: "good"
    defp tone(:failed), do: "bad"
    defp tone(_status), do: "neutral"

    defp error_text(error, lang),
      do: error |> error_messages(lang) |> Map.values() |> Enum.join(", ")
  end
end

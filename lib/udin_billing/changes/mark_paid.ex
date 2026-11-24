defmodule UdinBilling.Changes.MarkPaid do
  @moduledoc """
  Confirms a purchase whose status is one of `opts[:from]`: pending or failed for an
  on-time payment, cancelled for a late one (see `UdinBilling.Purchases.confirm_payment/2`).

  Checks the provider-reported amount and currency equal the copied price, then sets
  `:paid`, `paid_at` and `access_expires_at` (copied validity from `paid_at`). Units
  aren't created here: they're created when the buyer first spends or checks a balance
  (`UdinBilling.Quotas`), so payment and spending can't drift apart.
  """
  use Ash.Resource.Change

  alias UdinBilling.{Plan, Purchases}

  @impl true
  def change(changeset, opts, _context) do
    from = Keyword.fetch!(opts, :from)
    Ash.Changeset.before_action(changeset, &verify_and_stamp(&1, from))
  end

  defp verify_and_stamp(%{data: purchase} = changeset, from) do
    paid_amount = Ash.Changeset.get_argument(changeset, :paid_amount)
    paid_currency = Ash.Changeset.get_argument(changeset, :paid_currency)

    cond do
      purchase.status not in from ->
        Ash.Changeset.add_error(changeset,
          field: :status,
          message: "purchase is #{purchase.status}"
        )

      not Purchases.amount_matches?(purchase, paid_amount, paid_currency) ->
        Ash.Changeset.add_error(changeset,
          field: :paid_amount,
          message: "paid amount doesn't match the price"
        )

      true ->
        paid_at = Ash.Changeset.get_argument(changeset, :paid_at) || DateTime.utc_now()

        Ash.Changeset.force_change_attributes(changeset,
          status: :paid,
          paid_at: paid_at,
          access_expires_at: Plan.expires_at(purchase, paid_at),
          provider_ref:
            Ash.Changeset.get_argument(changeset, :provider_ref) || purchase.provider_ref,
          payment_ref: Ash.Changeset.get_argument(changeset, :payment_ref)
        )
    end
  end
end

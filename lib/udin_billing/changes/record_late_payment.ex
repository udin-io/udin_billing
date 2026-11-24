defmodule UdinBilling.Changes.RecordLatePayment do
  @moduledoc """
  Records a payment for a cancelled checkout that can't be accepted, without granting
  anything: another amount, no matching checkout reference, or the `:single_active`
  policy (see `UdinBilling.Purchases.confirm_payment/2`).

  ## Why
  Rejecting the webhook would leave the user charged with no record of it. So the
  purchase becomes `:refund_required` with the provider's reference and the amount
  actually paid (in `metadata["paid_amount"]` / `["paid_currency"]`), for an admin or a
  provider refund call to settle with `UdinBilling.refund/2`.
  """
  use Ash.Resource.Change

  @impl true
  def change(%{data: purchase} = changeset, _opts, _context) do
    paid_amount = Ash.Changeset.get_argument(changeset, :paid_amount)
    paid_currency = Ash.Changeset.get_argument(changeset, :paid_currency)

    Ash.Changeset.force_change_attributes(changeset,
      status: :refund_required,
      paid_at: Ash.Changeset.get_argument(changeset, :paid_at) || DateTime.utc_now(),
      provider_ref: Ash.Changeset.get_argument(changeset, :provider_ref) || purchase.provider_ref,
      payment_ref: Ash.Changeset.get_argument(changeset, :payment_ref),
      failure_reason: failure_reason(Ash.Changeset.get_argument(changeset, :reason)),
      metadata:
        Map.merge(purchase.metadata, %{
          "paid_amount" => Decimal.to_string(Decimal.new(paid_amount)),
          "paid_currency" => paid_currency
        })
    )
  end

  defp failure_reason(nil), do: "Paid after the checkout was cancelled."
  defp failure_reason(reason), do: "Paid after the checkout was cancelled: #{reason}."
end

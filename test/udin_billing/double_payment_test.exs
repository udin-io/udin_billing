defmodule UdinBilling.DoublePaymentTest do
  @moduledoc """
  A rider charged twice for one order (a double submit, or card then wallet): the first
  payment buys the plan, the second is kept as its own "refund required" record linked to
  the first, and a refund reaches the payment it names.
  """
  use UdinBilling.DataCase, async: false

  require Ash.Query

  alias UdinBilling.{Admin, Purchases, Quotas, Webhooks}

  @headers %{"x-fake-signature" => "a-long-test-secret-value"}

  setup do
    user = user_fixture()
    plan = plan_fixture()
    {:ok, purchase} = Purchases.start(user.id, plan.id, "fake")
    {:ok, purchase} = Purchases.attach_provider_ref(purchase, "order-#{purchase.id}")
    %{user: user, plan: plan, purchase: purchase}
  end

  defp send_event(purchase, type, transaction, extra \\ %{}) do
    params =
      Map.merge(
        %{
          "event_id" => "#{transaction}:#{type}:#{System.unique_integer([:positive])}",
          "type" => type,
          "provider_ref" => purchase.provider_ref,
          "payment_ref" => transaction,
          "amount" => "150.00",
          "currency" => "EGP"
        },
        extra
      )

    Webhooks.handle("fake", params, @headers)
  end

  defp pay(purchase, transaction), do: send_event(purchase, "payment_succeeded", transaction)
  defp refund(purchase, transaction), do: send_event(purchase, "refunded", transaction)

  defp reload(purchase), do: Ash.get!(Purchase, purchase.id, authorize?: false)
  defp rides_left(user), do: elem(Quotas.balance(user.id, "rides"), 1).remaining

  defp extra_payments(purchase) do
    Purchase
    |> Ash.Query.filter(duplicate_of_id == ^purchase.id)
    |> Ash.read!(authorize?: false)
  end

  test "the first payment is stored with its transaction", %{purchase: purchase} do
    assert {:ok, :processed} = pay(purchase, "tx-1")
    assert %{status: :paid, payment_ref: "tx-1"} = reload(purchase)
  end

  test "a second payment for a paid order is kept for refund and gives nothing", %{
    user: user,
    purchase: purchase
  } do
    {:ok, :processed} = pay(purchase, "tx-1")

    ref =
      :telemetry_test.attach_event_handlers(self(), [[:udin_billing, :purchase, :refund_required]])

    assert {:ok, :processed} = pay(purchase, "tx-2")

    assert %{status: :paid, payment_ref: "tx-1"} = reload(purchase)
    assert rides_left(user) == 10

    assert [extra] = extra_payments(purchase)
    assert extra.status == :refund_required
    assert extra.payment_ref == "tx-2"
    assert extra.user_id == user.id
    assert extra.failure_reason =~ "twice"
    assert Decimal.equal?(extra.amount, purchase.amount)

    assert_received {[:udin_billing, :purchase, :refund_required], ^ref, _, %{purchase_id: id}}
    assert id == extra.id
  end

  test "the same transaction sent again records nothing new", %{purchase: purchase} do
    {:ok, :processed} = pay(purchase, "tx-1")
    {:ok, :processed} = pay(purchase, "tx-2")

    assert {:ok, :processed} = pay(purchase, "tx-1")
    assert {:ok, :processed} = pay(purchase, "tx-2")

    assert length(extra_payments(purchase)) == 1
  end

  test "refunding the second payment keeps the rider's plan", %{
    user: user,
    purchase: purchase
  } do
    {:ok, :processed} = pay(purchase, "tx-1")
    {:ok, :processed} = pay(purchase, "tx-2")

    assert {:ok, :processed} = refund(purchase, "tx-2")

    assert [%{status: :refunded}] = extra_payments(purchase)
    assert reload(purchase).status == :paid
    assert rides_left(user) == 10
  end

  test "refunding the first payment refunds the plan and leaves the second waiting", %{
    user: user,
    purchase: purchase
  } do
    {:ok, :processed} = pay(purchase, "tx-1")
    {:ok, :processed} = pay(purchase, "tx-2")

    assert {:ok, :processed} = refund(purchase, "tx-1")

    assert reload(purchase).status == :refunded
    assert rides_left(user) == 0
    assert [%{status: :refund_required}] = extra_payments(purchase)
  end

  test "a refund that names no transaction refunds the order's purchase", %{
    purchase: purchase
  } do
    {:ok, :processed} = pay(purchase, "tx-1")

    assert {:ok, :processed} = send_event(purchase, "refunded", nil)
    assert reload(purchase).status == :refunded
  end

  test "a refund can't reach a payment of another order", %{user: user, plan: plan} do
    {:ok, other} = Purchases.start(user.id, plan.id, "fake")
    {:ok, other} = Purchases.attach_provider_ref(other, "order-#{other.id}")
    {:ok, :processed} = pay(other, "tx-other-1")
    {:ok, :processed} = pay(other, "tx-other-2")

    {:ok, mine} = Purchases.start(user.id, plan.id, "fake")
    {:ok, mine} = Purchases.attach_provider_ref(mine, "order-#{mine.id}")
    {:ok, :processed} = pay(mine, "tx-mine")

    # My order's refund naming the other order's second payment.
    assert {:ok, :processed} = refund(mine, "tx-other-2")

    assert [%{status: :refund_required}] = extra_payments(other)
    assert reload(mine).status == :refunded
  end

  test "revenue counts the second payment as money waiting for a refund", %{
    purchase: purchase
  } do
    {:ok, :processed} = pay(purchase, "tx-1")
    {:ok, :processed} = pay(purchase, "tx-2")
    admin = user_fixture(%{admin: true})
    now = DateTime.utc_now()

    assert {:ok, [row]} =
             Admin.revenue(admin, DateTime.add(now, -3600), DateTime.add(now, 3600))

    assert Decimal.equal?(row.gross, 300)
    assert Decimal.equal?(row.awaiting_refund, 150)
    assert Decimal.equal?(row.net, 150)
  end
end

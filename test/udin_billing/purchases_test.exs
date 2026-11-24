defmodule UdinBilling.PurchasesTest do
  use UdinBilling.DataCase, async: false

  alias UdinBilling.{Purchases, Quotas}

  @t0 ~U[2026-11-01 10:00:00.000000Z]

  setup do
    %{user: user_fixture(), plan: plan_fixture()}
  end

  defp left(user, now \\ DateTime.add(@t0, 60)),
    do: elem(Quotas.balance(user.id, "rides", now: now), 1).remaining

  describe "checkout and payment" do
    test "copies the plan's terms; later edits don't change them", %{user: user, plan: plan} do
      {:ok, purchase} = Purchases.start(user.id, plan.id, "fake")
      assert purchase.features == %{"rides" => 10}
      assert {purchase.validity_unit, purchase.validity_count} == {:week, 1}

      plan
      |> Ash.Changeset.for_update(:update, %{
        price: Decimal.new(999),
        features: %{"rides" => 1},
        validity_unit: :day
      })
      |> Ash.update!(authorize?: false)

      {:ok, paid} =
        Purchases.confirm_payment(purchase.id, %{amount: "150.00", currency: "EGP", paid_at: @t0})

      assert paid.access_expires_at == DateTime.add(@t0, 7, :day)
      assert left(user) == 10
    end

    test "is paid exactly once", %{user: user, plan: plan} do
      {:ok, purchase} = Purchases.start(user.id, plan.id, "fake")
      payment = %{amount: plan.price, currency: "EGP", paid_at: @t0}

      assert {:ok, %{status: :paid}} = Purchases.confirm_payment(purchase.id, payment)
      assert {:ok, %{status: :paid}} = Purchases.confirm_payment(purchase.id, payment)
      assert left(user) == 10
    end

    test "a wrong amount or currency changes nothing", %{user: user, plan: plan} do
      {:ok, purchase} = Purchases.start(user.id, plan.id, "fake")

      assert {:error, {:amount_mismatch, _}} =
               Purchases.confirm_payment(purchase.id, %{amount: "1", currency: "EGP"})

      assert {:error, {:amount_mismatch, _}} =
               Purchases.confirm_payment(purchase.id, %{amount: plan.price, currency: "USD"})

      assert {:error, {:amount_mismatch, _}} =
               Purchases.confirm_payment(purchase.id, %{amount: nil, currency: "EGP"})

      assert Ash.get!(Purchase, purchase.id, authorize?: false).status == :pending
    end

    test "a failed payment can still be paid; a cancelled one without its reference is kept", %{
      user: user,
      plan: plan
    } do
      {:ok, failing} = Purchases.start(user.id, plan.id, "fake")
      {:ok, %{status: :failed}} = Purchases.fail(failing.id, "declined")

      assert {:ok, %{status: :paid}} =
               Purchases.confirm_payment(failing.id, %{amount: plan.price, currency: "EGP"})

      {:ok, late} = Purchases.start(user.id, plan.id, "fake")
      {:ok, _} = Purchases.cancel(late.id)

      assert {:ok, %{status: :refund_required, metadata: %{"paid_amount" => "150.00"}}} =
               Purchases.confirm_payment(late.id, %{amount: plan.price, currency: "EGP"})
    end

    test "unknown purchases and plans not for sale are refused", %{user: user} do
      assert {:error, :not_found} =
               Purchases.confirm_payment(Ecto.UUID.generate(), %{amount: 1, currency: "EGP"})

      free = free_plan_fixture()
      inactive = plan_fixture(%{status: :inactive})
      recurring = subscription_plan_fixture()
      assert {:error, _} = Purchases.start(user.id, free.id, "fake")
      assert {:error, _} = Purchases.start(user.id, inactive.id, "fake")
      assert {:error, _} = Purchases.start(user.id, recurring.id, "fake")
    end
  end

  describe "late payments (after the checkout was cancelled)" do
    defp cancelled_checkout(user, plan, ref \\ "order-1") do
      {:ok, purchase} = Purchases.start(user.id, plan.id, "fake")
      {:ok, purchase} = Purchases.attach_provider_ref(purchase, ref)
      {:ok, _} = Purchases.cancel(purchase.id)
      purchase
    end

    defp pay_late(purchase, attrs) do
      payment = Map.merge(%{amount: "150.00", currency: "EGP", paid_at: @t0}, attrs)
      Purchases.confirm_payment(purchase.id, payment)
    end

    test "the same checkout and the full amount: accepted like an on-time payment", %{
      user: user,
      plan: plan
    } do
      purchase = cancelled_checkout(user, plan)

      assert {:ok, paid} = pay_late(purchase, %{provider_ref: "order-1"})

      assert paid.status == :paid
      assert paid.access_expires_at == DateTime.add(@t0, 7, :day)
      assert left(user) == 10
    end

    test "another amount: kept for refund, nothing given", %{user: user, plan: plan} do
      purchase = cancelled_checkout(user, plan)

      assert {:ok, %{status: :refund_required, metadata: %{"paid_amount" => "100"}} = request} =
               pay_late(purchase, %{amount: "100", provider_ref: "order-1"})

      assert request.failure_reason =~ "paid 100 EGP, the price is 150"

      assert left(user) == 0
    end

    test "another checkout's reference, or none: kept for refund", %{user: user, plan: plan} do
      other = cancelled_checkout(user, plan)
      missing = cancelled_checkout(user_fixture(), plan, "order-3")

      assert {:ok, %{status: :refund_required} = request} =
               pay_late(other, %{provider_ref: "order-2"})

      assert request.failure_reason =~ "reference"
      assert {:ok, %{status: :refund_required}} = pay_late(missing, %{})
      assert left(user) == 0
    end

    test "under :single_active: kept for refund, one plan at a time", %{user: user, plan: plan} do
      with_env(:purchase_policy, :single_active, fn ->
        purchase = cancelled_checkout(user, plan)

        assert {:ok, %{status: :refund_required} = request} =
                 pay_late(purchase, %{provider_ref: "order-1"})

        assert request.failure_reason =~ "single_active"
        assert left(user) == 0
      end)
    end

    test "accepted once: a repeat changes nothing", %{user: user, plan: plan} do
      purchase = cancelled_checkout(user, plan)

      assert {:ok, %{status: :paid}} = pay_late(purchase, %{provider_ref: "order-1"})
      assert {:ok, %{status: :paid}} = pay_late(purchase, %{provider_ref: "order-1"})
      assert left(user) == 10
    end
  end

  describe "refunds" do
    test "end access, revoke unused units, keep history and the original end date", %{
      user: user,
      plan: plan
    } do
      purchase = paid_purchase_fixture(user, plan, paid_at: @t0)
      {:ok, _} = Quotas.consume(user.id, "rides", reference: "b1", now: DateTime.add(@t0, 60))

      assert {:ok, refunded} = Purchases.refund(purchase.id, "chargeback")

      assert refunded.status == :refunded and
               refunded.access_expires_at == purchase.access_expires_at

      assert left(user, DateTime.add(@t0, 120)) == 0
      assert [_] = Ash.read!(Usage, authorize?: false)
      assert {:ok, %{status: :refunded}} = Purchases.refund(purchase.id, "again")
    end

    test "never-paid purchases can't be refunded", %{user: user, plan: plan} do
      {:ok, pending} = Purchases.start(user.id, plan.id, "fake")
      assert {:error, {:purchase_not_refundable, :pending}} = Purchases.refund(pending.id, "x")
    end
  end

  describe "record_paid (store top-ups, gifts)" do
    test "records once per provider reference", %{user: user, plan: plan} do
      assert {:ok, first} =
               Purchases.record_paid(user.id, plan.id, "store", "txn-1", paid_at: @t0)

      assert {:ok, again} =
               Purchases.record_paid(user.id, plan.id, "store", "txn-1", paid_at: @t0)

      assert first.id == again.id and first.status == :paid
      assert left(user) == 10
    end

    test "a gift has amount 0 and works like a purchase", %{user: user, plan: plan} do
      assert {:ok, gift} =
               Purchases.record_paid(user.id, plan.id, "admin", "gift-1",
                 amount: Decimal.new(0),
                 paid_at: @t0
               )

      assert Decimal.equal?(gift.amount, 0)
      assert left(user) == 10
    end
  end

  describe "abandoned checkouts" do
    test "cancel_stale cancels only old pending ones", %{user: user, plan: plan} do
      {:ok, pending} = Purchases.start(user.id, plan.id, "fake")
      paid = paid_purchase_fixture(user, plan)

      assert {:ok, 0} = Purchases.cancel_stale(3600)

      assert {:ok, 1} =
               Purchases.cancel_stale(3600, now: DateTime.add(DateTime.utc_now(), 2, :hour))

      assert Ash.get!(Purchase, pending.id, authorize?: false).status == :cancelled
      assert Ash.get!(Purchase, paid.id, authorize?: false).status == :paid
    end

    test "a declined checkout expires too, so a much later payment follows the late rules", %{
      user: user,
      plan: plan
    } do
      with_env(:purchase_policy, :single_active, fn ->
        {:ok, declined} = Purchases.start(user.id, plan.id, "fake")
        {:ok, declined} = Purchases.attach_provider_ref(declined, "order-declined")
        {:ok, %{status: :failed}} = Purchases.fail(declined.id, "card declined")

        assert {:ok, 1} =
                 Purchases.cancel_stale(3600, now: DateTime.add(DateTime.utc_now(), 2, :hour))

        assert Ash.get!(Purchase, declined.id, authorize?: false).status == :cancelled

        # Paid hours later on the old page: one plan at a time, so it's kept for refund.
        assert {:ok, %{status: :refund_required}} =
                 Purchases.confirm_payment(declined.id, %{
                   amount: plan.price,
                   currency: "EGP",
                   provider_ref: "order-declined"
                 })
      end)
    end

    test "a declined checkout that's still recent can be retried and paid", %{
      user: user,
      plan: plan
    } do
      {:ok, declined} = Purchases.start(user.id, plan.id, "fake")
      {:ok, %{status: :failed}} = Purchases.fail(declined.id, "card declined")

      assert {:ok, 0} = Purchases.cancel_stale(3600)

      assert {:ok, %{status: :paid}} =
               Purchases.confirm_payment(declined.id, %{amount: plan.price, currency: "EGP"})
    end
  end

  describe "status events" do
    defp listen(status),
      do: :telemetry_test.attach_event_handlers(self(), [[:udin_billing, :purchase, status]])

    test "a failed payment is announced once", %{user: user, plan: plan} do
      {:ok, purchase} = Purchases.start(user.id, plan.id, "fake")
      ref = listen(:failed)

      {:ok, _} = Purchases.fail(purchase.id, "declined")
      {:ok, _} = Purchases.fail(purchase.id, "declined")

      assert_received {[:udin_billing, :purchase, :failed], ^ref, _, %{user_id: user_id}}
      assert user_id == user.id
      refute_received {[:udin_billing, :purchase, :failed], ^ref, _, _}
    end

    test "a refund is announced", %{user: user, plan: plan} do
      purchase = paid_purchase_fixture(user, plan)
      ref = listen(:refunded)

      {:ok, _} = Purchases.refund(purchase.id, "support")

      assert_received {[:udin_billing, :purchase, :refunded], ^ref, _, %{purchase_id: id}}
      assert id == purchase.id
    end

    test "a cancelled checkout is announced, by the rider or by the cleanup", %{
      user: user,
      plan: plan
    } do
      {:ok, by_rider} = Purchases.start(user.id, plan.id, "fake")
      ref = listen(:cancelled)
      {:ok, _} = Purchases.cancel(by_rider.id)
      assert_received {[:udin_billing, :purchase, :cancelled], ^ref, _, %{purchase_id: id}}
      assert id == by_rider.id

      {:ok, stale} = Purchases.start(user.id, plan.id, "fake")
      {:ok, 1} = Purchases.cancel_stale(60, now: DateTime.add(DateTime.utc_now(), 3600))
      assert_received {[:udin_billing, :purchase, :cancelled], ^ref, _, %{purchase_id: id}}
      assert id == stale.id
    end
  end

  describe "single_active policy" do
    test "one open checkout and one in-use bundle at a time", %{user: user, plan: plan} do
      with_env(:purchase_policy, :single_active, fn ->
        {:ok, first} = Purchases.start(user.id, plan.id, "fake")
        assert {:error, error} = Purchases.start(user.id, plan.id, "fake")
        assert Exception.message(error) =~ "checkout is already in progress"
        assert Purchases.open_checkout(user.id).id == first.id

        {:ok, _} = Purchases.confirm_payment(first.id, %{amount: plan.price, currency: "EGP"})
        assert {:error, error} = Purchases.start(user.id, plan.id, "fake")
        assert Exception.message(error) =~ "run out or expire"
      end)
    end

    test "a used-up bundle no longer blocks a new one", %{user: user} do
      with_env(:purchase_policy, :single_active, fn ->
        small = plan_fixture(%{features: %{"rides" => 1}})
        paid_purchase_fixture(user, small)
        {:ok, _} = Quotas.consume(user.id, "rides", reference: "b1")
        assert {:ok, _} = Purchases.start(user.id, small.id, "fake")
      end)
    end
  end
end

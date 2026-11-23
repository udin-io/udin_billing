defmodule UdinBilling.ConcurrencyTest do
  @moduledoc """
  Races on real, separate database connections. The SQL sandbox shares one connection
  between processes, which serializes every query and hides races, so these tests switch
  the repo to `:auto` mode and delete what they wrote afterwards.
  """
  use ExUnit.Case, async: false

  import UdinBilling.DataCase,
    only: [catalog_fixture: 0, user_fixture: 0, plan_fixture: 1, with_env: 3]

  alias UdinBilling.{Grant, Purchase, Purchases, TestRepo}

  @tables ~w(billing_provider_events billing_usages billing_grants billing_subscriptions billing_purchases
             billing_accounts billing_plan_features billing_plans billing_features users)

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, :auto)

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.mode(TestRepo, :auto)
      Enum.each(@tables, &TestRepo.delete_all/1)
      Ecto.Adapters.SQL.Sandbox.mode(TestRepo, :manual)
    end)

    catalog_fixture()
    plan = plan_fixture(%{features: %{"rides" => 3}})
    %{user: user_fixture(), plan: plan}
  end

  defp race(count, fun) do
    1..count
    |> Task.async_stream(fun, max_concurrency: count, timeout: 30_000)
    |> Enum.map(fn {:ok, result} -> result end)
  end

  defp pay(purchase, plan),
    do: Purchases.confirm_payment(purchase.id, %{amount: plan.price, currency: "EGP"})

  test "simultaneous spends never overdraw (lots created on the fly)", %{user: user, plan: plan} do
    {:ok, purchase} = Purchases.start(user.id, plan.id, "fake")
    {:ok, _} = pay(purchase, plan)

    results = race(10, &UdinBilling.consume(user.id, "rides", reference: "b#{&1}"))

    assert Enum.count(results, &match?({:ok, _}, &1)) == 3
    assert Enum.count(results, &(&1 == {:error, :insufficient_quota})) == 7
    assert [%{remaining: 0}] = Ash.read!(Grant, authorize?: false)
  end

  test "simultaneous spends on an existing lot never overdraw", %{user: user, plan: plan} do
    {:ok, purchase} = Purchases.start(user.id, plan.id, "fake")
    {:ok, _} = pay(purchase, plan)
    # The lot exists before the race, as for every spend after a user's first.
    {:ok, _} = UdinBilling.consume(user.id, "rides", reference: "warm-up")

    results = race(10, &UdinBilling.consume(user.id, "rides", reference: "b#{&1}"))

    assert Enum.count(results, &match?({:ok, _}, &1)) == 2
    assert Enum.count(results, &(&1 == {:error, :insufficient_quota})) == 8
    assert [%{remaining: 0}] = Ash.read!(Grant, authorize?: false)
  end

  test "simultaneous holds can't share the last units", %{user: user, plan: plan} do
    {:ok, purchase} = Purchases.start(user.id, plan.id, "fake")
    {:ok, _} = pay(purchase, plan)

    results = race(10, &UdinBilling.reserve(user.id, "rides", reference: "x#{&1}"))
    assert Enum.count(results, &match?({:ok, _}, &1)) == 3
  end

  test "simultaneous payment confirmations apply once", %{user: user, plan: plan} do
    {:ok, purchase} = Purchases.start(user.id, plan.id, "fake")
    ref = :telemetry_test.attach_event_handlers(self(), [[:udin_billing, :purchase, :paid]])

    results = race(10, fn _ -> pay(purchase, plan) end)

    assert Enum.all?(results, &match?({:ok, %{status: :paid}}, &1))
    assert_receive {[:udin_billing, :purchase, :paid], ^ref, _, _}
    refute_receive {[:udin_billing, :purchase, :paid], ^ref, _, _}, 200
  end

  test "the same provider message arriving 10 times at once applies once", %{
    user: user,
    plan: plan
  } do
    {:ok, purchase} = Purchases.start(user.id, plan.id, "fake")

    message = %{
      "event_id" => "e1",
      "type" => "payment_succeeded",
      "purchase_id" => purchase.id,
      "amount" => "150.00",
      "currency" => "EGP"
    }

    headers = %{"x-fake-signature" => "a-long-test-secret-value"}

    results = race(10, fn _ -> UdinBilling.handle_webhook("fake", message, headers) end)

    assert Enum.count(results, &(&1 == {:ok, :processed})) == 1
    assert Enum.count(results, &(&1 == {:ok, :duplicate})) == 9
  end

  @cleanup_delay_ms 15

  # The hourly cleanup and Paymob's callback can hit the same checkout in the same instant.
  # Whichever wins, a buyer who paid the full price for that checkout gets the plan:
  # payment first, and the cleanup's "still pending" check skips it; cleanup first, and
  # the payment is accepted as a late payment for the same checkout.
  test "cleanup racing payments: every buyer who paid gets the plan", %{plan: plan} do
    purchases =
      for n <- 1..30 do
        {:ok, purchase} = Purchases.start(user_fixture().id, plan.id, "fake")
        {:ok, purchase} = Purchases.attach_provider_ref(purchase, "order-#{n}")
        purchase
      end

    later = DateTime.add(DateTime.utc_now(), 2, :hour)

    pay_with_ref = fn purchase ->
      Purchases.confirm_payment(purchase.id, %{
        amount: plan.price,
        currency: "EGP",
        provider_ref: purchase.provider_ref
      })
    end

    # The cleanup lands while payments are running, so both orders happen.
    paying =
      Task.async(fn ->
        purchases |> Task.async_stream(pay_with_ref, max_concurrency: 5) |> Stream.run()
      end)

    cleanup =
      Task.async(fn ->
        Process.sleep(@cleanup_delay_ms)
        Purchases.cancel_stale(3600, now: later)
      end)

    :ok = Task.await(paying, 30_000)
    {:ok, _} = Task.await(cleanup, 30_000)

    for p <- Ash.read!(Purchase, authorize?: false) do
      assert p.status == :paid, "#{p.status} with paid_at #{inspect(p.paid_at)}"
      assert elem(UdinBilling.balance(p.user_id, "rides"), 1).remaining == 3
    end
  end

  test ":single_active lets only one of many simultaneous checkouts start", %{
    user: user,
    plan: plan
  } do
    with_env(:purchase_policy, :single_active, fn ->
      results = race(10, fn _ -> Purchases.start(user.id, plan.id, "fake") end)
      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    end)
  end

  test "the same Paymob callback arriving 10 times at once pays once", %{user: user, plan: plan} do
    {:ok, purchase} = Purchases.start(user.id, plan.id, "paymob")

    {:ok, _} =
      Purchases.attach_provider_ref(purchase, UdinBilling.Test.PaymobFixtures.order_ref())

    callback = UdinBilling.Test.PaymobFixtures.callback(:paid, purchase.id)

    results = race(10, fn _ -> UdinBilling.handle_webhook("paymob", callback) end)

    assert Enum.count(results, &(&1 == {:ok, :processed})) == 1
    assert Enum.count(results, &(&1 == {:ok, :duplicate})) == 9
    assert Ash.get!(Purchase, purchase.id, authorize?: false).status == :paid
  end

  test "a new subscription reported twice at once (app sync + webhook) is created once", %{
    user: user
  } do
    UdinBilling.DataCase.subscription_plan_fixture(%{
      provider_product_ids: %{"fake" => "basic_monthly"}
    })

    start = DateTime.add(DateTime.utc_now(), -60)

    state =
      UdinBilling.DataCase.sub_state(%{
        provider_ref: "new-sub",
        period_starts_at: start,
        period_ends_at: DateTime.shift(start, month: 1)
      })

    results = race(6, fn _ -> UdinBilling.Subscriptions.apply_state("fake", user.id, state) end)

    assert Enum.all?(results, &match?({:ok, %{provider_ref: "new-sub"}}, &1)), inspect(results)
    assert [_] = Ash.read!(UdinBilling.Subscription, authorize?: false)
  end

  test "the same reference sent many times at once is charged once", %{user: user} do
    for days <- 1..6 do
      plan = plan_fixture(%{validity_unit: :day, validity_count: days, features: %{"rides" => 1}})
      {:ok, p} = Purchases.start(user.id, plan.id, "fake")
      {:ok, _} = pay(p, plan)
    end

    {:ok, _} = UdinBilling.reserve(user.id, "rides", reference: "warm")
    {:ok, _} = UdinBilling.release(user.id, "rides", reference: "warm")

    results = race(8, fn _ -> UdinBilling.consume(user.id, "rides", reference: "booking:1") end)

    assert Enum.all?(results, &match?({:ok, _}, &1)), inspect(results)

    live =
      Ash.read!(UdinBilling.Usage, authorize?: false)
      |> Enum.filter(&(&1.reference == "booking:1" and &1.status != :released))

    assert [_one] = live
  end
end

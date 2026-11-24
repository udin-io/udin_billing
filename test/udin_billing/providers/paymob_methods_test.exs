defmodule UdinBilling.Providers.PaymobMethodsTest do
  @moduledoc "Payment methods: wallet configured but off until enabled; card only today."
  use UdinBilling.DataCase, async: false

  alias UdinBilling.Providers.Paymob
  alias UdinBilling.Test.{PaymobFixtures, PaymobStub}

  @customer %{
    first_name: "Mona",
    last_name: "Ali",
    email: "mona@example.com",
    phone_number: "+201000000000"
  }

  setup do
    {:ok, {Paymob, opts}} = UdinBilling.Config.provider("paymob")
    %{opts: opts, user: user_fixture(), plan: plan_fixture()}
  end

  defp offered(user, plan, extra \\ %{}) do
    PaymobStub.respond_with(
      {201,
       %{
         "id" => "pi",
         "client_secret" => "cs",
         "intention_order_id" => System.unique_integer([:positive])
       }}
    )

    {:ok, _} =
      UdinBilling.checkout(user.id, plan.id, "paymob", Map.merge(%{customer: @customer}, extra))

    assert_received {:paymob_request, :post, _url, _headers, body}
    body["payment_methods"]
  end

  defp with_methods(opts, enabled, fun) do
    with_env(
      :providers,
      %{"paymob" => {Paymob, Keyword.put(opts, :enabled_methods, enabled)}},
      fun
    )
  end

  test "wallet is configured but not offered: card only", %{user: user, plan: plan} do
    assert offered(user, plan) == [4_097_558]
  end

  test "enabling wallet is a config change", %{opts: opts, user: user, plan: plan} do
    with_methods(opts, [:card, :wallet], fn ->
      assert offered(user, plan) == [4_097_558, 4_097_559]
      assert offered(user, plan, %{methods: [:wallet]}) == [4_097_559]
    end)
  end

  test "a checkout can narrow the methods but never add a disabled one", %{opts: opts} do
    assert {:error, {:payment_methods_disabled, [:wallet]}} =
             Paymob.integration_ids(%{methods: [:wallet]}, opts)

    assert {:error, {:unknown_payment_methods, [:bank]}} =
             Paymob.integration_ids(%{methods: [:bank]}, opts)
  end

  test "an enabled method without an integration id fails before calling Paymob", %{
    opts: opts,
    user: user,
    plan: plan
  } do
    opts = Keyword.put(opts, :integrations, %{card: 4_097_558})

    with_methods(opts, [:card, :wallet], fn ->
      assert {:error, {:payment_method_not_configured, :wallet}} =
               UdinBilling.checkout(user.id, plan.id, "paymob", %{customer: @customer})

      refute_received {:paymob_request, _, _, _, _}
    end)

    assert {:error, :no_payment_method_enabled} =
             Paymob.integration_ids(%{}, Keyword.put(opts, :enabled_methods, []))
  end

  test "a real wallet payment is accepted even while wallet is off", %{user: user, plan: plan} do
    {:ok, purchase} = UdinBilling.Purchases.start(user.id, plan.id, "paymob")
    PaymobFixtures.bind(purchase)

    assert {:ok, :processed} =
             UdinBilling.handle_webhook(
               "paymob",
               PaymobFixtures.callback(:wallet_paid, purchase.id)
             )

    assert Ash.get!(Purchase, purchase.id, authorize?: false).status == :paid
  end
end

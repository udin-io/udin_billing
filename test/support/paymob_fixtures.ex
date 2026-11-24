defmodule UdinBilling.Test.PaymobFixtures do
  @moduledoc """
  Realistic Paymob "transaction processed" callbacks for tests.

  Each `hmac` below was computed independently with
  `printf '%s' "$fields" | openssl dgst -sha512 -hmac test-hmac-secret`
  over Paymob's 20 signed fields, so tests check our verification against Paymob's rule,
  not against a copy of our own code. `order.merchant_order_id` (our purchase id) isn't
  signed, so it can vary per test without changing the signature.
  """

  @hmacs %{
    paid:
      "6d281f2d58be32182c091212a395b607d1d0a923f810cdc996054e63cac9a57c76edefce0be78ac5e95d523d11b355375c07ae98db246cd871e23871e45aece1",
    failed:
      "06e92cde28a4521486122105e4ddb319433f09c0941a15c5a79f63cf4a7474afabb89615370adc18becd56174b6643642db82205275133e4f91588c986389977",
    pending:
      "ffafdd10281fe788b1def8308decb6a4aa8aab0fb45f0ed444bdccad761f44d342c9a3f7274ababa59cbebdd50b0d7708305fe5b8a8bbefc1c12f97a3f46bda1",
    refunded:
      "fad69b27218577693cc97d97a61ed5f044f4eb4e6447f1982d41dc9e68e6addf5315e5906ded0c650220fc868e02b21919c46d8dedfbb45cb63e07db7ceb8cf0",
    wallet_paid:
      "ad96a6bc98a8014365c41f1a02840f35e428dbb1bbcc3c3f7a353387d4664abbdb5fb21f2f268c655261dcb42c51128719e1a63e247104b1cdb1923d601a1c0e",
    child_refund:
      "046214dad5460c6511221f835355b22bb7ca928d7b6a4a4a0779a1318759b79975a5bd7e32a722cc71a66ca0958b30b8cd3efd163e9d2e08c21b61dff6ad25df"
  }

  @doc "Paymob's order id in every fixture; checkout stores it as the purchase's provider_ref."
  def order_ref, do: "217503754"

  @doc "Links `purchase` to the fixtures' Paymob order, as a real checkout would."
  def bind(purchase) do
    {:ok, bound} = UdinBilling.Purchases.attach_provider_ref(purchase, order_ref())
    bound
  end

  @doc "HMAC secret the fixtures are signed with."
  def hmac_secret, do: "test-hmac-secret"

  @doc "A signed POST callback (`%{\"type\", \"obj\", \"hmac\"}`) of `kind` for `purchase_id`."
  def callback(kind, purchase_id) when is_map_key(@hmacs, kind) do
    %{
      "type" => "TRANSACTION",
      "obj" => obj(kind, purchase_id),
      "hmac" => Map.fetch!(@hmacs, kind)
    }
  end

  @doc "The same transaction as the browser redirect sends it: flat string query params."
  def redirect(kind, purchase_id) do
    obj = obj(kind, purchase_id)

    obj
    |> Map.drop(["order", "source_data", "data"])
    |> Map.new(fn {key, value} -> {key, to_string(value)} end)
    |> Map.merge(%{
      "order" => to_string(obj["order"]["id"]),
      "merchant_order_id" => obj["order"]["merchant_order_id"],
      "source_data.pan" => obj["source_data"]["pan"],
      "source_data.sub_type" => obj["source_data"]["sub_type"],
      "source_data.type" => obj["source_data"]["type"],
      "data.message" => obj["data"]["message"],
      "hmac" => Map.fetch!(@hmacs, kind)
    })
  end

  defp obj(kind, purchase_id) do
    base = %{
      "id" => 192_036_465,
      "pending" => false,
      "amount_cents" => 15_000,
      "success" => true,
      "is_auth" => false,
      "is_capture" => false,
      "is_standalone_payment" => true,
      "is_voided" => false,
      "is_refunded" => false,
      "is_3d_secure" => true,
      "integration_id" => 4_097_558,
      "has_parent_transaction" => false,
      "error_occured" => false,
      "currency" => "EGP",
      "created_at" => "2026-10-04T10:15:30.123456",
      "owner" => 302_852,
      "source_data" => %{"pan" => "2346", "type" => "card", "sub_type" => "MasterCard"},
      "order" => %{"id" => 217_503_754, "merchant_order_id" => purchase_id},
      "data" => %{"message" => "Approved"}
    }

    Map.merge(base, variant(kind))
  end

  defp variant(:paid), do: %{}

  defp variant(:failed),
    do: %{"id" => 192_036_466, "success" => false, "data" => %{"message" => "Do not honour"}}

  defp variant(:pending), do: %{"id" => 192_036_467, "pending" => true, "success" => false}
  defp variant(:refunded), do: %{"is_refunded" => true}

  # A refund (or void) Paymob sends as its own transaction on the paid order: it has a
  # parent transaction, succeeds, and is not a capture.
  defp variant(:child_refund),
    do: %{
      "id" => 192_036_470,
      "has_parent_transaction" => true,
      "is_3d_secure" => false,
      "is_standalone_payment" => false,
      "created_at" => "2026-10-05T09:00:00.000000"
    }

  # A mobile wallet payment through the wallet integration.
  defp variant(:wallet_paid),
    do: %{
      "id" => 192_036_468,
      "integration_id" => 4_097_559,
      "is_3d_secure" => false,
      "source_data" => %{"pan" => "01010101010", "type" => "wallet", "sub_type" => "wallet"}
    }
end

defmodule UdinBilling.Test.PaymobStub do
  @moduledoc """
  Stand-in for Paymob's servers, plugged into ex_paymob as its `:http_client`.

  Each test sets the response with `respond_with/1`; every request is sent to the test
  process as `{:paymob_request, method, url, headers, decoded_body}`.
  """
  @behaviour ExPaymob.HttpClient

  @doc "Makes the next requests from this process return `{status, body_map}`, or `{:error, reason}`."
  def respond_with(response), do: Process.put(__MODULE__, response)

  @impl true
  def request(method, url, headers, body, _opts) do
    send(self(), {:paymob_request, method, url, headers, body && Jason.decode!(body)})

    case Process.get(__MODULE__, {201, %{}}) do
      {:error, reason} -> {:error, reason}
      {status, response} -> {:ok, status, [], Jason.encode!(response)}
    end
  end
end

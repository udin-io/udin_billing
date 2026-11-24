defmodule UdinBilling.WebhookPlug do
  @moduledoc """
  Receives provider messages over HTTP and hands them to `UdinBilling.Webhooks`.

      # router.ex, outside session/CSRF pipelines (providers send no cookies or tokens;
      # authenticity comes only from the provider's signature or secret)
      forward "/billing/webhooks/revenuecat", UdinBilling.WebhookPlug, provider: "revenuecat"

  Uses the params Phoenix already parsed (JSON body + query string) and the request
  headers, so the endpoint needs no raw-body reader. Without a parser it reads the JSON
  body itself (up to 1 MB).

  ## Responses
    * `200` - applied, duplicate, ignored, or refused for a business reason (stored for an
      admin; a retry wouldn't help).
    * `401` - bad or missing signature/secret.  * `404` - unknown provider name.
    * `500` - something broke; nothing was applied, so the provider's retry will apply it.
  """
  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: %{provider: opts |> Keyword.fetch!(:provider) |> to_string()}

  @impl true
  def call(conn, %{provider: provider}) do
    conn = fetch_query_params(conn)

    case UdinBilling.Webhooks.handle(provider, params(conn), Map.new(conn.req_headers)) do
      {:ok, outcome} -> respond(conn, 200, %{status: outcome})
      {:error, :invalid_signature} -> respond(conn, 401, %{error: "invalid signature"})
      {:error, :unknown_provider} -> respond(conn, 404, %{error: "unknown provider"})
      {:error, _reason} -> respond(conn, 500, %{error: "not applied, retry"})
    end
  end

  defp params(conn) do
    case conn.body_params do
      %Plug.Conn.Unfetched{} -> conn |> read_json_body() |> Map.merge(conn.query_params)
      body -> Map.merge(body, conn.query_params)
    end
  end

  defp read_json_body(conn) do
    with {:ok, raw, _conn} <- read_body(conn, length: 1_000_000),
         {:ok, %{} = body} <- Jason.decode(raw) do
      body
    else
      _ -> %{}
    end
  end

  defp respond(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
    |> halt()
  end
end

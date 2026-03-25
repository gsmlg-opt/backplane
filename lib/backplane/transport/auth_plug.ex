defmodule Backplane.Transport.AuthPlug do
  @moduledoc """
  Optional bearer token authentication plug.

  When `backplane.auth_token` is configured, requests must include
  `Authorization: Bearer <token>`. When not configured, all requests pass through.

  The /health endpoint always passes without auth.
  """

  import Plug.Conn
  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{request_path: "/health"} = conn, _opts), do: conn

  def call(conn, _opts) do
    case get_auth_token() do
      nil -> conn
      expected_token -> verify_token(conn, expected_token)
    end
  end

  defp verify_token(conn, expected_token) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         true <- Plug.Crypto.secure_compare(token, expected_token) do
      conn
    else
      _ -> reject(conn)
    end
  end

  defp reject(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{error: "Unauthorized"}))
    |> halt()
  end

  defp get_auth_token do
    Application.get_env(:backplane, :auth_token)
  end
end

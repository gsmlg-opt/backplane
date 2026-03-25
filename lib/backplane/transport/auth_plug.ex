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
      nil ->
        conn

      expected_token ->
        case get_req_header(conn, "authorization") do
          ["Bearer " <> token] when token == expected_token ->
            conn

          _ ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(401, Jason.encode!(%{error: "Unauthorized"}))
            |> halt()
        end
    end
  end

  defp get_auth_token do
    Application.get_env(:backplane, :auth_token)
  end
end

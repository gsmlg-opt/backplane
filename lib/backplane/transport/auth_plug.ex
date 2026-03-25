defmodule Backplane.Transport.AuthPlug do
  @moduledoc """
  Optional bearer token authentication plug.

  When `backplane.auth_token` is configured, requests must include
  `Authorization: Bearer <token>`. When not configured, all requests pass through.

  Supports token rotation by accepting a list of valid tokens:

      config :backplane, auth_token: "single-token"
      config :backplane, auth_tokens: ["current-token", "previous-token"]

  The /health and /metrics endpoints always pass without auth.
  """

  import Plug.Conn
  @behaviour Plug

  @public_paths ["/health", "/metrics"]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{request_path: path} = conn, _opts) when path in @public_paths, do: conn

  def call(conn, _opts) do
    case get_valid_tokens() do
      [] -> conn
      valid_tokens -> verify_token(conn, valid_tokens)
    end
  end

  defp verify_token(conn, valid_tokens) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        if Enum.any?(valid_tokens, &Plug.Crypto.secure_compare(token, &1)) do
          conn
        else
          reject(conn)
        end

      _ ->
        reject(conn)
    end
  end

  defp reject(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{error: "Unauthorized"}))
    |> halt()
  end

  defp get_valid_tokens do
    tokens = Application.get_env(:backplane, :auth_tokens, [])
    single = Application.get_env(:backplane, :auth_token)

    case {tokens, single} do
      {list, _} when is_list(list) and list != [] -> list
      {_, token} when is_binary(token) -> [token]
      _ -> []
    end
  end
end

defmodule Backplane.Transport.AuthPlug do
  @moduledoc """
  Bearer token authentication plug with two modes:

  **Legacy mode** (backward-compatible): When `backplane.auth_token` is set and
  no `clients` table rows exist, behaves as a single shared token — all tools visible.

  **Client mode**: When at least one row exists in `clients`, resolves the bearer
  token against `clients.token_hash`. On match, stores the client record in
  `conn.assigns[:client]` and scopes in `conn.assigns[:tool_scopes]`. On miss,
  falls through to legacy token check. If both fail, 401.

  The /health, /metrics, and webhook endpoints always pass without auth.
  """

  import Plug.Conn
  @behaviour Plug

  alias Backplane.Clients

  @public_paths ["/health", "/metrics", "/webhook/github", "/webhook/gitlab"]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{request_path: path} = conn, _opts) when path in @public_paths do
    assign(conn, :tool_scopes, ["*"])
  end

  def call(conn, _opts) do
    token = extract_bearer(conn)

    cond do
      # Client mode: try DB-backed clients first
      clients_exist?() ->
        case token && Clients.verify_token(token) do
          {:ok, client} ->
            conn
            |> assign(:client, client)
            |> assign(:tool_scopes, client.scopes)

          _ ->
            # Fall through to legacy token
            verify_legacy(conn, token)
        end

      # Legacy mode: no clients in DB
      true ->
        case get_valid_tokens() do
          [] ->
            # No auth configured at all
            assign(conn, :tool_scopes, ["*"])

          valid_tokens ->
            if token && Enum.any?(valid_tokens, &Plug.Crypto.secure_compare(token, &1)) do
              assign(conn, :tool_scopes, ["*"])
            else
              reject(conn)
            end
        end
    end
  end

  defp verify_legacy(conn, token) do
    case get_valid_tokens() do
      [] ->
        reject(conn)

      valid_tokens ->
        if token && Enum.any?(valid_tokens, &Plug.Crypto.secure_compare(token, &1)) do
          assign(conn, :tool_scopes, ["*"])
        else
          reject(conn)
        end
    end
  end

  defp extract_bearer(conn) do
    case get_req_header(conn, "authorization") do
      [header] -> extract_bearer_token(header)
      _ -> nil
    end
  end

  defp extract_bearer_token(header) do
    case String.split(header, " ", parts: 2) do
      [scheme, token] when byte_size(token) > 0 ->
        if String.downcase(scheme) == "bearer", do: String.trim(token)

      _ ->
        nil
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

  defp clients_exist? do
    Clients.any_clients?()
  end
end

defmodule Relayixir.Router do
  @moduledoc """
  Top-level Plug router. Dispatches requests to the HTTP or WebSocket proxy path.
  """

  use Plug.Router

  alias Relayixir.Proxy.{Upstream, ErrorMapper, HttpPlug}

  plug(Plug.RequestId)
  plug(Plug.Logger)
  plug(:match)
  plug(:dispatch)

  match _ do
    case Upstream.resolve(conn) do
      {:ok, upstream} ->
        case check_policy(conn, upstream) do
          :ok ->
            if upstream.websocket? && websocket_upgrade?(conn) do
              Relayixir.Proxy.WebSocket.Plug.call(conn, upstream)
            else
              HttpPlug.call(conn, upstream)
            end

          {:error, reason} ->
            ErrorMapper.send_error(conn, reason)
        end

      {:error, :route_not_found} ->
        ErrorMapper.send_error(conn, :route_not_found)
    end
  end

  defp check_policy(conn, upstream) do
    case upstream.allowed_methods do
      nil ->
        :ok

      methods ->
        if String.upcase(conn.method) in methods, do: :ok, else: {:error, :method_not_allowed}
    end
  end

  defp websocket_upgrade?(conn) do
    upgrade_header =
      conn
      |> Plug.Conn.get_req_header("upgrade")
      |> Enum.map(&String.downcase/1)

    "websocket" in upgrade_header
  end
end

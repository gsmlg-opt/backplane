defmodule Relayixir.Proxy.WebSocket.Plug do
  @moduledoc """
  Entry point for WebSocket proxy path. Implements WebSock behaviour for Bandit.
  Validates upgrade request, starts bridge process, and relays frames.
  """

  require Logger

  alias Relayixir.Proxy.Upstream
  alias Relayixir.Proxy.WebSocket.{Bridge, Frame}

  @behaviour WebSock

  @doc """
  Upgrades the connection to WebSocket if valid, otherwise returns 400.
  Called from Router when a WebSocket-eligible route with upgrade headers is matched.
  """
  @spec call(Plug.Conn.t(), Upstream.t()) :: Plug.Conn.t()
  def call(%Plug.Conn{} = conn, %Upstream{} = upstream) do
    if valid_websocket_upgrade?(conn) do
      ws_headers = extract_ws_headers(conn)

      conn
      |> WebSockAdapter.upgrade(
        __MODULE__,
        %{upstream: upstream, ws_headers: ws_headers},
        []
      )
    else
      conn
      |> Plug.Conn.put_resp_content_type("text/plain")
      |> Plug.Conn.send_resp(400, "Invalid WebSocket upgrade request")
    end
  end

  ## WebSock callbacks

  @impl WebSock
  def init(%{upstream: upstream, ws_headers: ws_headers}) do
    Process.flag(:trap_exit, true)

    case Bridge.start(self(), upstream, ws_headers) do
      {:ok, bridge_pid} ->
        Process.link(bridge_pid)
        {:ok, %{bridge_pid: bridge_pid}}

      {:error, reason} ->
        Logger.error("Failed to start WebSocket bridge: #{inspect(reason)}")
        {:stop, :normal, {1014, "Bad Gateway"}}
    end
  end

  @impl WebSock
  def handle_in({data, opcode: :text}, state) do
    frame = Frame.text(data)
    Bridge.relay_from_downstream(state.bridge_pid, frame)
    {:ok, state}
  end

  def handle_in({data, opcode: :binary}, state) do
    frame = Frame.binary(data)
    Bridge.relay_from_downstream(state.bridge_pid, frame)
    {:ok, state}
  end

  @impl WebSock
  def handle_info({:bridge_frame, frame}, state) do
    {:push, [frame], state}
  end

  def handle_info({:EXIT, pid, reason}, %{bridge_pid: pid} = state) do
    Logger.info("WebSocket bridge exited: #{inspect(reason)}")
    {:stop, :normal, state}
  end

  def handle_info(_msg, state) do
    {:ok, state}
  end

  @impl WebSock
  def handle_control({data, opcode: :ping}, state) do
    frame = Frame.ping(data)
    Bridge.relay_from_downstream(state.bridge_pid, frame)
    {:ok, state}
  end

  def handle_control({data, opcode: :pong}, state) do
    frame = Frame.pong(data)
    Bridge.relay_from_downstream(state.bridge_pid, frame)
    {:ok, state}
  end

  @impl WebSock
  def terminate(reason, state) do
    if is_map_key(state, :bridge_pid) and is_pid(state.bridge_pid) and
         Process.alive?(state.bridge_pid) do
      case reason do
        {:remote, code, reason_text} ->
          Bridge.downstream_closed(state.bridge_pid, code, reason_text)

        :normal ->
          Bridge.downstream_closed(state.bridge_pid, 1000, "")

        _ ->
          Bridge.downstream_closed(state.bridge_pid, 1001, "Going Away")
      end
    end

    :ok
  end

  ## Private

  defp valid_websocket_upgrade?(conn) do
    has_upgrade_header?(conn) &&
      has_connection_upgrade?(conn) &&
      has_ws_key?(conn) &&
      has_ws_version?(conn)
  end

  defp has_upgrade_header?(conn) do
    conn
    |> Plug.Conn.get_req_header("upgrade")
    |> Enum.any?(&(String.downcase(&1) == "websocket"))
  end

  defp has_connection_upgrade?(conn) do
    conn
    |> Plug.Conn.get_req_header("connection")
    |> Enum.any?(&String.contains?(String.downcase(&1), "upgrade"))
  end

  defp has_ws_key?(conn) do
    Plug.Conn.get_req_header(conn, "sec-websocket-key") != []
  end

  defp has_ws_version?(conn) do
    case Plug.Conn.get_req_header(conn, "sec-websocket-version") do
      ["13" | _] -> true
      _ -> false
    end
  end

  defp extract_ws_headers(conn) do
    conn.req_headers
    |> Enum.filter(fn {name, _} ->
      downcased = String.downcase(name)
      String.starts_with?(downcased, "sec-websocket-protocol")
    end)
  end
end

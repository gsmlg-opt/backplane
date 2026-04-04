defmodule Relayixir.TestWsSubprotocolUpstream do
  @moduledoc """
  A WebSocket echo server that is aware of Sec-WebSocket-Protocol negotiation.
  When the client sends "check-protocol", it responds with the negotiated protocol.
  Otherwise, it echoes frames like the standard TestWsUpstream.
  """

  @behaviour WebSock

  @impl WebSock
  def init(opts) do
    protocol = Map.get(opts, :protocol, "none")
    {:ok, %{protocol: protocol}}
  end

  @impl WebSock
  def handle_in({text, [opcode: :text]}, state) do
    case text do
      "check-protocol" ->
        {:push, [{:text, "protocol:#{state.protocol}"}], state}

      "close" ->
        {:stop, :normal, {1000, "requested close"}, state}

      _ ->
        {:push, [{:text, text}], state}
    end
  end

  def handle_in({data, [opcode: :binary]}, state) do
    {:push, [{:binary, data}], state}
  end

  @impl WebSock
  def handle_control({_data, [opcode: :ping]}, state) do
    {:ok, state}
  end

  def handle_control({_data, [opcode: :pong]}, state) do
    {:ok, state}
  end

  @impl WebSock
  def handle_info(_msg, state) do
    {:ok, state}
  end

  @impl WebSock
  def terminate(_reason, _state) do
    :ok
  end
end

defmodule Relayixir.TestWsSubprotocolRouter do
  @moduledoc """
  Plug router that upgrades to WebSocket with subprotocol negotiation support.
  Reads the Sec-WebSocket-Protocol header and passes the negotiated protocol
  to the handler so it can be echoed back for verification.
  """

  use Plug.Router

  plug(:match)
  plug(:dispatch)

  get "/ws" do
    # Extract the requested subprotocol from headers
    protocol =
      case Plug.Conn.get_req_header(conn, "sec-websocket-protocol") do
        [value | _] ->
          # Take the first protocol from a comma-separated list
          value
          |> String.split(",")
          |> List.first()
          |> String.trim()

        [] ->
          "none"
      end

    # Build upgrade options with subprotocol response if one was requested
    opts =
      if protocol != "none" do
        [subprotocol: protocol]
      else
        []
      end

    conn
    |> maybe_set_subprotocol(protocol)
    |> WebSockAdapter.upgrade(
      Relayixir.TestWsSubprotocolUpstream,
      %{protocol: protocol},
      opts
    )
    |> halt()
  end

  match _ do
    send_resp(conn, 404, "Not Found")
  end

  defp maybe_set_subprotocol(conn, "none"), do: conn

  defp maybe_set_subprotocol(conn, protocol) do
    Plug.Conn.put_resp_header(conn, "sec-websocket-protocol", protocol)
  end
end

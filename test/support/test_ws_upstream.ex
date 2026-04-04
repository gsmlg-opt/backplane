defmodule Relayixir.TestWsUpstream do
  @moduledoc """
  A simple WebSocket echo server using WebSock behaviour for testing.
  Echoes text and binary frames, responds to ping with pong,
  and initiates close on receiving "close" text.
  """

  @behaviour WebSock

  @impl WebSock
  def init(_opts) do
    {:ok, %{}}
  end

  @impl WebSock
  def handle_in({text, [opcode: :text]}, state) do
    if text == "close" do
      {:stop, :normal, {1000, "requested close"}, state}
    else
      {:push, [{:text, text}], state}
    end
  end

  def handle_in({data, [opcode: :binary]}, state) do
    {:push, [{:binary, data}], state}
  end

  @impl WebSock
  def handle_control({_data, [opcode: :ping]}, state) do
    # Bandit auto-responds to pings with pongs
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

defmodule Relayixir.TestWsRouter do
  @moduledoc """
  Minimal Plug router that upgrades to the TestWsUpstream WebSocket handler.
  """

  use Plug.Router

  plug(:match)
  plug(:dispatch)

  get "/ws" do
    conn
    |> WebSockAdapter.upgrade(Relayixir.TestWsUpstream, %{}, [])
    |> halt()
  end

  match _ do
    send_resp(conn, 404, "Not Found")
  end
end

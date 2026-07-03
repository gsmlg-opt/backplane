defmodule Relayixir.Proxy.WebSocket.AdapterTest do
  use ExUnit.Case

  alias Relayixir.Proxy.WebSocket.Adapter

  defmodule TestSocket do
    @behaviour WebSock

    @impl WebSock
    def init(state), do: {:ok, state}

    @impl WebSock
    def handle_in(_frame, state), do: {:ok, state}

    @impl WebSock
    def handle_info(_message, state), do: {:ok, state}
  end

  test "upgrade marks Plug test connection as upgraded with WebSock tuple" do
    state = %{ready?: true}

    conn =
      valid_conn()
      |> Adapter.upgrade(TestSocket, state, timeout: 1_000)

    assert conn.state == :upgraded
    assert conn.status == 101
    assert_receive {_ref, :upgrade, {:websocket, {TestSocket, ^state, [timeout: 1_000]}}}
  end

  test "validate_upgrade rejects missing WebSocket key header" do
    conn =
      Plug.Test.conn(:get, "/ws")
      |> Plug.Conn.put_req_header("connection", "Upgrade")
      |> Plug.Conn.put_req_header("upgrade", "websocket")
      |> Plug.Conn.put_req_header("sec-websocket-version", "13")

    assert {:error, "'sec-websocket-key' header is absent"} = Adapter.validate_upgrade(conn)
  end

  test "validate_upgrade accepts comma-separated connection header tokens" do
    conn =
      Plug.Test.conn(:get, "/ws")
      |> Plug.Conn.put_req_header("connection", "keep-alive, Upgrade")
      |> Plug.Conn.put_req_header("upgrade", "websocket")
      |> Plug.Conn.put_req_header("sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ==")
      |> Plug.Conn.put_req_header("sec-websocket-version", "13")

    assert :ok = Adapter.validate_upgrade(conn)
  end

  defp valid_conn do
    Plug.Test.conn(:get, "/ws")
    |> Plug.Conn.put_req_header("connection", "Upgrade")
    |> Plug.Conn.put_req_header("upgrade", "websocket")
    |> Plug.Conn.put_req_header("sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ==")
    |> Plug.Conn.put_req_header("sec-websocket-version", "13")
  end
end

defmodule Relayixir.Proxy.WebSocket.PlugTest do
  use ExUnit.Case

  alias Relayixir.Proxy.WebSocket.Plug, as: WsPlug
  alias Relayixir.Proxy.Upstream

  describe "WebSock callback: handle_info EXIT" do
    test "bridge exit with :normal returns stop" do
      bridge_pid = spawn(fn -> :ok end)
      Process.sleep(10)

      state = %{bridge_pid: bridge_pid}
      result = WsPlug.handle_info({:EXIT, bridge_pid, :normal}, state)
      assert result == {:stop, :normal, state}
    end

    test "bridge exit with {:shutdown, reason} returns stop" do
      bridge_pid = spawn(fn -> :ok end)
      Process.sleep(10)

      state = %{bridge_pid: bridge_pid}
      result = WsPlug.handle_info({:EXIT, bridge_pid, {:shutdown, :timeout}}, state)
      assert result == {:stop, :normal, state}
    end

    test "bridge exit with :killed returns stop" do
      bridge_pid = spawn(fn -> :ok end)
      Process.sleep(10)

      state = %{bridge_pid: bridge_pid}
      result = WsPlug.handle_info({:EXIT, bridge_pid, :killed}, state)
      assert result == {:stop, :normal, state}
    end

    test "EXIT from non-bridge pid is ignored" do
      bridge_pid = spawn(fn -> :ok end)
      other_pid = spawn(fn -> :ok end)
      Process.sleep(10)

      state = %{bridge_pid: bridge_pid}
      result = WsPlug.handle_info({:EXIT, other_pid, :normal}, state)
      assert result == {:ok, state}
    end
  end

  describe "WebSock callback: terminate" do
    test "terminate with already-dead bridge does not crash" do
      bridge_pid = spawn(fn -> :ok end)
      # Wait for the process to die
      Process.sleep(10)
      refute Process.alive?(bridge_pid)

      state = %{bridge_pid: bridge_pid}
      # Should not raise
      assert WsPlug.terminate(:normal, state) == :ok
    end

    test "terminate with no bridge_pid key does not crash" do
      state = %{}
      assert WsPlug.terminate(:normal, state) == :ok
    end

    test "terminate with remote close notifies live bridge", %{} do
      # Start a real bridge to test the terminate path with a live process
      test_pid = self()

      # Spawn a process that will receive the downstream_closed cast
      fake_bridge =
        spawn(fn ->
          receive do
            {:"$gen_cast", {:downstream_closed, code, reason}} ->
              send(test_pid, {:closed_with, code, reason})
          after
            2_000 -> :timeout
          end
        end)

      state = %{bridge_pid: fake_bridge}
      WsPlug.terminate({:remote, 1000, "bye"}, state)

      assert_receive {:closed_with, 1000, "bye"}, 1_000
    end

    test "terminate with :normal sends 1000 close to live bridge" do
      test_pid = self()

      fake_bridge =
        spawn(fn ->
          receive do
            {:"$gen_cast", {:downstream_closed, code, _reason}} ->
              send(test_pid, {:closed_with_code, code})
          after
            2_000 -> :timeout
          end
        end)

      state = %{bridge_pid: fake_bridge}
      WsPlug.terminate(:normal, state)

      assert_receive {:closed_with_code, 1000}, 1_000
    end

    test "terminate with abnormal reason sends 1001 to live bridge" do
      test_pid = self()

      fake_bridge =
        spawn(fn ->
          receive do
            {:"$gen_cast", {:downstream_closed, code, reason}} ->
              send(test_pid, {:closed_with, code, reason})
          after
            2_000 -> :timeout
          end
        end)

      state = %{bridge_pid: fake_bridge}
      WsPlug.terminate(:crash, state)

      assert_receive {:closed_with, 1001, "Going Away"}, 1_000
    end
  end

  describe "valid_websocket_upgrade? validation" do
    test "rejects request missing upgrade header" do
      conn =
        Plug.Test.conn(:get, "/ws")
        |> Plug.Conn.put_req_header("connection", "Upgrade")
        |> Plug.Conn.put_req_header("sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ==")
        |> Plug.Conn.put_req_header("sec-websocket-version", "13")

      upstream = %Upstream{
        scheme: :http,
        host: "127.0.0.1",
        port: 9999,
        websocket?: true,
        host_forward_mode: :preserve,
        metadata: %{}
      }

      result = WsPlug.call(conn, upstream)
      assert result.status == 400
      assert result.resp_body == "Invalid WebSocket upgrade request"
    end

    test "rejects request missing connection header" do
      conn =
        Plug.Test.conn(:get, "/ws")
        |> Plug.Conn.put_req_header("upgrade", "websocket")
        |> Plug.Conn.put_req_header("sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ==")
        |> Plug.Conn.put_req_header("sec-websocket-version", "13")

      upstream = %Upstream{
        scheme: :http,
        host: "127.0.0.1",
        port: 9999,
        websocket?: true,
        host_forward_mode: :preserve,
        metadata: %{}
      }

      result = WsPlug.call(conn, upstream)
      assert result.status == 400
    end

    test "rejects request missing sec-websocket-key" do
      conn =
        Plug.Test.conn(:get, "/ws")
        |> Plug.Conn.put_req_header("upgrade", "websocket")
        |> Plug.Conn.put_req_header("connection", "Upgrade")
        |> Plug.Conn.put_req_header("sec-websocket-version", "13")

      upstream = %Upstream{
        scheme: :http,
        host: "127.0.0.1",
        port: 9999,
        websocket?: true,
        host_forward_mode: :preserve,
        metadata: %{}
      }

      result = WsPlug.call(conn, upstream)
      assert result.status == 400
    end

    test "rejects request with wrong sec-websocket-version" do
      conn =
        Plug.Test.conn(:get, "/ws")
        |> Plug.Conn.put_req_header("upgrade", "websocket")
        |> Plug.Conn.put_req_header("connection", "Upgrade")
        |> Plug.Conn.put_req_header("sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ==")
        |> Plug.Conn.put_req_header("sec-websocket-version", "8")

      upstream = %Upstream{
        scheme: :http,
        host: "127.0.0.1",
        port: 9999,
        websocket?: true,
        host_forward_mode: :preserve,
        metadata: %{}
      }

      result = WsPlug.call(conn, upstream)
      assert result.status == 400
    end
  end
end

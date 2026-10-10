defmodule Relayixir.Proxy.WebSocket.UpstreamClientTest do
  use ExUnit.Case

  alias Relayixir.Proxy.Upstream
  alias Relayixir.Proxy.WebSocket.{Bridge, Frame, UpstreamClient}

  test "uses the public WebSocket client and preserves request headers and subprotocols" do
    owner = self()

    upstream =
      start_peer(fn socket, request ->
        send(owner, {:request, request})
        upgrade(socket, request, [{"sec-websocket-protocol", "graphql-ws"}])
        assert {8, <<1001::16, "done">>} = recv_frame(socket)
        send_frame(socket, 8, <<1001::16, "done">>)
      end)

    assert {:ok, %HTTP.WebSocket{} = socket} =
             UpstreamClient.connect(upstream, [
               {"authorization", "Bearer test-key"},
               {"sec-websocket-protocol", "graphql-ws, graphql-transport-ws"},
               {"sec-websocket-extensions", "permessage-deflate"}
             ])

    assert_receive {:request, request}
    assert request =~ "GET /ws?token=test HTTP/1.1"
    assert String.downcase(request) =~ "authorization: bearer test-key"
    assert String.downcase(request) =~ "sec-websocket-protocol: graphql-ws, graphql-transport-ws"
    refute request =~ "permessage-deflate"
    assert HTTP.WebSocket.protocol(socket) == "graphql-ws"
    assert :ok = UpstreamClient.send_frame(socket, Frame.close(1001, "done"))
    assert_receive {HTTP.WebSocket, ^socket, %HTTP.WebSocket.Event.Close{code: 1001}}
    await_peer()
  end

  test "forwards upstream ping and pong without an automatic pong" do
    owner = self()

    upstream =
      start_peer(fn socket, request ->
        upgrade(socket, request)
        send_frame(socket, 9, "probe")
        assert {10, "forwarded"} = recv_frame(socket)
        send(owner, :pong_forwarded)
        send_frame(socket, 10, "reply")
        assert {8, <<1000::16>>} = recv_frame(socket)
        send_frame(socket, 8, <<1000::16>>)
      end)

    assert {:ok, %HTTP.WebSocket{} = socket} = UpstreamClient.connect(upstream)
    assert_receive {HTTP.WebSocket, ^socket, %HTTP.WebSocket.Event.Frame{} = event, delivery}

    assert {:ok, [%Frame{type: :ping, payload: "probe"}], ^delivery} =
             UpstreamClient.decode_message(socket, {HTTP.WebSocket, socket, event, delivery})

    assert :ok = HTTP.WebSocket.acknowledge(socket, delivery)
    assert :ok = UpstreamClient.send_frame(socket, Frame.pong("forwarded"))
    assert_receive :pong_forwarded
    assert_receive {HTTP.WebSocket, ^socket, %HTTP.WebSocket.Event.Frame{} = event, delivery}

    assert {:ok, [%Frame{type: :pong, payload: "reply"}], ^delivery} =
             UpstreamClient.decode_message(socket, {HTTP.WebSocket, socket, event, delivery})

    assert :ok = HTTP.WebSocket.acknowledge(socket, delivery)
    assert :ok = UpstreamClient.send_frame(socket, Frame.close())
    await_peer()
  end

  for target <- ["//tenant/ws", "//tenant/ws?token=test"] do
    test "preserves the origin-form WebSocket target #{target}" do
      upstream =
        start_peer(fn socket, request ->
          assert request =~ "GET #{unquote(target)} HTTP/1.1\r\n"
          upgrade(socket, request)
          assert {8, <<1000::16>>} = recv_frame(socket)
          send_frame(socket, 8, <<1000::16>>)
        end)

      upstream = %{upstream | path_prefix_rewrite: unquote(target)}
      assert {:ok, %HTTP.WebSocket{} = socket} = UpstreamClient.connect(upstream)
      assert :ok = UpstreamClient.send_frame(socket, Frame.close())
      assert_receive {HTTP.WebSocket, ^socket, %HTTP.WebSocket.Event.Close{code: 1000}}
      await_peer()
    end
  end

  test "drains application writes before preserving an RFC close code and reason" do
    owner = self()

    upstream =
      start_peer(fn socket, request ->
        upgrade(socket, request)
        assert {1, "last message"} = recv_frame(socket)
        assert {9, "last ping"} = recv_frame(socket)
        assert {8, <<1008::16, "policy">>} = recv_frame(socket)
        send(owner, :writes_drained)
        send_frame(socket, 8, <<1008::16, "policy">>)
      end)

    assert {:ok, %HTTP.WebSocket{} = socket} = UpstreamClient.connect(upstream)
    assert :ok = UpstreamClient.send_frame(socket, Frame.text("last message"))
    assert :ok = UpstreamClient.send_frame(socket, Frame.ping("last ping"))
    assert :ok = UpstreamClient.send_frame(socket, Frame.close(1008, "policy"))
    assert_receive :writes_drained
    assert_receive {HTTP.WebSocket, ^socket, %HTTP.WebSocket.Event.Close{} = event}

    assert {:ok, [%Frame{type: :close, close_code: 1008, close_reason: "policy"}], nil} =
             UpstreamClient.decode_message(socket, {HTTP.WebSocket, socket, event})

    await_peer()
  end

  test "upstream close preserves protocol code and reason" do
    upstream =
      start_peer(fn socket, request ->
        upgrade(socket, request)
        send_frame(socket, 8, <<1011::16, "upstream failed">>)
        assert {8, <<1011::16, "upstream failed">>} = recv_frame(socket)
      end)

    assert {:ok, %HTTP.WebSocket{} = socket} = UpstreamClient.connect(upstream)
    assert_receive {HTTP.WebSocket, ^socket, %HTTP.WebSocket.Event.Close{} = event}

    assert {:ok, [%Frame{type: :close, close_code: 1011, close_reason: "upstream failed"}], nil} =
             UpstreamClient.decode_message(socket, {HTTP.WebSocket, socket, event})

    await_peer()
  end

  test "bridge forwards control frames, invokes hooks and closes the upstream session" do
    test_pid = self()
    previous_hook = Relayixir.Config.HookConfig.get_on_ws_frame()

    Relayixir.Config.HookConfig.put_on_ws_frame(fn _session, direction, frame ->
      send(test_pid, {:ws_hook, direction, frame})
    end)

    on_exit(fn -> Relayixir.Config.HookConfig.put_on_ws_frame(previous_hook) end)

    upstream =
      start_peer(fn socket, request ->
        upgrade(socket, request)
        send_frame(socket, 9, "probe")
        assert {10, "forwarded"} = recv_frame(socket)
        send_frame(socket, 10, "reply")
        assert {1, "close-now"} = recv_frame(socket)
        send_frame(socket, 8, <<1008::16, "policy">>)
        assert {8, <<1008::16, "policy">>} = recv_frame(socket)
      end)

    {:ok, bridge} = Bridge.start(self(), upstream)
    bridge_monitor = Process.monitor(bridge)
    assert_receive {:bridge_frame, {:ping, "probe"}}, 2_000
    assert_receive {:ws_hook, :inbound, %Frame{type: :ping, payload: "probe"}}
    %HTTP.WebSocket{pid: socket_pid} = :sys.get_state(bridge).upstream_conn
    socket_monitor = Process.monitor(socket_pid)

    Bridge.relay_from_downstream(bridge, Frame.pong("forwarded"))
    assert_receive {:ws_hook, :outbound, %Frame{type: :pong, payload: "forwarded"}}
    assert_receive {:bridge_frame, {:pong, "reply"}}, 2_000
    assert_receive {:ws_hook, :inbound, %Frame{type: :pong, payload: "reply"}}
    Bridge.relay_from_downstream(bridge, Frame.text("close-now"))
    assert_receive {:bridge_frame, {:close, 1008, "policy"}}, 2_000
    assert_receive {:DOWN, ^bridge_monitor, :process, ^bridge, :normal}, 2_000
    assert_receive {:DOWN, ^socket_monitor, :process, ^socket_pid, :normal}, 2_000
    await_peer()
  end

  test "bridge maps abrupt upstream EOF to an internal-error close" do
    upstream = start_peer(fn socket, request -> upgrade(socket, request) end)
    {:ok, bridge} = Bridge.start(self(), upstream)
    monitor = Process.monitor(bridge)

    assert_receive {:bridge_frame, {:close, 1011, "Internal Error"}}, 2_000
    assert_receive {:DOWN, ^monitor, :process, ^bridge, :normal}, 2_000
    await_peer()
  end

  test "connection owner death closes the public client process" do
    upstream =
      start_peer(fn socket, request ->
        upgrade(socket, request)
        assert {:error, :closed} = :gen_tcp.recv(socket, 0, 2_000)
      end)

    test_pid = self()

    owner =
      spawn(fn ->
        {:ok, socket} = UpstreamClient.connect(upstream)
        send(test_pid, {:socket, socket})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:socket, %HTTP.WebSocket{} = socket}
    monitor = Process.monitor(socket.pid)
    send(owner, :stop)
    assert_receive {:DOWN, ^monitor, :process, _, _}, 2_000
    await_peer()
  end

  defp start_peer(run) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true])

    {:ok, {_address, port}} = :inet.sockname(listener)

    peer =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)

        try do
          run.(socket, recv_head(socket, ""))
        after
          :gen_tcp.close(socket)
        end
      end)

    Process.put(:ws_peer, peer)

    on_exit(fn ->
      :gen_tcp.close(listener)
      if Process.alive?(peer.pid), do: Process.exit(peer.pid, :kill)
    end)

    %Upstream{
      scheme: :http,
      host: "127.0.0.1",
      port: port,
      path_prefix_rewrite: "/ws?token=test"
    }
  end

  defp await_peer do
    Task.await(Process.get(:ws_peer), 2_000)
  end

  defp recv_head(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      acc
    else
      {:ok, data} = :gen_tcp.recv(socket, 0, 2_000)
      recv_head(socket, acc <> data)
    end
  end

  defp upgrade(socket, request, headers \\ []) do
    [_, key] = Regex.run(~r/sec-websocket-key: ([^\r]+)\r/i, request)
    accept = :crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11") |> Base.encode64()

    :ok =
      :gen_tcp.send(socket, [
        "HTTP/1.1 101 Switching Protocols\r\n",
        "upgrade: websocket\r\nconnection: Upgrade\r\n",
        "sec-websocket-accept: #{accept}\r\n",
        Enum.map(headers, fn {name, value} -> "#{name}: #{value}\r\n" end),
        "\r\n"
      ])
  end

  defp recv_frame(socket) do
    {:ok, <<1::1, 0::3, opcode::4, 1::1, size::7>>} = :gen_tcp.recv(socket, 2, 2_000)
    assert size < 126
    {:ok, mask} = :gen_tcp.recv(socket, 4, 2_000)

    payload =
      if size == 0 do
        ""
      else
        {:ok, payload} = :gen_tcp.recv(socket, size, 2_000)
        key = :binary.copy(mask, div(size + 3, 4)) |> binary_part(0, size)
        :crypto.exor(payload, key)
      end

    {opcode, payload}
  end

  defp send_frame(socket, opcode, payload) do
    :ok = :gen_tcp.send(socket, [<<1::1, 0::3, opcode::4, 0::1, byte_size(payload)::7>>, payload])
  end
end

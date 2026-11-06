defmodule Relayixir.Proxy.WebSocket.IntegrationTest do
  use ExUnit.Case

  alias Relayixir.Config.{RouteConfig, UpstreamConfig}

  @moduletag :integration

  setup do
    # Start a WebSocket echo upstream
    {:ok, upstream_pid} = Gaoxy.HTTP.start_link(plug: {Relayixir.TestWsRouter, []}, port: 0)
    %{local: {:ok, {_ip, upstream_port}}} = Gaoxy.info(upstream_pid, :http)

    # Start the proxy router on a random port
    {:ok, proxy_pid} = Gaoxy.HTTP.start_link(plug: {Relayixir.Router, []}, port: 0)
    %{local: {:ok, {_ip, proxy_port}}} = Gaoxy.info(proxy_pid, :http)

    # Configure routes to direct WebSocket traffic to upstream
    RouteConfig.put_routes([
      %{
        host_match: "*",
        path_prefix: "/ws",
        upstream_name: "ws_backend",
        websocket: true,
        host_forward_mode: :rewrite_to_upstream
      },
      %{
        host_match: "*",
        path_prefix: "/",
        upstream_name: "ws_backend"
      }
    ])

    UpstreamConfig.put_upstreams(%{
      "ws_backend" => %{
        scheme: :http,
        host: "127.0.0.1",
        port: upstream_port,
        path_prefix_rewrite: "/ws"
      }
    })

    on_exit(fn ->
      try do
        Gaoxy.stop(proxy_pid)
        Gaoxy.stop(upstream_pid)
      catch
        :exit, _ -> :ok
      end
    end)

    %{proxy_port: proxy_port, upstream_port: upstream_port}
  end

  test "full end-to-end WebSocket proxy: upgrade, relay text, close", %{proxy_port: proxy_port} do
    socket = HTTP.WebSocket.new("http://127.0.0.1:#{proxy_port}/ws")
    assert_receive {HTTP.WebSocket, ^socket, %HTTP.WebSocket.Event.Open{}}, 5_000

    :ok = HTTP.WebSocket.send(socket, "hello via proxy")
    assert_receive {HTTP.WebSocket, ^socket, %HTTP.WebSocket.Event.Message{data: "hello via proxy"}}, 5_000

    :ok = HTTP.WebSocket.close(socket, 1000, "done")
    assert_receive {HTTP.WebSocket, ^socket, %HTTP.WebSocket.Event.Close{code: 1000}}, 5_000
  end

  test "full end-to-end WebSocket proxy: relay binary frame", %{proxy_port: proxy_port} do
    socket = HTTP.WebSocket.new("http://127.0.0.1:#{proxy_port}/ws")
    assert_receive {HTTP.WebSocket, ^socket, %HTTP.WebSocket.Event.Open{}}, 5_000

    binary_data = <<0xFF, 0xFE, 0xFD, 0xFC>>
    :ok = HTTP.WebSocket.send(socket, HTTP.WebSocket.array_buffer(binary_data))
    assert_receive {HTTP.WebSocket, ^socket, %HTTP.WebSocket.Event.Message{data: %HTTP.Blob{data: ^binary_data}}}, 5_000

    HTTP.WebSocket.close(socket)
  end

  test "upstream-initiated close reaches the downstream with its reason", %{proxy_port: port} do
    socket = HTTP.WebSocket.new("http://127.0.0.1:#{port}/ws")
    assert_receive {HTTP.WebSocket, ^socket, %HTTP.WebSocket.Event.Open{}}, 5_000

    :ok = HTTP.WebSocket.send(socket, "close")
    assert_receive {HTTP.WebSocket, ^socket, %HTTP.WebSocket.Event.Close{code: 1000, reason: "requested close"}}, 5_000
  end

  test "non-WebSocket request to WS route returns normal HTTP response", %{
    proxy_port: proxy_port
  } do
    promise = HTTP.fetch("http://127.0.0.1:#{proxy_port}/ws", method: "GET")
    response = HTTP.Promise.await(promise)
    assert %HTTP.Response{} = response
    assert response.status != nil
  end
end

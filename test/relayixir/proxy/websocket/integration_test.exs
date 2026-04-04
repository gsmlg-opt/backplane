defmodule Relayixir.Proxy.WebSocket.IntegrationTest do
  use ExUnit.Case

  alias Relayixir.Config.{RouteConfig, UpstreamConfig}

  @moduletag :integration

  setup do
    # Start a WebSocket echo upstream
    {:ok, upstream_pid} = Bandit.start_link(plug: Relayixir.TestWsRouter, port: 0)
    {:ok, {_ip, upstream_port}} = ThousandIsland.listener_info(upstream_pid)

    # Start the proxy router on a random port
    {:ok, proxy_pid} = Bandit.start_link(plug: Relayixir.Router, port: 0)
    {:ok, {_ip, proxy_port}} = ThousandIsland.listener_info(proxy_pid)

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
        ThousandIsland.stop(proxy_pid)
        ThousandIsland.stop(upstream_pid)
      catch
        :exit, _ -> :ok
      end
    end)

    %{proxy_port: proxy_port, upstream_port: upstream_port}
  end

  test "full end-to-end WebSocket proxy: upgrade, relay text, close", %{proxy_port: proxy_port} do
    # Connect to the proxy's WebSocket endpoint
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", proxy_port)

    {:ok, conn, ref} =
      Mint.WebSocket.upgrade(:ws, conn, "/ws", [
        {"host", "127.0.0.1:#{proxy_port}"}
      ])

    # Receive upgrade response
    {:ok, conn, websocket} = await_ws_upgrade(conn, ref)

    # Send a text frame through the proxy
    {:ok, websocket, data} = Mint.WebSocket.encode(websocket, {:text, "hello via proxy"})
    {:ok, conn} = Mint.WebSocket.stream_request_body(conn, ref, data)

    # Should receive the echo back through the proxy
    {:ok, _conn, websocket, frames} = await_ws_frames(conn, websocket)
    assert [{:text, "hello via proxy"}] = frames

    # Send close
    {:ok, websocket, data} = Mint.WebSocket.encode(websocket, {:close, 1000, "done"})
    {:ok, conn} = Mint.WebSocket.stream_request_body(conn, ref, data)

    # Await close ack
    await_ws_close(conn, websocket)
  end

  test "full end-to-end WebSocket proxy: relay binary frame", %{proxy_port: proxy_port} do
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", proxy_port)

    {:ok, conn, ref} =
      Mint.WebSocket.upgrade(:ws, conn, "/ws", [
        {"host", "127.0.0.1:#{proxy_port}"}
      ])

    {:ok, conn, websocket} = await_ws_upgrade(conn, ref)

    # Send binary frame
    binary_data = <<0xFF, 0xFE, 0xFD, 0xFC>>
    {:ok, websocket, data} = Mint.WebSocket.encode(websocket, {:binary, binary_data})
    {:ok, conn} = Mint.WebSocket.stream_request_body(conn, ref, data)

    # Should receive binary echo
    {:ok, _conn, _websocket, frames} = await_ws_frames(conn, websocket)
    assert [{:binary, ^binary_data}] = frames

    Mint.HTTP.close(conn)
  end

  test "non-WebSocket request to WS route returns normal HTTP response", %{
    proxy_port: proxy_port
  } do
    # A normal HTTP GET to the WS-eligible route should fall through to HTTP proxy
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", proxy_port)
    {:ok, conn, ref} = Mint.HTTP.request(conn, "GET", "/ws", [{"host", "localhost"}], nil)

    {:ok, _conn, responses} = recv_all(conn, ref)

    # The upstream WS handler responds with upgrade, but without WS headers
    # the proxy should handle it as HTTP (404 from test router for non-WS upgrade)
    statuses = for {:status, ^ref, status} <- responses, do: status
    assert length(statuses) > 0
  end

  ## Helpers

  defp await_ws_upgrade(conn, ref) do
    receive do
      message ->
        case Mint.WebSocket.stream(conn, message) do
          {:ok, conn, responses} ->
            {status, headers} = extract_status_headers(responses)

            case Mint.WebSocket.new(conn, ref, status, headers) do
              {:ok, conn, websocket} -> {:ok, conn, websocket}
              {:error, conn, reason} -> {:error, conn, reason}
            end

          {:error, conn, reason, _} ->
            {:error, conn, reason}
        end
    after
      5_000 -> {:error, conn, :timeout}
    end
  end

  defp await_ws_frames(conn, websocket) do
    receive do
      message ->
        case Mint.WebSocket.stream(conn, message) do
          {:ok, conn, [{:data, _ref, data}]} ->
            case Mint.WebSocket.decode(websocket, data) do
              {:ok, websocket, frames} -> {:ok, conn, websocket, frames}
              {:error, websocket, reason} -> {:error, conn, websocket, reason}
            end

          {:ok, conn, _other} ->
            await_ws_frames(conn, websocket)

          {:error, conn, reason, _} ->
            {:error, conn, websocket, reason}

          :unknown ->
            await_ws_frames(conn, websocket)
        end
    after
      5_000 -> {:error, conn, websocket, :timeout}
    end
  end

  defp await_ws_close(conn, websocket) do
    receive do
      message ->
        case Mint.WebSocket.stream(conn, message) do
          {:ok, conn, [{:data, _ref, data}]} ->
            case Mint.WebSocket.decode(websocket, data) do
              {:ok, _websocket, frames} ->
                has_close = Enum.any?(frames, fn f -> match?({:close, _, _}, f) end)
                if has_close, do: :ok, else: await_ws_close(conn, websocket)

              {:error, _websocket, _reason} ->
                :ok
            end

          {:ok, _conn, _} ->
            :ok

          _ ->
            :ok
        end
    after
      5_000 -> :timeout
    end
  end

  defp extract_status_headers(responses) do
    Enum.reduce(responses, {nil, []}, fn
      {:status, _ref, status}, {_s, h} -> {status, h}
      {:headers, _ref, headers}, {s, _h} -> {s, headers}
      _, acc -> acc
    end)
  end

  defp recv_all(conn, ref, acc \\ []) do
    receive do
      message ->
        case Mint.HTTP.stream(conn, message) do
          {:ok, conn, responses} ->
            new_acc = acc ++ responses
            done? = Enum.any?(responses, &match?({:done, ^ref}, &1))
            if done?, do: {:ok, conn, new_acc}, else: recv_all(conn, ref, new_acc)

          {:error, conn, reason, _} ->
            {:error, conn, reason}

          :unknown ->
            recv_all(conn, ref, acc)
        end
    after
      5_000 -> {:ok, conn, acc}
    end
  end
end

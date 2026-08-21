defmodule Backplane.McpProtocol.Transport.StreamableHTTP.StreamTest do
  use ExUnit.Case, async: false

  alias Backplane.McpProtocol.Protocol.Registry
  alias Backplane.McpProtocol.Transport.RequestContext
  alias Backplane.McpProtocol.Transport.StreamableHTTP

  @version "2026-07-28"
  @subscription_id_key "io.modelcontextprotocol/subscriptionId"
  @test_http_opts [max_reconnections: 0]

  setup do
    {:ok, _applications} = Application.ensure_all_started(:bypass)

    unless Process.whereis(Backplane.McpProtocol.Finch) do
      start_supervised!({Finch, name: Backplane.McpProtocol.Finch})
    end

    bypass = Bypass.open()
    Process.group_leader(self(), self())
    {:ok, bypass: bypass}
  end

  test "owns one incremental POST/SSE stream while ordinary HTTP calls remain concurrent", %{
    bypass: bypass
  } do
    test_pid = self()

    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = JSON.decode!(body)
      send(test_pid, {:http_method, request["method"]})

      case request["method"] do
        "subscriptions/listen" ->
          Process.flag(:trap_exit, true)

          conn =
            Plug.Conn.put_resp_header(conn, "content-type", "text/event-stream; charset=utf-8")

          conn = Plug.Conn.send_chunked(conn, 200)
          send(test_pid, {:listen_connection, self(), request["id"]})
          stream_commands(conn, test_pid)

        "ping" ->
          conn = Plug.Conn.put_resp_header(conn, "content-type", "application/json")

          Plug.Conn.resp(
            conn,
            200,
            JSON.encode!(%{
              "jsonrpc" => "2.0",
              "id" => request["id"],
              "result" => %{"resultType" => "complete"}
            })
          )

        "notifications/cancelled" ->
          send(test_pid, :unexpected_http_cancellation)
          Plug.Conn.resp(conn, 202, "")
      end
    end)

    {:ok, transport} = start_transport(bypass, receive_timeout: 50, request_timeout: 50)
    flush_negotiate()

    {encoded, context} = listen_request("listen-http")

    assert {:ok, stream} =
             StreamableHTTP.open_stream(transport, encoded,
               owner: self(),
               request_context: context,
               subscription_id: "listen-http",
               timeout: 1_000
             )

    assert_receive {:listen_connection, server, "listen-http"}
    assert Process.alive?(stream)

    Process.sleep(100)
    assert Process.alive?(stream)
    refute_receive {:mcp_stream_error, ^stream, _reason}

    ping = request("ping", "ordinary", %{})

    assert :ok =
             StreamableHTTP.send_message(transport, JSON.encode!(ping),
               timeout: 1_000,
               request_context: context("ping", %{})
             )

    assert_receive {:http_method, "ping"}

    assert_receive {:"$gen_cast", {:response, ping_response}}
    assert JSON.decode!(ping_response)["id"] == "ordinary"
    assert Process.alive?(stream)

    send_chunk(server, ": keepalive\r\n\r\n")
    refute_receive {:"$gen_cast", {:response, _}}, 20

    wrong = notification("notifications/tools/list_changed", "sibling", %{"revision" => 1})

    missing = %{
      "jsonrpc" => "2.0",
      "method" => "notifications/tools/list_changed",
      "params" => %{}
    }

    ordinary = %{
      "jsonrpc" => "2.0",
      "id" => "ordinary-on-stream",
      "result" => %{"resultType" => "complete"}
    }

    for message <- [wrong, missing, ordinary] do
      send_chunk(server, "data: " <> JSON.encode!(message) <> "\n\n")
    end

    refute_receive {:mcp_stream_message, ^stream, "listen-http", _message}, 30
    refute_receive {:"$gen_cast", {:response, _message}}, 30

    ack =
      notification("notifications/subscriptions/acknowledged", "listen-http", %{
        "notifications" => %{}
      })

    ack_wire = "data: " <> JSON.encode!(ack) <> "\r\n\r\n"
    {first, second} = String.split_at(ack_wire, byte_size(ack_wire) - 3)
    send_chunk(server, first)
    refute_receive {:"$gen_cast", {:response, _}}, 20
    send_chunk(server, second)

    assert_receive {:mcp_stream_message, ^stream, "listen-http", ^ack}

    event = notification("notifications/tools/list_changed", "listen-http", %{"revision" => 3})
    event_wire = "event: message\rdata: " <> JSON.encode!(event) <> "\r\r"
    {one, rest} = String.split_at(event_wire, 9)
    {two, three} = String.split_at(rest, 17)
    Enum.each([one, two, three], &send_chunk(server, &1))

    assert_receive {:mcp_stream_message, ^stream, "listen-http", ^event}
    refute_receive {:"$gen_cast", {:response, _message}}, 20

    monitor = Process.monitor(stream)
    assert :ok = StreamableHTTP.close_stream(transport, stream, reason: "done", timeout: 100)
    assert_receive {:DOWN, ^monitor, :process, ^stream, :normal}
    refute_receive :unexpected_http_cancellation, 50

    stop_transport(transport)
    assert :ok = Bypass.down(bypass)
  end

  test "delivers a final response before the clean EOF terminal from the same stream", %{
    bypass: bypass
  } do
    test_pid = self()

    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = JSON.decode!(body)
      Process.flag(:trap_exit, true)
      conn = Plug.Conn.put_resp_header(conn, "content-type", "text/event-stream")
      conn = Plug.Conn.send_chunked(conn, 200)
      send(test_pid, {:listen_connection, self(), request["id"]})
      stream_commands(conn, test_pid)
    end)

    {:ok, transport} = start_transport(bypass)
    flush_negotiate()
    {encoded, context} = listen_request("ordered-final")

    assert {:ok, stream} =
             StreamableHTTP.open_stream(transport, encoded,
               owner: self(),
               request_context: context,
               subscription_id: "ordered-final",
               timeout: 500
             )

    assert_receive {:listen_connection, server, "ordered-final"}

    final = %{
      "jsonrpc" => "2.0",
      "id" => "ordered-final",
      "result" => %{
        "resultType" => "complete",
        "_meta" => %{@subscription_id_key => "ordered-final"}
      }
    }

    send_chunk(server, "data: " <> JSON.encode!(final) <> "\n\n")
    send(server, :finish)

    assert_receive {:mcp_stream_message, ^stream, "ordered-final", ^final}
    assert_receive {:mcp_stream_closed, ^stream, :normal}
    refute_receive {:mcp_stream_error, ^stream, _reason}, 30
    refute_receive {:"$gen_cast", {:response, _message}}, 30

    stop_transport(transport)
    assert :ok = Bypass.down(bypass)
  end

  test "resolves rotating provider headers for every request-scoped stream", %{
    bypass: bypass
  } do
    counter = start_supervised!({Agent, fn -> 0 end})
    test_pid = self()

    provider = fn ->
      value = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
      {:ok, %{"authorization" => "Bearer token-#{value}"}}
    end

    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = JSON.decode!(body)
      [authorization] = Plug.Conn.get_req_header(conn, "authorization")
      ["one"] = Plug.Conn.get_req_header(conn, "x-static")
      send(test_pid, {:stream_authorization, request["id"], authorization})

      final = %{
        "jsonrpc" => "2.0",
        "id" => request["id"],
        "result" => %{
          "resultType" => "complete",
          "_meta" => %{@subscription_id_key => request["id"]}
        }
      }

      conn = Plug.Conn.put_resp_header(conn, "content-type", "text/event-stream")
      Plug.Conn.resp(conn, 200, "data: " <> JSON.encode!(final) <> "\n\n")
    end)

    {:ok, transport} =
      StreamableHTTP.start_link(
        client: self(),
        base_url: "http://localhost:#{bypass.port}",
        mcp_path: "/mcp",
        headers: %{"authorization" => "Bearer old", "x-static" => "one"},
        headers_provider: provider,
        transport_opts: @test_http_opts,
        http_options: [receive_timeout: 5_000]
      )

    flush_negotiate()

    for {id, token} <- [{"stream-one", "Bearer token-1"}, {"stream-two", "Bearer token-2"}] do
      {encoded, context} = listen_request(id)

      assert {:ok, stream} =
               StreamableHTTP.open_stream(transport, encoded,
                 owner: self(),
                 request_context: context,
                 subscription_id: id,
                 timeout: 500
               )

      assert_receive {:stream_authorization, ^id, ^token}
      assert_receive {:mcp_stream_message, ^stream, ^id, %{"id" => ^id}}
      assert_receive {:mcp_stream_closed, ^stream, :normal}
    end

    stop_transport(transport)
  end

  test "killing a stream controller terminates its exact Finch worker", %{bypass: bypass} do
    test_pid = self()

    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      {:ok, _body, conn} = Plug.Conn.read_body(conn)
      Process.flag(:trap_exit, true)
      conn = Plug.Conn.put_resp_header(conn, "content-type", "text/event-stream")
      conn = Plug.Conn.send_chunked(conn, 200)
      send(test_pid, {:listen_connection, self()})
      stream_commands(conn, test_pid)
    end)

    {:ok, transport} = start_transport(bypass)
    flush_negotiate()
    {encoded, context} = listen_request("kill-controller")

    assert {:ok, stream} =
             StreamableHTTP.open_stream(transport, encoded,
               owner: self(),
               request_context: context,
               subscription_id: "kill-controller",
               timeout: 500
             )

    assert_receive {:listen_connection, _server}
    %{worker: worker, worker_monitor: worker_monitor} = :sys.get_state(stream)
    assert is_reference(worker_monitor)
    stream_monitor = Process.monitor(stream)
    worker_monitor = Process.monitor(worker)

    Process.exit(stream, :kill)

    assert_receive {:DOWN, ^stream_monitor, :process, ^stream, :killed}
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _reason}

    stop_transport(transport)
    assert :ok = Bypass.down(bypass)
  end

  test "halts an unterminated SSE frame at the bounded buffer limit", %{bypass: bypass} do
    test_pid = self()

    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      {:ok, _body, conn} = Plug.Conn.read_body(conn)
      Process.flag(:trap_exit, true)
      conn = Plug.Conn.put_resp_header(conn, "content-type", "text/event-stream")
      conn = Plug.Conn.send_chunked(conn, 200)
      send(test_pid, {:listen_connection, self()})
      stream_commands(conn, test_pid)
    end)

    {:ok, transport} = start_transport(bypass)
    flush_negotiate()
    {encoded, context} = listen_request("bounded-buffer")

    assert {:ok, stream} =
             StreamableHTTP.open_stream(transport, encoded,
               owner: self(),
               request_context: context,
               subscription_id: "bounded-buffer",
               timeout: 500
             )

    assert_receive {:listen_connection, server}
    send_chunk(server, String.duplicate("x", 1_048_577))
    assert_receive {:mcp_stream_error, ^stream, :sse_buffer_too_large}

    stop_transport(transport)
    assert :ok = Bypass.down(bypass)
  end

  test "rejects non-SSE and non-success responses once without delivering body data", %{
    bypass: bypass
  } do
    test_pid = self()

    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = JSON.decode!(body)
      send(test_pid, {:attempt, request["id"]})

      case request["id"] do
        "json-body" ->
          conn = Plug.Conn.put_resp_header(conn, "content-type", "application/json")

          Plug.Conn.resp(
            conn,
            200,
            JSON.encode!(notification("notifications/tools/list_changed", "json-body", %{}))
          )

        "server-error" ->
          conn = Plug.Conn.put_resp_header(conn, "content-type", "text/event-stream")
          Plug.Conn.resp(conn, 500, "data: must-not-deliver\n\n")
      end
    end)

    {:ok, transport} = start_transport(bypass)
    flush_negotiate()

    for {id, expected} <- [
          {"json-body", {:unsupported_content_type, "application/json"}},
          {"server-error", {:http_error, 500}}
        ] do
      {encoded, context} = listen_request(id)

      assert {:ok, stream} =
               StreamableHTTP.open_stream(transport, encoded,
                 owner: self(),
                 request_context: context,
                 subscription_id: id,
                 timeout: 500
               )

      assert_receive {:mcp_stream_error, ^stream, ^expected}
      assert_receive {:attempt, ^id}
      refute_receive {:attempt, ^id}, 50
      refute_receive {:"$gen_cast", {:response, _}}, 20
      refute_receive {:mcp_stream_error, ^stream, {:stream_worker_down, _reason}}, 20
    end

    stop_transport(transport)
  end

  defp start_transport(bypass, http_options \\ [receive_timeout: 5_000]) do
    StreamableHTTP.start_link(
      client: self(),
      base_url: "http://localhost:#{bypass.port}",
      mcp_path: "/mcp",
      transport_opts: @test_http_opts,
      http_options: http_options
    )
  end

  defp listen_request(id) do
    params = modern_params(%{"notifications" => %{}})

    {JSON.encode!(request("subscriptions/listen", id, params)),
     context("subscriptions/listen", params)}
  end

  defp request(method, id, params) do
    %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => modern_params(params)}
  end

  defp notification(method, subscription_id, params) do
    params = Map.put(params, "_meta", %{@subscription_id_key => subscription_id})
    %{"jsonrpc" => "2.0", "method" => method, "params" => params}
  end

  defp context(method, params) do
    {:ok, profile} = Registry.profile(@version)

    %RequestContext{
      profile: profile,
      era: :modern,
      lifecycle: :per_request,
      protocol_version: @version,
      method: method,
      params: modern_params(params),
      parameter_headers: %{}
    }
  end

  defp modern_params(params) do
    Map.put_new(params, "_meta", %{
      "io.modelcontextprotocol/protocolVersion" => @version,
      "io.modelcontextprotocol/clientCapabilities" => %{}
    })
  end

  defp stream_commands(conn, test_pid) do
    receive do
      {:chunk, data, caller} ->
        case Plug.Conn.chunk(conn, data) do
          {:ok, conn} ->
            send(caller, {:chunked, :ok})
            stream_commands(conn, test_pid)

          {:error, reason} ->
            send(caller, {:chunked, {:error, reason}})
            conn
        end

      :finish ->
        send(test_pid, :listen_finished)
        conn

      {:EXIT, _pid, _reason} ->
        conn
    end
  end

  defp send_chunk(server, data) do
    send(server, {:chunk, data, self()})
    assert_receive {:chunked, :ok}
  end

  defp flush_negotiate do
    receive do
      {:"$gen_cast", :negotiate} -> :ok
    after
      100 -> :ok
    end
  end

  defp stop_transport(transport) do
    monitor = Process.monitor(transport)
    StreamableHTTP.shutdown(transport)
    assert_receive {:DOWN, ^monitor, :process, ^transport, :normal}
  end
end

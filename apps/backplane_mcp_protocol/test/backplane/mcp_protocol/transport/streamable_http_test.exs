defmodule Backplane.McpProtocol.Transport.StreamableHTTPTest do
  use ExUnit.Case, async: false

  alias Backplane.McpProtocol.Client
  alias Backplane.McpProtocol.MCP.Error
  alias Backplane.McpProtocol.MCP.Message
  alias Backplane.McpProtocol.MCP.Response
  alias Backplane.McpProtocol.Protocol
  alias Backplane.McpProtocol.Transport.StreamableHTTP

  @moduletag capture_log: true
  @test_http_opts [max_reconnections: 0]

  setup do
    bypass = Bypass.open()
    Process.group_leader(self(), self())

    {:ok, bypass: bypass}
  end

  describe "start_link/1" do
    test "successfully starts with valid options", %{bypass: bypass} do
      server_url = "http://localhost:#{bypass.port}"

      {:ok, stub_client} = StubClient.start_link()
      :ok = StubClient.subscribe()

      {:ok, transport} =
        StreamableHTTP.start_link(
          client: stub_client,
          base_url: server_url,
          mcp_path: "/mcp",
          transport_opts: @test_http_opts
        )

      assert Process.alive?(transport)

      state = :sys.get_state(transport)
      assert state.mcp_url.path == "/mcp"
      assert state.session_id == nil
      assert_receive {:stub_client_signal, :negotiate}, 500
      assert :negotiate in StubClient.get_signals()
      refute :initialize in StubClient.get_signals()

      StreamableHTTP.shutdown(transport)
      StubClient.clear_messages()
    end

    test "uses default mcp_path when not specified", %{bypass: bypass} do
      server_url = "http://localhost:#{bypass.port}"
      {:ok, stub_client} = StubClient.start_link()

      {:ok, transport} =
        StreamableHTTP.start_link(
          client: stub_client,
          base_url: server_url,
          transport_opts: @test_http_opts
        )

      _state = :sys.get_state(transport)

      StreamableHTTP.shutdown(transport)
      StubClient.clear_messages()
    end

    test "accepts an exact MCP endpoint URL without appending mcp_path", %{bypass: bypass} do
      url = "http://localhost:#{bypass.port}/custom/mcp?tenant=one"
      {:ok, stub_client} = StubClient.start_link()

      {:ok, transport} =
        StreamableHTTP.start_link(
          client: stub_client,
          url: url,
          transport_opts: @test_http_opts
        )

      assert ^url = transport |> :sys.get_state() |> Map.fetch!(:mcp_url) |> URI.to_string()

      StreamableHTTP.shutdown(transport)
      StubClient.clear_messages()
    end

    test "raises when neither url nor base_url is supplied" do
      {:ok, stub_client} = StubClient.start_link()

      assert_raise ArgumentError, ~r/url or base_url/, fn ->
        StreamableHTTP.start_link(client: stub_client, transport_opts: @test_http_opts)
      end

      StubClient.clear_messages()
    end

    test "raises when both url and base_url are supplied", %{bypass: bypass} do
      {:ok, stub_client} = StubClient.start_link()

      assert_raise ArgumentError, ~r/only one of url or base_url/, fn ->
        StreamableHTTP.start_link(
          client: stub_client,
          url: "http://localhost:#{bypass.port}/custom/mcp",
          base_url: "http://localhost:#{bypass.port}",
          transport_opts: @test_http_opts
        )
      end

      StubClient.clear_messages()
    end
  end

  test "advertises every compatible modern and legacy protocol version" do
    assert StreamableHTTP.supported_protocol_versions() == [
             "2026-07-28",
             "2025-11-25",
             "2025-06-18",
             "2025-03-26"
           ]
  end

  test "accepts the Client default protocol version when it is omitted" do
    assert {:ok, client} =
             Client.start_link_server(
               name: :default_streamable_http_client_validation,
               transport: [layer: StreamableHTTP, name: :unused_streamable_http_transport],
               client_info: %{"name" => "DefaultHTTPClient", "version" => "1.0.0"},
               capabilities: %{}
             )

    assert :sys.get_state(client).protocol_preference == :auto
    GenServer.stop(client)
  end

  describe "client negotiation integration" do
    test "an unrecognized HTTP 400 falls back to legacy initialize", %{bypass: bypass} do
      test_pid = self()

      Bypass.stub(bypass, "POST", "/mcp", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = JSON.decode!(body)
        send(test_pid, {:negotiation_request, request["method"]})

        case request["method"] do
          "server/discover" ->
            Plug.Conn.resp(conn, 400, "legacy endpoint")

          "initialize" ->
            conn = Plug.Conn.put_resp_header(conn, "content-type", "application/json")

            Plug.Conn.resp(
              conn,
              200,
              JSON.encode!(%{
                "jsonrpc" => "2.0",
                "id" => request["id"],
                "result" => %{
                  "protocolVersion" => "2025-03-26",
                  "capabilities" => %{"tools" => %{}},
                  "serverInfo" => %{"name" => "LegacyHTTP", "version" => "1.0.0"}
                }
              })
            )

          "notifications/initialized" ->
            Plug.Conn.resp(conn, 202, "")
        end
      end)

      {client, transport} = start_http_negotiation_client(bypass, :fallback)

      assert :ok = Client.await_ready(client, timeout: 2_000)
      assert :sys.get_state(client).timeout == 1_000
      assert_receive {:negotiation_request, "server/discover"}
      assert_receive {:negotiation_request, "initialize"}
      assert_receive {:negotiation_request, "notifications/initialized"}

      assert %{
               negotiation_status: :ready,
               era: :legacy,
               negotiated_version: "2025-03-26"
             } = Client.get_protocol_info(client)

      assert Process.alive?(client)
      assert Process.alive?(transport)
    end

    for status <- [200, 400] do
      test "method not found over HTTP #{status} falls back through tools/list", %{bypass: bypass} do
        test_pid = self()
        fallback_version = Protocol.fallback_version()

        echo_tool = %{
          "name" => "echo",
          "description" => "Echo input",
          "inputSchema" => %{"type" => "object", "additionalProperties" => true}
        }

        Bypass.stub(bypass, "POST", "/mcp", fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          request = JSON.decode!(body)
          send(test_pid, {:negotiation_request, request["method"]})

          conn = Plug.Conn.put_resp_header(conn, "content-type", "application/json")

          case request["method"] do
            "server/discover" ->
              Plug.Conn.resp(
                conn,
                unquote(status),
                JSON.encode!(%{
                  "jsonrpc" => "2.0",
                  "id" => request["id"],
                  "error" => %{"code" => -32_601, "message" => "Method not found"}
                })
              )

            "initialize" ->
              assert request["params"]["protocolVersion"] == fallback_version

              Plug.Conn.resp(
                conn,
                200,
                JSON.encode!(%{
                  "jsonrpc" => "2.0",
                  "id" => request["id"],
                  "result" => %{
                    "protocolVersion" => fallback_version,
                    "capabilities" => %{"tools" => %{}},
                    "serverInfo" => %{"name" => "LegacyHTTP", "version" => "1.0.0"}
                  }
                })
              )

            "notifications/initialized" ->
              Plug.Conn.resp(conn, 202, "")

            "tools/list" ->
              Plug.Conn.resp(
                conn,
                200,
                JSON.encode!(%{
                  "jsonrpc" => "2.0",
                  "id" => request["id"],
                  "result" => %{"tools" => [echo_tool]}
                })
              )
          end
        end)

        {client, transport} = start_http_negotiation_client(bypass, unquote(status))

        assert :ok = Client.await_ready(client, timeout: 2_000)

        assert %{
                 negotiation_status: :ready,
                 era: :legacy,
                 protocol_version: ^fallback_version,
                 negotiated_version: ^fallback_version
               } = Client.get_protocol_info(client)

        assert {:ok, %Response{result: %{"tools" => [^echo_tool]}}} =
                 Client.list_tools(client, timeout: 2_000)

        methods =
          for _index <- 1..4 do
            assert_receive {:negotiation_request, method}
            method
          end

        assert methods == [
                 "server/discover",
                 "initialize",
                 "notifications/initialized",
                 "tools/list"
               ]

        refute_receive {:negotiation_request, _extra_method}, 50
        assert Process.alive?(client)
        assert Process.alive?(transport)
      end
    end

    test "HTTP 400 method not found with a mismatched id stays modern", %{bypass: bypass} do
      test_pid = self()

      Bypass.stub(bypass, "POST", "/mcp", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = JSON.decode!(body)
        send(test_pid, {:negotiation_request, request["method"]})

        conn = Plug.Conn.put_resp_header(conn, "content-type", "application/json")

        case request["method"] do
          "server/discover" ->
            Plug.Conn.resp(
              conn,
              400,
              JSON.encode!(%{
                "jsonrpc" => "2.0",
                "id" => "different-request",
                "error" => %{"code" => -32_601, "message" => "Method not found"}
              })
            )

          _unexpected_method ->
            Plug.Conn.resp(conn, 500, "unexpected negotiation request")
        end
      end)

      {client, transport} = start_http_negotiation_client(bypass, :mismatched_response)

      assert {:error, %Error{reason: :send_failure}} =
               Client.await_ready(client, timeout: 2_000)

      assert_receive {:negotiation_request, method}
      assert method == "server/discover"
      refute_receive {:negotiation_request, _other_method}, 50

      assert %{negotiation_status: :failed, era: :modern, negotiated_version: nil} =
               Client.get_protocol_info(client)

      assert Process.alive?(client)
      assert Process.alive?(transport)
    end

    test "HTTP 400 hybrid result and error response stays modern", %{bypass: bypass} do
      test_pid = self()

      Bypass.stub(bypass, "POST", "/mcp", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = JSON.decode!(body)
        send(test_pid, {:negotiation_request, request["method"]})

        conn = Plug.Conn.put_resp_header(conn, "content-type", "application/json")

        case request["method"] do
          "server/discover" ->
            Plug.Conn.resp(
              conn,
              400,
              JSON.encode!(%{
                "jsonrpc" => "2.0",
                "id" => request["id"],
                "result" => %{},
                "error" => %{"code" => -32_601, "message" => "Method not found"}
              })
            )

          _unexpected_method ->
            Plug.Conn.resp(conn, 500, "unexpected negotiation request")
        end
      end)

      {client, transport} = start_http_negotiation_client(bypass, :hybrid_response)

      assert {:error, %Error{reason: :send_failure}} =
               Client.await_ready(client, timeout: 2_000)

      assert_receive {:negotiation_request, method}
      assert method == "server/discover"
      refute_receive {:negotiation_request, _other_method}, 50

      assert %{negotiation_status: :failed, era: :modern, negotiated_version: nil} =
               Client.get_protocol_info(client)

      assert Process.alive?(client)
      assert Process.alive?(transport)
    end

    test "a pinned modern client surfaces method not found from HTTP 400", %{bypass: bypass} do
      test_pid = self()

      Bypass.expect_once(bypass, "POST", "/mcp", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = JSON.decode!(body)
        send(test_pid, {:negotiation_request, request["method"]})

        Plug.Conn.resp(
          conn,
          400,
          JSON.encode!(%{
            "jsonrpc" => "2.0",
            "id" => request["id"],
            "error" => %{"code" => -32_601, "message" => "Method not found"}
          })
        )
      end)

      {client, transport} =
        start_http_negotiation_client(bypass, :recognized_error, "2026-07-28")

      assert {:error, %Error{reason: :method_not_found}} =
               Client.await_ready(client, timeout: 2_000)

      assert_receive {:negotiation_request, method}
      assert method == "server/discover"
      refute_receive {:negotiation_request, _other_method}, 50

      assert %{negotiation_status: :failed, era: :modern, negotiated_version: nil} =
               Client.get_protocol_info(client)

      assert Process.alive?(client)
      assert Process.alive?(transport)
    end
  end

  describe "send_message/3" do
    test "sends HTTP POST request with JSON response", %{bypass: bypass} do
      server_url = "http://localhost:#{bypass.port}"
      {:ok, stub_client} = StubClient.start_link()

      Bypass.expect(bypass, "POST", "/mcp", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        assert body =~ "ping"

        conn = Plug.Conn.put_resp_header(conn, "content-type", "application/json")
        Plug.Conn.resp(conn, 200, ~s|{"jsonrpc":"2.0","id":"1","result":{}}|)
      end)

      {:ok, transport} =
        StreamableHTTP.start_link(
          client: stub_client,
          base_url: server_url,
          mcp_path: "/mcp",
          transport_opts: @test_http_opts
        )

      {:ok, ping_message} =
        Message.encode_request(%{"method" => "ping", "params" => %{}}, "1")

      assert :ok = StreamableHTTP.send_message(transport, ping_message, timeout: 5000)

      messages = StubClient.get_messages()
      refute Enum.empty?(messages)
      assert List.first(messages) =~ "result"

      StreamableHTTP.shutdown(transport)
      StubClient.clear_messages()
    end

    test "handles 202 Accepted response", %{bypass: bypass} do
      server_url = "http://localhost:#{bypass.port}"
      {:ok, stub_client} = StubClient.start_link()

      Bypass.expect(bypass, "POST", "/mcp", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert body =~ "initialized"

        Plug.Conn.resp(conn, 202, "")
      end)

      {:ok, transport} =
        StreamableHTTP.start_link(
          client: stub_client,
          base_url: server_url,
          mcp_path: "/mcp",
          transport_opts: @test_http_opts
        )

      notification = ~s|{"jsonrpc":"2.0","method":"notifications/initialized"}|
      assert :ok = StreamableHTTP.send_message(transport, notification, timeout: 5000)

      StreamableHTTP.shutdown(transport)
      StubClient.clear_messages()
    end

    test "handles SSE response", %{bypass: bypass} do
      server_url = "http://localhost:#{bypass.port}"
      {:ok, stub_client} = StubClient.start_link()

      Bypass.expect(bypass, "POST", "/mcp", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert body =~ "ping"

        conn = Plug.Conn.put_resp_header(conn, "content-type", "text/event-stream")
        sse_data = ~s(data: {"jsonrpc":"2.0","id":"1","result":{}}\n\n)
        Plug.Conn.resp(conn, 200, sse_data)
      end)

      {:ok, transport} =
        StreamableHTTP.start_link(
          client: stub_client,
          base_url: server_url,
          mcp_path: "/mcp",
          transport_opts: @test_http_opts
        )

      {:ok, ping_message} =
        Message.encode_request(%{"method" => "ping", "params" => %{}}, "1")

      assert :ok = StreamableHTTP.send_message(transport, ping_message, timeout: 5000)

      messages = StubClient.get_messages()
      refute Enum.empty?(messages)

      StreamableHTTP.shutdown(transport)
      StubClient.clear_messages()
    end

    test "handles HTTP error responses", %{bypass: bypass} do
      server_url = "http://localhost:#{bypass.port}"
      {:ok, stub_client} = StubClient.start_link()

      Bypass.expect(bypass, "POST", "/mcp", fn conn ->
        Plug.Conn.resp(conn, 500, "Internal Server Error")
      end)

      {:ok, transport} =
        StreamableHTTP.start_link(
          client: stub_client,
          base_url: server_url,
          mcp_path: "/mcp",
          transport_opts: @test_http_opts
        )

      assert {:error, {:http_error, 500, "Internal Server Error"}} =
               StreamableHTTP.send_message(transport, "test message", timeout: 5000)

      StreamableHTTP.shutdown(transport)
      StubClient.clear_messages()
    end

    test "handles unsupported content type", %{bypass: bypass} do
      server_url = "http://localhost:#{bypass.port}"
      {:ok, stub_client} = StubClient.start_link()

      Bypass.expect(bypass, "POST", "/mcp", fn conn ->
        conn = Plug.Conn.put_resp_header(conn, "content-type", "text/html")
        Plug.Conn.resp(conn, 200, "<html>Not JSON or SSE</html>")
      end)

      {:ok, transport} =
        StreamableHTTP.start_link(
          client: stub_client,
          base_url: server_url,
          mcp_path: "/mcp",
          transport_opts: @test_http_opts
        )

      assert {:error, {:unsupported_content_type, "text/html"}} =
               StreamableHTTP.send_message(transport, "test message", timeout: 5000)

      StreamableHTTP.shutdown(transport)
      StubClient.clear_messages()
    end
  end

  describe "session management" do
    test "handles session ID from response headers", %{bypass: bypass} do
      server_url = "http://localhost:#{bypass.port}"
      {:ok, stub_client} = StubClient.start_link()
      session_id = "test-session-123"

      Bypass.expect_once(bypass, "POST", "/mcp", fn conn ->
        conn =
          conn
          |> Plug.Conn.put_resp_header("content-type", "application/json")
          |> Plug.Conn.put_resp_header("mcp-session-id", session_id)

        Plug.Conn.resp(conn, 200, ~s|{"jsonrpc":"2.0","id":"1","result":{}}|)
      end)

      Bypass.expect(bypass, "DELETE", "/mcp", fn conn ->
        assert [^session_id] = Plug.Conn.get_req_header(conn, "mcp-session-id")
        Plug.Conn.resp(conn, 200, "")
      end)

      {:ok, transport} =
        StreamableHTTP.start_link(
          client: stub_client,
          base_url: server_url,
          mcp_path: "/mcp",
          transport_opts: @test_http_opts
        )

      {:ok, ping_message} =
        Message.encode_request(%{"method" => "ping", "params" => %{}}, "1")

      assert :ok = StreamableHTTP.send_message(transport, ping_message, timeout: 5000)

      state = :sys.get_state(transport)
      assert state.session_id == session_id

      StreamableHTTP.shutdown(transport)
      StubClient.clear_messages()
    end

    test "includes session ID in subsequent requests", %{bypass: bypass} do
      server_url = "http://localhost:#{bypass.port}"
      {:ok, stub_client} = StubClient.start_link()
      session_id = "test-session-456"

      Bypass.stub(bypass, "POST", "/mcp", fn conn ->
        session_headers = Plug.Conn.get_req_header(conn, "mcp-session-id")

        case session_headers do
          [] ->
            conn =
              conn
              |> Plug.Conn.put_resp_header("content-type", "application/json")
              |> Plug.Conn.put_resp_header("mcp-session-id", session_id)

            Plug.Conn.resp(conn, 200, ~s|{"jsonrpc":"2.0","id":"1","result":{}}|)

          [^session_id] ->
            conn =
              Plug.Conn.put_resp_header(conn, "content-type", "application/json")

            Plug.Conn.resp(conn, 200, ~s|{"jsonrpc":"2.0","id":"2","result":{}}|)
        end
      end)

      Bypass.stub(bypass, "DELETE", "/mcp", fn conn ->
        assert [^session_id] = Plug.Conn.get_req_header(conn, "mcp-session-id")
        Plug.Conn.resp(conn, 200, "")
      end)

      {:ok, transport} =
        StreamableHTTP.start_link(
          client: stub_client,
          base_url: server_url,
          mcp_path: "/mcp",
          transport_opts: @test_http_opts
        )

      {:ok, first_message} =
        Message.encode_request(%{"method" => "ping", "params" => %{}}, "1")

      assert :ok = StreamableHTTP.send_message(transport, first_message, timeout: 5000)

      {:ok, second_message} =
        Message.encode_request(%{"method" => "ping", "params" => %{}}, "2")

      assert :ok = StreamableHTTP.send_message(transport, second_message, timeout: 5000)

      StreamableHTTP.shutdown(transport)
      StubClient.clear_messages()
    end
  end

  describe "headers and options" do
    test "passes custom headers to requests", %{bypass: bypass} do
      server_url = "http://localhost:#{bypass.port}"
      {:ok, stub_client} = StubClient.start_link()

      Bypass.expect(bypass, "POST", "/mcp", fn conn ->
        assert "auth-token" ==
                 conn |> Plug.Conn.get_req_header("authorization") |> List.first()

        # Every POST must advertise both content types per the MCP spec
        assert_dual_accept(conn)

        conn = Plug.Conn.put_resp_header(conn, "content-type", "application/json")
        Plug.Conn.resp(conn, 200, ~s|{"jsonrpc":"2.0","id":"1","result":{}}|)
      end)

      {:ok, transport} =
        StreamableHTTP.start_link(
          client: stub_client,
          base_url: server_url,
          mcp_path: "/mcp",
          headers: %{
            "authorization" => "auth-token"
          },
          transport_opts: @test_http_opts
        )

      {:ok, ping_message} =
        Message.encode_request(%{"method" => "ping", "params" => %{}}, "1")

      assert :ok = StreamableHTTP.send_message(transport, ping_message, timeout: 5000)

      StreamableHTTP.shutdown(transport)
      StubClient.clear_messages()
    end

    test "resolves rotating provider headers for every POST", %{bypass: bypass} do
      server_url = "http://localhost:#{bypass.port}"
      {:ok, stub_client} = StubClient.start_link()
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
        send(test_pid, {:post_authorization, request["id"], authorization})

        conn = Plug.Conn.put_resp_header(conn, "content-type", "application/json")
        Plug.Conn.resp(conn, 200, ~s|{"jsonrpc":"2.0","id":"#{request["id"]}","result":{}}|)
      end)

      {:ok, transport} =
        StreamableHTTP.start_link(
          client: stub_client,
          base_url: server_url,
          mcp_path: "/mcp",
          headers: %{"authorization" => "Bearer old", "x-static" => "one"},
          headers_provider: provider,
          transport_opts: @test_http_opts
        )

      for id <- ["1", "2"] do
        {:ok, ping} = Message.encode_request(%{"method" => "ping", "params" => %{}}, id)
        assert :ok = StreamableHTTP.send_message(transport, ping, timeout: 5_000)
      end

      assert_receive {:post_authorization, "1", "Bearer token-1"}
      assert_receive {:post_authorization, "2", "Bearer token-2"}

      StreamableHTTP.shutdown(transport)
      StubClient.clear_messages()
    end

    test "returns a sanitized POST error for an invalid headers provider", %{bypass: bypass} do
      server_url = "http://localhost:#{bypass.port}"
      {:ok, stub_client} = StubClient.start_link()

      {:ok, transport} =
        StreamableHTTP.start_link(
          client: stub_client,
          base_url: server_url,
          mcp_path: "/mcp",
          headers_provider: :not_a_function,
          transport_opts: @test_http_opts
        )

      {:ok, ping} = Message.encode_request(%{"method" => "ping", "params" => %{}}, "invalid-provider")

      assert {:error, :invalid_headers_provider_result} =
               StreamableHTTP.send_message(transport, ping, timeout: 5_000)

      assert Process.alive?(transport)

      StreamableHTTP.shutdown(transport)
      StubClient.clear_messages()
    end

    test "resolves rotating provider headers for legacy GET and DELETE", %{bypass: bypass} do
      server_url = "http://localhost:#{bypass.port}"
      {:ok, stub_client} = StubClient.start_link()
      counter = start_supervised!({Agent, fn -> 0 end})
      session_id = "rotating-header-session"
      test_pid = self()

      provider = fn ->
        value = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
        {:ok, %{"authorization" => "Bearer token-#{value}"}}
      end

      Bypass.stub(bypass, "POST", "/mcp", fn conn ->
        [authorization] = Plug.Conn.get_req_header(conn, "authorization")
        send(test_pid, {:post_authorization, authorization})

        conn =
          conn
          |> Plug.Conn.put_resp_header("content-type", "application/json")
          |> Plug.Conn.put_resp_header("mcp-session-id", session_id)

        Plug.Conn.resp(conn, 200, ~s|{"jsonrpc":"2.0","id":"1","result":{}}|)
      end)

      Bypass.stub(bypass, "GET", "/mcp", fn conn ->
        [authorization] = Plug.Conn.get_req_header(conn, "authorization")
        [^session_id] = Plug.Conn.get_req_header(conn, "mcp-session-id")
        send(test_pid, {:get_authorization, authorization, self()})

        receive do
          :finish -> Plug.Conn.resp(conn, 405, "")
        after
          5_000 -> Plug.Conn.resp(conn, 405, "")
        end
      end)

      Bypass.stub(bypass, "DELETE", "/mcp", fn conn ->
        [authorization] = Plug.Conn.get_req_header(conn, "authorization")
        [^session_id] = Plug.Conn.get_req_header(conn, "mcp-session-id")
        send(test_pid, {:delete_authorization, authorization})
        Plug.Conn.resp(conn, 200, "")
      end)

      {:ok, transport} =
        StreamableHTTP.start_link(
          client: stub_client,
          base_url: server_url,
          mcp_path: "/mcp",
          enable_sse: true,
          headers: %{"authorization" => "Bearer old"},
          headers_provider: provider,
          transport_opts: @test_http_opts
        )

      {:ok, ping} = Message.encode_request(%{"method" => "ping", "params" => %{}}, "1")
      assert :ok = StreamableHTTP.send_message(transport, ping, timeout: 5_000)

      assert_receive {:post_authorization, "Bearer token-1"}
      assert_receive {:get_authorization, "Bearer token-2", get_server}

      :sys.replace_state(transport, &Map.put(&1, :enable_sse, false))
      sse_task = :sys.get_state(transport).sse_task
      sse_monitor = Process.monitor(sse_task)
      send(get_server, :finish)
      assert_receive {:DOWN, ^sse_monitor, :process, ^sse_task, _reason}

      monitor = Process.monitor(transport)
      StreamableHTTP.shutdown(transport)
      assert_receive {:delete_authorization, "Bearer token-3"}
      assert_receive {:DOWN, ^monitor, :process, ^transport, :normal}
      StubClient.clear_messages()
    end

    test "backs off legacy SSE retries when request headers cannot be resolved", %{bypass: bypass} do
      server_url = "http://localhost:#{bypass.port}"
      {:ok, stub_client} = StubClient.start_link()
      counter = start_supervised!({Agent, fn -> 0 end})
      session_id = "headers-retry-session"
      test_pid = self()

      provider = fn ->
        call = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
        send(test_pid, {:headers_provider_call, call})

        if call == 1 do
          {:ok, %{"authorization" => "Bearer initial"}}
        else
          {:error, :credential_unavailable}
        end
      end

      Bypass.stub(bypass, "POST", "/mcp", fn conn ->
        conn =
          conn
          |> Plug.Conn.put_resp_header("content-type", "application/json")
          |> Plug.Conn.put_resp_header("mcp-session-id", session_id)

        Plug.Conn.resp(conn, 200, ~s|{"jsonrpc":"2.0","id":"1","result":{}}|)
      end)

      {:ok, transport} =
        StreamableHTTP.start_link(
          client: stub_client,
          base_url: server_url,
          mcp_path: "/mcp",
          enable_sse: true,
          headers_provider: provider,
          transport_opts: @test_http_opts
        )

      {:ok, ping} = Message.encode_request(%{"method" => "ping", "params" => %{}}, "1")
      assert :ok = StreamableHTTP.send_message(transport, ping, timeout: 5_000)

      assert_receive {:headers_provider_call, 1}
      assert_receive {:headers_provider_call, 2}, 1_000
      refute_receive {:headers_provider_call, 3}, 250
      assert Agent.get(counter, & &1) == 2
      assert Process.alive?(transport)

      StreamableHTTP.shutdown(transport)
      StubClient.clear_messages()
    end

    test "forwards custom :headers to the SSE GET request", %{bypass: bypass} do
      server_url = "http://localhost:#{bypass.port}"
      {:ok, stub_client} = StubClient.start_link()
      session_id = "test-session-headers"
      test_pid = self()

      # First POST establishes the session (and must also receive the auth header)
      Bypass.stub(bypass, "POST", "/mcp", fn conn ->
        auth = conn |> Plug.Conn.get_req_header("authorization") |> List.first()
        send(test_pid, {:post_auth, auth})

        conn =
          conn
          |> Plug.Conn.put_resp_header("content-type", "application/json")
          |> Plug.Conn.put_resp_header("mcp-session-id", session_id)

        Plug.Conn.resp(conn, 200, ~s|{"jsonrpc":"2.0","id":"1","result":{}}|)
      end)

      # The SSE GET that follows session establishment — assert auth header arrives,
      # then short-circuit with 405 so we don't have to fake a real stream.
      Bypass.stub(bypass, "GET", "/mcp", fn conn ->
        auth = conn |> Plug.Conn.get_req_header("authorization") |> List.first()
        send(test_pid, {:sse_auth, auth})
        Plug.Conn.resp(conn, 405, "")
      end)

      Bypass.stub(bypass, "DELETE", "/mcp", fn conn -> Plug.Conn.resp(conn, 200, "") end)

      {:ok, transport} =
        StreamableHTTP.start_link(
          client: stub_client,
          base_url: server_url,
          mcp_path: "/mcp",
          enable_sse: true,
          headers: %{"authorization" => "Bearer test-token"},
          transport_opts: @test_http_opts
        )

      # Drive the first POST to establish the session
      {:ok, ping} = Message.encode_request(%{"method" => "ping", "params" => %{}}, "1")
      assert :ok = StreamableHTTP.send_message(transport, ping, timeout: 5000)

      # Both the POST and the subsequent SSE GET must have carried the user header.
      assert_receive {:post_auth, "Bearer test-token"}, 1_000
      assert_receive {:sse_auth, "Bearer test-token"}, 1_000

      StreamableHTTP.shutdown(transport)
      StubClient.clear_messages()
    end

    test "handles custom mcp_path", %{bypass: bypass} do
      server_url = "http://localhost:#{bypass.port}"
      custom_path = "/api/v1/mcp"
      {:ok, stub_client} = StubClient.start_link()

      Bypass.expect(bypass, "POST", "/api/v1/mcp", fn conn ->
        conn = Plug.Conn.put_resp_header(conn, "content-type", "application/json")
        Plug.Conn.resp(conn, 200, ~s|{"jsonrpc":"2.0","id":"1","result":{}}|)
      end)

      {:ok, transport} =
        StreamableHTTP.start_link(
          client: stub_client,
          base_url: server_url,
          mcp_path: custom_path,
          transport_opts: @test_http_opts
        )

      state = :sys.get_state(transport)
      assert state.mcp_url.path == custom_path

      {:ok, ping_message} =
        Message.encode_request(%{"method" => "ping", "params" => %{}}, "1")

      assert :ok = StreamableHTTP.send_message(transport, ping_message, timeout: 5000)

      StreamableHTTP.shutdown(transport)
      StubClient.clear_messages()
    end
  end

  describe "timeout handling" do
    test "respects custom timeout option", %{bypass: bypass} do
      server_url = "http://localhost:#{bypass.port}"
      {:ok, stub_client} = StubClient.start_link()

      # Server delay > default GenServer.call timeout would matter; shrink to
      # a tiny duration since we're verifying option propagation, not real time.
      Bypass.expect(bypass, "POST", "/mcp", fn conn ->
        Process.sleep(60)
        conn = Plug.Conn.put_resp_header(conn, "content-type", "application/json")
        Plug.Conn.resp(conn, 200, ~s|{"jsonrpc":"2.0","id":"1","result":{}}|)
      end)

      {:ok, transport} =
        StreamableHTTP.start_link(
          client: stub_client,
          base_url: server_url,
          mcp_path: "/mcp",
          transport_opts: @test_http_opts
        )

      {:ok, ping_message} =
        Message.encode_request(%{"method" => "ping", "params" => %{}}, "1")

      # Custom timeout > server delay → success.
      assert :ok = StreamableHTTP.send_message(transport, ping_message, timeout: 200)

      StreamableHTTP.shutdown(transport)
      StubClient.clear_messages()
    end

    test "respects timeout > Mint default receive_timeout", %{bypass: bypass} do
      server_url = "http://localhost:#{bypass.port}"
      {:ok, stub_client} = StubClient.start_link()

      # Original test used 20s vs 15s Mint default. We test the same option
      # propagation path with a server delay that would exceed a hypothetical
      # short receive_timeout if the option weren't being passed through.
      Bypass.expect(bypass, "POST", "/mcp", fn conn ->
        Process.sleep(60)
        conn = Plug.Conn.put_resp_header(conn, "content-type", "application/json")
        Plug.Conn.resp(conn, 200, ~s|{"jsonrpc":"2.0","id":"1","result":{}}|)
      end)

      {:ok, transport} =
        StreamableHTTP.start_link(
          client: stub_client,
          base_url: server_url,
          mcp_path: "/mcp",
          transport_opts: @test_http_opts
        )

      {:ok, ping_message} =
        Message.encode_request(%{"method" => "ping", "params" => %{}}, "1")

      assert :ok = StreamableHTTP.send_message(transport, ping_message, timeout: 500)

      StreamableHTTP.shutdown(transport)
      StubClient.clear_messages()
    end
  end

  describe "error handling" do
    test "handles network connection failures", %{bypass: bypass} do
      server_url = "http://localhost:#{bypass.port}"
      {:ok, stub_client} = StubClient.start_link()

      Bypass.down(bypass)

      {:ok, transport} =
        StreamableHTTP.start_link(
          client: stub_client,
          base_url: server_url,
          mcp_path: "/mcp",
          transport_opts: @test_http_opts
        )

      assert {:error, _reason} =
               StreamableHTTP.send_message(transport, "test message", timeout: 5000)

      StreamableHTTP.shutdown(transport)
      StubClient.clear_messages()
    end
  end

  describe "accept header behavior" do
    test "advertises both content types when SSE is disabled (default)", %{bypass: bypass} do
      server_url = "http://localhost:#{bypass.port}"
      {:ok, stub_client} = StubClient.start_link()

      Bypass.expect(bypass, "POST", "/mcp", fn conn ->
        # Per the MCP spec, every POST advertises both content types
        assert_dual_accept(conn)

        conn = Plug.Conn.put_resp_header(conn, "content-type", "application/json")
        Plug.Conn.resp(conn, 200, ~s|{"jsonrpc":"2.0","id":"1","result":{}}|)
      end)

      {:ok, transport} =
        StreamableHTTP.start_link(
          client: stub_client,
          base_url: server_url,
          mcp_path: "/mcp",
          enable_sse: false,
          transport_opts: @test_http_opts
        )

      {:ok, ping_message} =
        Message.encode_request(%{"method" => "ping", "params" => %{}}, "1")

      assert :ok = StreamableHTTP.send_message(transport, ping_message, timeout: 5000)

      StreamableHTTP.shutdown(transport)
      StubClient.clear_messages()
    end

    test "advertises both content types when SSE enabled but no session yet", %{bypass: bypass} do
      server_url = "http://localhost:#{bypass.port}"
      {:ok, stub_client} = StubClient.start_link()

      Bypass.expect(bypass, "POST", "/mcp", fn conn ->
        # Both content types are advertised even before a session exists
        assert_dual_accept(conn)

        conn = Plug.Conn.put_resp_header(conn, "content-type", "application/json")
        Plug.Conn.resp(conn, 200, ~s|{"jsonrpc":"2.0","id":"1","result":{}}|)
      end)

      {:ok, transport} =
        StreamableHTTP.start_link(
          client: stub_client,
          base_url: server_url,
          mcp_path: "/mcp",
          enable_sse: true,
          transport_opts: @test_http_opts
        )

      state = :sys.get_state(transport)
      assert state.session_id == nil

      {:ok, ping_message} =
        Message.encode_request(%{"method" => "ping", "params" => %{}}, "1")

      assert :ok = StreamableHTTP.send_message(transport, ping_message, timeout: 5000)

      StreamableHTTP.shutdown(transport)
      StubClient.clear_messages()
    end

    test "sends SSE accept header when SSE enabled AND session exists", %{bypass: bypass} do
      server_url = "http://localhost:#{bypass.port}"
      {:ok, stub_client} = StubClient.start_link()
      session_id = "test-session-789"

      # Both requests advertise the dual Accept header; only the second
      # carries the established session id.
      Bypass.stub(bypass, "POST", "/mcp", fn conn ->
        session_headers = Plug.Conn.get_req_header(conn, "mcp-session-id")

        case session_headers do
          [] ->
            # First request - no session yet, still advertises both content types
            assert_dual_accept(conn)

            conn =
              conn
              |> Plug.Conn.put_resp_header("content-type", "application/json")
              |> Plug.Conn.put_resp_header("mcp-session-id", session_id)

            Plug.Conn.resp(conn, 200, ~s|{"jsonrpc":"2.0","id":"1","result":{}}|)

          [^session_id] ->
            # Second request - has session, should include SSE
            assert_dual_accept(conn)

            conn = Plug.Conn.put_resp_header(conn, "content-type", "application/json")
            Plug.Conn.resp(conn, 200, ~s|{"jsonrpc":"2.0","id":"2","result":{}}|)
        end
      end)

      # Handle SSE GET connection attempt after session is acquired
      Bypass.stub(bypass, "GET", "/mcp", fn conn ->
        Plug.Conn.resp(conn, 405, "")
      end)

      # Handle DELETE request during shutdown
      Bypass.stub(bypass, "DELETE", "/mcp", fn conn ->
        Plug.Conn.resp(conn, 200, "")
      end)

      {:ok, transport} =
        StreamableHTTP.start_link(
          client: stub_client,
          base_url: server_url,
          mcp_path: "/mcp",
          enable_sse: true,
          transport_opts: @test_http_opts
        )

      # First request - establishes session
      {:ok, first_message} =
        Message.encode_request(%{"method" => "ping", "params" => %{}}, "1")

      assert :ok = StreamableHTTP.send_message(transport, first_message, timeout: 5000)

      # Verify session was captured
      state = :sys.get_state(transport)
      assert state.session_id == session_id

      # Second request - should include SSE in Accept header
      {:ok, second_message} =
        Message.encode_request(%{"method" => "tools/list", "params" => %{}}, "2")

      assert :ok = StreamableHTTP.send_message(transport, second_message, timeout: 5000)

      StreamableHTTP.shutdown(transport)
      StubClient.clear_messages()
    end
  end

  describe "shutdown" do
    test "gracefully shuts down transport", %{bypass: bypass} do
      server_url = "http://localhost:#{bypass.port}"
      {:ok, stub_client} = StubClient.start_link()

      {:ok, transport} =
        StreamableHTTP.start_link(
          client: stub_client,
          base_url: server_url,
          mcp_path: "/mcp",
          transport_opts: @test_http_opts
        )

      assert Process.alive?(transport)

      ref = Process.monitor(transport)
      StreamableHTTP.shutdown(transport)

      assert_receive {:DOWN, ^ref, :process, ^transport, _reason}
      refute Process.alive?(transport)

      StubClient.clear_messages()
    end
  end

  # Asserts the Accept header advertises both MCP media types, regardless of
  # their order or surrounding whitespace.
  defp assert_dual_accept(conn) do
    media_types =
      conn
      |> Plug.Conn.get_req_header("accept")
      |> List.first()
      |> to_string()
      |> String.split(",")
      |> Enum.map(&String.trim/1)

    assert "application/json" in media_types
    assert "text/event-stream" in media_types
  end

  defp start_http_negotiation_client(bypass, suffix, protocol_version \\ :auto) do
    client_name = Module.concat(__MODULE__, "#{suffix}Client")
    transport_name = Module.concat(__MODULE__, "#{suffix}Transport")
    server_url = "http://localhost:#{bypass.port}"

    _supervisor =
      start_supervised!(%{
        id: {Client, suffix},
        start:
          {Client, :start_link,
           [
             [
               name: client_name,
               transport_name: transport_name,
               transport:
                 {:streamable_http,
                  [
                    base_url: server_url,
                    mcp_path: "/mcp",
                    transport_opts: @test_http_opts
                  ]},
               client_info: %{"name" => "HTTPNegotiation", "version" => "1.0.0"},
               capabilities: %{},
               protocol_version: protocol_version,
               timeout: 1_000
             ]
           ]},
        restart: :temporary
      })

    {Process.whereis(client_name), Process.whereis(transport_name)}
  end
end

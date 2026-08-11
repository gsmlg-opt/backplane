defmodule Backplane.McpProtocol.Transport.StreamableHTTP.HeadersTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Backplane.McpProtocol.Client
  alias Backplane.McpProtocol.Client.State
  alias Backplane.McpProtocol.Telemetry
  alias Backplane.McpProtocol.Transport.RequestContext
  alias Backplane.McpProtocol.Transport.STDIO
  alias Backplane.McpProtocol.Transport.StreamableHTTP
  alias Backplane.McpProtocol.Transport.StreamableHTTP.Headers

  @protocol_version_key "io.modelcontextprotocol/protocolVersion"
  @client_capabilities_key "io.modelcontextprotocol/clientCapabilities"
  @test_http_opts [max_reconnections: 0]

  setup do
    bypass = Bypass.open()
    Process.group_leader(self(), self())
    {:ok, bypass: bypass}
  end

  describe "build/3" do
    test "builds canonical modern routing headers from the actual encoded request" do
      for {method, params, expected_name} <- [
            {"tools/call", %{"name" => "weather", "arguments" => %{}}, "weather"},
            {"prompts/get", %{"name" => "forecast"}, "forecast"},
            {"resources/read", %{"uri" => "file:///tmp/report"}, "file:///tmp/report"}
          ] do
        params = modern_params(params)
        context = context(:modern, method, params)

        assert {:ok, headers} = Headers.build(%{}, encode(method, params), context)
        assert headers["accept"] == "application/json, text/event-stream"
        assert headers["content-type"] == "application/json"
        assert headers["mcp-protocol-version"] == "2026-07-28"
        assert headers["mcp-method"] == method
        assert decode_mirrored(headers["mcp-name"]) == expected_name
        assert Enum.all?(Map.keys(headers), &(&1 == String.downcase(&1)))
      end
    end

    test "omits Mcp-Name for methods without a routed name" do
      params = modern_params(%{})

      assert {:ok, headers} =
               Headers.build(
                 %{},
                 encode("tools/list", params),
                 context(:modern, "tools/list", params)
               )

      refute Map.has_key?(headers, "mcp-name")
    end

    test "the actual encoded method and name win over stale context fields" do
      actual_params = modern_params(%{"name" => "actual", "arguments" => %{}})

      stale_context =
        :modern
        |> context("tools/list", modern_params(%{}))
        |> Map.put(:protocol_version, "stale-context-version")

      assert {:ok, headers} =
               Headers.build(%{}, encode("tools/call", actual_params), stale_context)

      assert headers["mcp-method"] == "tools/call"
      assert headers["mcp-name"] == "actual"
      assert headers["mcp-protocol-version"] == "2026-07-28"
    end

    test "encodes unsafe, Unicode, and sentinel routed names" do
      for name <- [" padded ", "München", "=?base64?already?=", "line\r\nbreak"] do
        params = modern_params(%{"name" => name, "arguments" => %{}})

        assert {:ok, headers} =
                 Headers.build(
                   %{},
                   encode("tools/call", params),
                   context(:modern, "tools/call", params)
                 )

        assert decode_mirrored(headers["mcp-name"]) == name
        refute headers["mcp-name"] =~ "\r"
        refute headers["mcp-name"] =~ "\n"
      end
    end

    test "generated routing headers override mixed-case configured values and strip sessions" do
      params = modern_params(%{"name" => "weather", "arguments" => %{}})

      base = %{
        "Authorization" => "Bearer token",
        "MCP-Protocol-Version" => "spoofed",
        "Mcp-Method" => "spoofed",
        "MCP-NAME" => "spoofed",
        "Mcp-Session-Id" => "poisoned",
        "Mcp-Param-Untrusted" => "poisoned"
      }

      assert {:ok, headers} =
               Headers.build(
                 base,
                 encode("tools/call", params),
                 context(:modern, "tools/call", params)
               )

      assert headers["authorization"] == "Bearer token"
      assert headers["mcp-protocol-version"] == "2026-07-28"
      assert headers["mcp-method"] == "tools/call"
      assert headers["mcp-name"] == "weather"
      refute Map.has_key?(headers, "mcp-session-id")
      refute Map.has_key?(headers, "mcp-param-untrusted")
    end

    test "projects validated parameter headers and encodes unsafe values" do
      params = modern_params(%{"name" => "weather", "arguments" => %{}})

      context =
        context(:modern, "tools/call", params,
          parameter_headers: %{
            "Mcp-Param-City" => "Paris",
            "Mcp-Param-Note" => "line\r\nbreak",
            "Mcp-Param-Enabled" => false
          }
        )

      assert {:ok, headers} = Headers.build(%{}, encode("tools/call", params), context)
      assert headers["mcp-param-city"] == "Paris"
      assert headers["mcp-param-enabled"] == "false"
      assert decode_mirrored(headers["mcp-param-note"]) == "line\r\nbreak"
      refute headers["mcp-param-note"] =~ "\r"
      refute headers["mcp-param-note"] =~ "\n"
    end

    test "rejects invalid configured names and raw CR/LF values" do
      params = modern_params(%{})
      context = context(:modern, "tools/list", params)
      encoded = encode("tools/list", params)

      assert {:error, {:invalid_header_name, "bad header"}} =
               Headers.build(%{"bad header" => "value"}, encoded, context)

      assert {:error, {:invalid_header_value, "authorization"}} =
               Headers.build(
                 %{"Authorization" => "Bearer good\r\ninjected: yes"},
                 encoded,
                 context
               )

      assert {:error, {:duplicate_header, "authorization"}} =
               Headers.build(
                 %{"Authorization" => "first", "authorization" => "second"},
                 encoded,
                 context
               )

      unsafe_method = encode("tools/list\r\ninjected", params)
      assert {:error, :invalid_routing_header_value} = Headers.build(%{}, unsafe_method, context)
    end

    test "rejects malformed encoded bodies and non-object JSON" do
      context = context(:modern, "tools/list", modern_params(%{}))

      assert {:error, :invalid_encoded_message} = Headers.build(%{}, "not-json", context)
      assert {:error, :invalid_encoded_message} = Headers.build(%{}, "[]", context)

      params = modern_params(%{})

      for invalid <- [
            %{"jsonrpc" => "1.0", "id" => "id", "method" => "tools/list", "params" => params},
            %{"jsonrpc" => "2.0", "method" => "tools/list", "params" => params},
            %{"jsonrpc" => "2.0", "id" => nil, "method" => "tools/list", "params" => params},
            %{"jsonrpc" => "2.0", "id" => true, "method" => "tools/list", "params" => params}
          ] do
        assert {:error, :invalid_encoded_message} =
                 Headers.build(%{}, JSON.encode!(invalid), context)
      end
    end

    test "rejects missing or non-string required modern protocol metadata" do
      context = context(:modern, "tools/list", modern_params(%{}))

      assert {:error, :missing_protocol_version_metadata} =
               Headers.build(%{}, encode("tools/list", %{}), context)

      invalid = %{
        "_meta" => %{
          @protocol_version_key => 20_260_728,
          @client_capabilities_key => %{}
        }
      }

      assert {:error, :missing_protocol_version_metadata} =
               Headers.build(%{}, encode("tools/list", invalid), context)
    end

    test "legacy requests retain configured session headers and omit modern routing fields" do
      params = %{"protocolVersion" => "2025-03-26"}
      context = context(:legacy, "initialize", params)

      assert {:ok, headers} =
               Headers.build(
                 %{
                   "Authorization" => "Bearer token",
                   "Mcp-Session-Id" => "legacy",
                   "MCP-Protocol-Version" => "configured-version",
                   "Mcp-Method" => "poisoned",
                   "Mcp-Param-City" => "poisoned"
                 },
                 encode("initialize", params),
                 context
               )

      assert headers["authorization"] == "Bearer token"
      assert headers["mcp-session-id"] == "legacy"
      assert headers["mcp-protocol-version"] == "configured-version"
      refute Map.has_key?(headers, "mcp-method")
      refute Map.has_key?(headers, "mcp-name")
      refute Map.has_key?(headers, "mcp-param-city")
    end

    test "generates legacy protocol headers only after initialize for revisions that require them" do
      for version <- ["2025-06-18", "2025-11-25"] do
        initialize = context(:legacy, "initialize", %{}, protocol_version: version)
        post_initialize = context(:legacy, "ping", %{}, protocol_version: version)

        assert {:ok, initialize_headers} = Headers.build(%{}, encode("initialize", %{}), initialize)
        refute Map.has_key?(initialize_headers, "mcp-protocol-version")

        assert {:ok, headers} = Headers.build(%{}, encode("ping", %{}), post_initialize)
        assert headers["mcp-protocol-version"] == version
      end

      context = context(:legacy, "ping", %{}, protocol_version: "2025-03-26")
      assert {:ok, headers} = Headers.build(%{}, encode("ping", %{}), context)
      refute Map.has_key?(headers, "mcp-protocol-version")
    end
  end

  describe "Streamable HTTP era isolation" do
    test "modern requests remain session-free across repeated POSTs and never start GET or DELETE",
         %{
           bypass: bypass
         } do
      test_pid = self()
      secret = "secret-modern-header-value"

      Bypass.stub(bypass, "POST", "/mcp", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = JSON.decode!(body)
        send(test_pid, {:request, conn.method, conn.req_headers})

        conn = Plug.Conn.put_resp_header(conn, "mcp-session-id", "malicious-session")

        if request["id"] == "two" do
          conn = Plug.Conn.put_resp_header(conn, "content-type", "text/event-stream")

          body =
            "data: " <>
              JSON.encode!(%{"jsonrpc" => "2.0", "id" => "two", "result" => %{}}) <> "\n\n"

          Plug.Conn.resp(conn, 200, body)
        else
          conn = Plug.Conn.put_resp_header(conn, "content-type", "application/json")

          Plug.Conn.resp(
            conn,
            200,
            JSON.encode!(%{"jsonrpc" => "2.0", "id" => request["id"], "result" => %{}})
          )
        end
      end)

      Bypass.stub(bypass, "GET", "/mcp", fn conn ->
        send(test_pid, {:request, conn.method, conn.req_headers})
        Plug.Conn.resp(conn, 405, "")
      end)

      Bypass.stub(bypass, "DELETE", "/mcp", fn conn ->
        send(test_pid, {:request, conn.method, conn.req_headers})
        Plug.Conn.resp(conn, 200, "")
      end)

      {stub_client, transport} =
        start_http_transport(bypass,
          enable_sse: true,
          headers: %{
            "Authorization" => secret,
            "MCP-SESSION-ID" => "configured-poison",
            "Last-Event-ID" => "configured-poison"
          }
        )

      :ok = StubClient.subscribe()

      params = modern_params(%{})
      context = context(:modern, "tools/list", params)

      for id <- ["one", "two"] do
        assert :ok =
                 StreamableHTTP.send_message(transport, encode("tools/list", params, id),
                   timeout: 1_000,
                   request_context: context
                 )

        assert_receive {:request, "POST", headers}, 1_000
        assert_receive {:stub_client_response, _response}, 1_000
        assert {"authorization", secret} in headers
        refute Enum.any?(headers, fn {name, _} -> name == "mcp-session-id" end)
        refute Enum.any?(headers, fn {name, _} -> name == "last-event-id" end)
      end

      assert :sys.get_state(transport).session_id == nil

      ref = Process.monitor(transport)
      StreamableHTTP.shutdown(transport)
      assert_receive {:DOWN, ^ref, :process, ^transport, :normal}, 1_000
      refute_receive {:request, "GET", _}, 100
      refute_receive {:request, "DELETE", _}, 100
      GenServer.stop(stub_client)
    end

    test "legacy initialize owns its session, starts GET SSE, and shutdown sends one authenticated DELETE",
         %{
           bypass: bypass
         } do
      test_pid = self()
      session_id = "legacy-session"
      secret = "legacy-auth-secret"

      Bypass.stub(bypass, "POST", "/mcp", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = JSON.decode!(body)
        send(test_pid, {:request, conn.method, conn.req_headers})

        conn =
          conn
          |> Plug.Conn.put_resp_header("content-type", "application/json")
          |> Plug.Conn.put_resp_header("mcp-session-id", session_id)

        Plug.Conn.resp(
          conn,
          200,
          JSON.encode!(%{"jsonrpc" => "2.0", "id" => request["id"], "result" => %{}})
        )
      end)

      Bypass.stub(bypass, "GET", "/mcp", fn conn ->
        send(test_pid, {:request, conn.method, conn.req_headers})

        case Plug.Conn.get_req_header(conn, "last-event-id") do
          [] ->
            conn = Plug.Conn.put_resp_header(conn, "content-type", "text/event-stream")
            Plug.Conn.resp(conn, 200, "id: legacy-event\ndata: {}\n\n")

          ["legacy-event"] ->
            Plug.Conn.resp(conn, 405, "")
        end
      end)

      Bypass.stub(bypass, "DELETE", "/mcp", fn conn ->
        send(test_pid, {:request, conn.method, conn.req_headers})
        Plug.Conn.resp(conn, 200, "")
      end)

      {stub_client, transport} =
        start_http_transport(bypass,
          enable_sse: true,
          headers: %{"Authorization" => secret}
        )

      params = %{
        "protocolVersion" => "2025-03-26",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "Client", "version" => "1"}
      }

      assert :ok =
               StreamableHTTP.send_message(transport, encode("initialize", params),
                 timeout: 1_000,
                 request_context: context(:legacy, "initialize", params)
               )

      assert_receive {:request, "POST", post_headers}, 1_000
      refute Enum.any?(post_headers, fn {name, _} -> name == "mcp-method" end)
      refute Enum.any?(post_headers, fn {name, _} -> name == "mcp-protocol-version" end)
      assert :sys.get_state(transport).session_id == session_id

      assert_receive {:request, "GET", get_headers}, 1_000
      assert {"authorization", secret} in get_headers
      assert {"mcp-session-id", session_id} in get_headers
      refute Enum.any?(get_headers, fn {name, _} -> name == "mcp-protocol-version" end)

      assert_receive {:request, "GET", resumed_headers}, 1_000
      assert {"last-event-id", "legacy-event"} in resumed_headers

      ref = Process.monitor(transport)
      StreamableHTTP.shutdown(transport)
      assert_receive {:request, "DELETE", delete_headers}, 1_000
      assert {"authorization", secret} in delete_headers
      assert {"mcp-session-id", session_id} in delete_headers
      refute Enum.any?(delete_headers, fn {name, _} -> name == "mcp-protocol-version" end)
      assert_receive {:DOWN, ^ref, :process, ^transport, :normal}, 1_000
      refute_receive {:request, "DELETE", _}, 100
      GenServer.stop(stub_client)
    end

    test "a non-initialize explicit legacy response cannot create a session", %{bypass: bypass} do
      test_pid = self()

      Bypass.stub(bypass, "POST", "/mcp", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = JSON.decode!(body)

        conn =
          conn
          |> Plug.Conn.put_resp_header("content-type", "application/json")
          |> Plug.Conn.put_resp_header("mcp-session-id", "poisoned")

        Plug.Conn.resp(
          conn,
          200,
          JSON.encode!(%{"jsonrpc" => "2.0", "id" => request["id"], "result" => %{}})
        )
      end)

      Bypass.stub(bypass, "DELETE", "/mcp", fn conn ->
        send(test_pid, {:request, conn.method})
        Plug.Conn.resp(conn, 200, "")
      end)

      {stub_client, transport} = start_http_transport(bypass)
      params = %{}

      assert :ok =
               StreamableHTTP.send_message(transport, encode("ping", params),
                 timeout: 1_000,
                 request_context: context(:legacy, "ping", params)
               )

      assert :sys.get_state(transport).session_id == nil
      ref = Process.monitor(transport)
      StreamableHTTP.shutdown(transport)
      assert_receive {:DOWN, ^ref, :process, ^transport, :normal}, 1_000
      refute_receive {:request, "DELETE"}, 100
      GenServer.stop(stub_client)
    end

    test "auto negotiation sends modern discover then legacy initialize on one transport", %{
      bypass: bypass
    } do
      test_pid = self()

      Bypass.stub(bypass, "POST", "/mcp", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = JSON.decode!(body)
        headers = Map.new(conn.req_headers)
        send(test_pid, {:negotiation_request, request["method"], headers})

        case request["method"] do
          "server/discover" ->
            Plug.Conn.resp(conn, 400, "legacy endpoint")

          "initialize" ->
            conn =
              conn
              |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
              |> Plug.Conn.put_resp_header("mcp-session-id", "fallback-session")

            response =
              JSON.encode!(%{
                "jsonrpc" => "2.0",
                "id" => request["id"],
                "result" => %{
                  "protocolVersion" => "2025-11-25",
                  "capabilities" => %{},
                  "serverInfo" => %{"name" => "Legacy", "version" => "1"}
                }
              })

            Plug.Conn.resp(
              conn,
              200,
              "data: #{response}\n\n"
            )

          "notifications/initialized" ->
            Plug.Conn.resp(conn, 202, "")

          "notifications/test" ->
            Plug.Conn.resp(conn, 202, "")
        end
      end)

      Bypass.stub(bypass, "GET", "/mcp", fn conn ->
        send(test_pid, {:negotiation_request, "GET", Map.new(conn.req_headers), self()})

        receive do
          :release_sse -> Plug.Conn.resp(conn, 405, "")
        after
          2_000 -> Plug.Conn.resp(conn, 405, "")
        end
      end)

      Bypass.stub(bypass, "DELETE", "/mcp", fn conn ->
        send(test_pid, {:negotiation_request, "DELETE", Map.new(conn.req_headers)})
        Plug.Conn.resp(conn, 200, "")
      end)

      suffix = System.unique_integer([:positive])
      client_name = Module.concat(__MODULE__, "AutoClient#{suffix}")
      transport_name = Module.concat(__MODULE__, "AutoTransport#{suffix}")

      supervisor =
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
                      base_url: "http://localhost:#{bypass.port}",
                      mcp_path: "/mcp",
                      enable_sse: true,
                      transport_opts: @test_http_opts
                    ]},
                 client_info: %{"name" => "Auto", "version" => "1"},
                 capabilities: %{},
                 protocol_version: :auto,
                 timeout: 1_000
               ]
             ]},
          restart: :temporary
        })

      assert :ok = Client.await_ready(client_name, timeout: 2_000)

      assert_receive {:negotiation_request, "server/discover", modern_headers}, 1_000
      assert modern_headers["mcp-protocol-version"] == "2026-07-28"
      assert modern_headers["mcp-method"] == "server/discover"
      refute Map.has_key?(modern_headers, "mcp-session-id")

      assert_receive {:negotiation_request, "initialize", legacy_headers}, 1_000
      refute Map.has_key?(legacy_headers, "mcp-protocol-version")
      refute Map.has_key?(legacy_headers, "mcp-method")

      assert_receive {:negotiation_request, "notifications/initialized", initialized_headers},
                     1_000

      assert initialized_headers["mcp-session-id"] == "fallback-session"
      assert initialized_headers["mcp-protocol-version"] == "2025-11-25"

      assert_receive {:negotiation_request, "GET", get_headers, sse_request}, 1_000
      assert get_headers["mcp-session-id"] == "fallback-session"
      assert get_headers["mcp-protocol-version"] == "2025-11-25"

      notification =
        JSON.encode!(%{"jsonrpc" => "2.0", "method" => "notifications/test", "params" => %{}})

      assert :ok = StreamableHTTP.send_message(transport_name, notification, timeout: 1_000)

      assert_receive {:negotiation_request, "notifications/test", later_headers}, 1_000
      assert later_headers["mcp-session-id"] == "fallback-session"
      assert later_headers["mcp-protocol-version"] == "2025-11-25"

      assert %{era: :legacy, negotiated_version: "2025-11-25"} =
               Client.get_protocol_info(client_name)

      send(sse_request, :release_sse)
      StreamableHTTP.shutdown(transport_name)
      assert_receive {:negotiation_request, "DELETE", delete_headers}, 1_000
      assert delete_headers["mcp-session-id"] == "fallback-session"
      assert delete_headers["mcp-protocol-version"] == "2025-11-25"
      stop_supervised({Client, suffix})
      refute Process.alive?(supervisor)
    end

    test "stdio accepts request context while emitting only the encoded body" do
      {:ok, stub_client} = StubClient.start_link()
      :ok = StubClient.subscribe()

      {:ok, transport} =
        STDIO.start_link(
          name: Module.concat(__MODULE__, "StdioTransport"),
          client: stub_client,
          command: "cat"
        )

      params = modern_params(%{})
      encoded = encode("tools/list", params)

      assert_receive {:stub_client_signal, :negotiate}, 1_000

      assert :ok =
               STDIO.send_message(transport, encoded,
                 timeout: 1_000,
                 request_context:
                   context(:modern, "tools/list", params,
                     parameter_headers: %{"Mcp-Param-Secret" => "never-an-http-field"}
                   )
               )

      assert_receive {:stub_client_response, ^encoded}, 1_000
      ref = Process.monitor(transport)
      STDIO.shutdown(transport)
      assert_receive {:DOWN, ^ref, :process, ^transport, :normal}, 1_000
      GenServer.stop(stub_client)
    end

    test "logs and telemetry expose header names but not authorization or parameter values", %{
      bypass: bypass
    } do
      secret = "task7-secret-sentinel"
      test_pid = self()
      handler = {__MODULE__, make_ref()}

      :ok =
        :telemetry.attach(
          handler,
          [:backplane_mcp_protocol | Telemetry.event_transport_send()],
          fn _event, _measurements, metadata, pid -> send(pid, {:send_metadata, metadata}) end,
          test_pid
        )

      on_exit(fn -> :telemetry.detach(handler) end)

      Bypass.stub(bypass, "POST", "/mcp", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = JSON.decode!(body)
        conn = Plug.Conn.put_resp_header(conn, "content-type", "application/json")

        Plug.Conn.resp(
          conn,
          200,
          JSON.encode!(%{"jsonrpc" => "2.0", "id" => request["id"], "result" => %{}})
        )
      end)

      {stub_client, transport} =
        start_http_transport(bypass, headers: %{"Authorization" => secret})

      params = modern_params(%{})

      context =
        context(:modern, "tools/list", params, parameter_headers: %{"Mcp-Param-Secret" => secret})

      log =
        capture_log(fn ->
          assert :ok =
                   StreamableHTTP.send_message(transport, encode("tools/list", params),
                     timeout: 1_000,
                     request_context: context
                   )
        end)

      assert_receive {:send_metadata, metadata}, 1_000
      refute inspect(metadata) =~ secret
      refute log =~ secret

      ref = Process.monitor(transport)
      StreamableHTTP.shutdown(transport)
      assert_receive {:DOWN, ^ref, :process, ^transport, :normal}, 1_000
      GenServer.stop(stub_client)
    end
  end

  defp start_http_transport(bypass, opts \\ []) do
    {:ok, stub_client} = StubClient.start_link()

    {:ok, transport} =
      StreamableHTTP.start_link(
        Keyword.merge(
          [
            client: stub_client,
            base_url: "http://localhost:#{bypass.port}",
            mcp_path: "/mcp",
            transport_opts: @test_http_opts
          ],
          opts
        )
      )

    {stub_client, transport}
  end

  defp context(era, method, params, opts \\ []) do
    default_version = if era == :modern, do: "2026-07-28", else: "2025-03-26"
    {version, opts} = Keyword.pop(opts, :protocol_version, default_version)

    state = %State{
      client_info: %{"name" => "Client", "version" => "1"},
      capabilities: %{},
      protocol_version: version,
      negotiated_version: version,
      negotiation_status: :ready,
      era: era
    }

    RequestContext.new(method, params, state, opts)
  end

  defp modern_params(params) do
    Map.put(params, "_meta", %{
      @protocol_version_key => "2026-07-28",
      @client_capabilities_key => %{}
    })
  end

  defp encode(method, params, id \\ "request-id") do
    JSON.encode!(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => params
    }) <> "\n"
  end

  defp decode_mirrored("=?base64?" <> rest) do
    encoded = binary_part(rest, 0, byte_size(rest) - 2)
    Base.decode64!(encoded)
  end

  defp decode_mirrored(value), do: value
end

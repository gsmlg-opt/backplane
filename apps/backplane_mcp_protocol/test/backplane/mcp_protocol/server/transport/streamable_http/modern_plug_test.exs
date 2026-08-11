defmodule ModernHTTPMissingCapabilityServer do
  @moduledoc false

  use Backplane.McpProtocol.Server,
    name: "modern-http-missing-capability",
    version: "1.0.0",
    capabilities: [:tools],
    protocol_versions: ["2026-07-28"]

  @impl true
  def handle_request(_request, frame) do
    result = %{
      "resultType" => "input_required",
      "inputRequests" => %{"roots" => %{"method" => "roots/list"}}
    }

    {:reply, result, frame}
  end
end

defmodule Backplane.McpProtocol.Server.Transport.StreamableHTTP.ModernPlugTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Backplane.McpProtocol.Server.Authorization
  alias Backplane.McpProtocol.Server.Registry
  alias Backplane.McpProtocol.Server.Supervisor, as: ServerSupervisor
  alias Backplane.McpProtocol.Server.Transport.StreamableHTTP.Plug, as: StreamableHTTPPlug

  @version "2026-07-28"

  setup do
    task_supervisor =
      start_supervised!({Task.Supervisor, name: Registry.task_supervisor_name(ModernStubServer)})

    session_supervisor =
      start_supervised!(
        {DynamicSupervisor, name: Registry.session_supervisor_name(ModernStubServer), strategy: :one_for_one}
      )

    session_config = %{
      server_module: ModernStubServer,
      registry_mod: Registry.None,
      transport: [layer: StubTransport, name: Registry.transport_name(ModernStubServer, StubTransport)],
      session_idle_timeout: nil,
      timeout: 30_000,
      task_supervisor: task_supervisor,
      max_concurrency: 1
    }

    :persistent_term.put({ServerSupervisor, ModernStubServer, :session_config}, session_config)
    :persistent_term.erase({ServerSupervisor, ModernStubServer, :authorization_config})

    on_exit(fn ->
      :persistent_term.erase({ServerSupervisor, ModernStubServer, :session_config})
      :persistent_term.erase({ServerSupervisor, ModernStubServer, :authorization_config})
    end)

    %{
      opts: StreamableHTTPPlug.init(server: ModernStubServer),
      session_supervisor: session_supervisor
    }
  end

  test "POST discovers the modern server without creating or returning a session", context do
    conn = post_modern(context.opts, modern_request("server/discover", %{}, id: "discover-http"))

    assert conn.status == 200
    assert get_resp_header(conn, "mcp-session-id") == []
    assert DynamicSupervisor.count_children(context.session_supervisor).active == 0

    assert %{
             "jsonrpc" => "2.0",
             "id" => "discover-http",
             "result" => %{
               "resultType" => "complete",
               "supportedVersions" => [@version]
             }
           } = JSON.decode!(conn.resp_body)
  end

  test "POST validates named tool headers after request initialization and ignores a session ID", context do
    request =
      modern_request(
        "tools/call",
        %{"name" => "route", "arguments" => %{"region" => "west"}},
        id: "tool-http"
      )

    conn =
      post_modern(context.opts, request, [
        {"mcp-name", "route"},
        {"mcp-param-region", "west"},
        {"mcp-session-id", "stray-legacy-session"}
      ])

    assert conn.status == 200
    assert get_resp_header(conn, "mcp-session-id") == []
    assert DynamicSupervisor.count_children(context.session_supervisor).active == 0

    assert %{
             "id" => "tool-http",
             "result" => %{
               "resultType" => "complete",
               "structuredContent" => %{
                 "arguments" => %{"region" => "west"},
                 "initCount" => 1
               }
             }
           } = JSON.decode!(conn.resp_body)

    assert_receive {:modern_init_request, _context}
    assert_receive {:modern_handle_request, "tools/call", 1}
  end

  test "POST maps standard and declared parameter header mismatches to HTTP 400", context do
    request =
      modern_request(
        "tools/call",
        %{"name" => "route", "arguments" => %{"region" => "west"}},
        id: "header-mismatch"
      )

    mismatched_headers = [
      [
        {"mcp-protocol-version", "2099-01-01"},
        {"mcp-name", "route"},
        {"mcp-param-region", "west"}
      ],
      [
        {"mcp-method", "tools/list"},
        {"mcp-name", "route"},
        {"mcp-param-region", "west"}
      ],
      [{"mcp-name", "different"}, {"mcp-param-region", "west"}],
      [{"mcp-name", "route"}, {"mcp-param-region", "east"}]
    ]

    for headers <- mismatched_headers do
      conn = post_modern(context.opts, request, headers)

      assert conn.status == 400

      assert %{
               "id" => "header-mismatch",
               "error" => %{"code" => -32_020}
             } = JSON.decode!(conn.resp_body)
    end
  end

  test "POST rejects duplicate routing and recognized parameter headers case-insensitively", context do
    request =
      modern_request(
        "tools/call",
        %{"name" => "route", "arguments" => %{"region" => "west"}},
        id: "duplicate-header"
      )

    extra_headers = [{"mcp-name", "route"}, {"mcp-param-region", "west"}]

    duplicate_headers = [
      {"MCP-Protocol-Version", @version},
      {"Mcp-Method", "tools/call"},
      {"MCP-NAME", "route"},
      {"Mcp-Param-Region", "west"}
    ]

    for duplicate <- duplicate_headers do
      conn =
        post_modern_with_raw_headers(
          context.opts,
          request,
          extra_headers,
          [duplicate]
        )

      assert conn.status == 400, "expected duplicate #{inspect(duplicate)} to be rejected"

      assert %{
               "id" => "duplicate-header",
               "error" => %{"code" => -32_020}
             } = JSON.decode!(conn.resp_body)
    end

    conn =
      post_modern_with_raw_headers(
        context.opts,
        request,
        extra_headers,
        [{"Mcp-Param-Unknown", "one"}, {"mcp-param-unknown", "two"}]
      )

    assert conn.status == 200
    assert %{"id" => "duplicate-header", "result" => %{}} = JSON.decode!(conn.resp_body)
  end

  test "POST maps an unsupported matching modern version to HTTP 400", context do
    request =
      "tools/list"
      |> modern_request(%{}, id: "unsupported-version")
      |> put_in(
        ["params", "_meta", "io.modelcontextprotocol/protocolVersion"],
        "2099-01-01"
      )

    conn =
      post_modern(context.opts, request, [
        {"mcp-protocol-version", "2099-01-01"}
      ])

    assert conn.status == 400

    assert %{
             "id" => "unsupported-version",
             "error" => %{
               "code" => -32_022,
               "data" => %{
                 "requested" => "2099-01-01",
                 "supported" => [@version]
               }
             }
           } = JSON.decode!(conn.resp_body)
  end

  test "POST maps invalid modern request metadata to HTTP 400", context do
    request =
      "tools/list"
      |> modern_request(%{}, id: "invalid-metadata")
      |> update_in(
        ["params", "_meta"],
        &Map.delete(&1, "io.modelcontextprotocol/clientCapabilities")
      )

    conn = post_modern(context.opts, request)

    assert conn.status == 400

    assert %{
             "id" => "invalid-metadata",
             "error" => %{"code" => -32_602}
           } = JSON.decode!(conn.resp_body)
  end

  test "POST maps a missing client capability to HTTP 400" do
    task_supervisor = start_supervised!({Task.Supervisor, []})

    session_config = %{
      server_module: ModernHTTPMissingCapabilityServer,
      registry_mod: Registry.None,
      transport: [layer: StubTransport, name: nil],
      session_idle_timeout: nil,
      timeout: 30_000,
      task_supervisor: task_supervisor,
      max_concurrency: 1
    }

    :persistent_term.put(
      {ServerSupervisor, ModernHTTPMissingCapabilityServer, :session_config},
      session_config
    )

    on_exit(fn ->
      :persistent_term.erase({ServerSupervisor, ModernHTTPMissingCapabilityServer, :session_config})
    end)

    opts = StreamableHTTPPlug.init(server: ModernHTTPMissingCapabilityServer)

    request =
      modern_request(
        "tools/call",
        %{"name" => "needs-roots", "arguments" => %{}},
        id: "missing-capability"
      )

    conn = post_modern(opts, request, [{"mcp-name", "needs-roots"}])

    assert conn.status == 400

    assert %{
             "id" => "missing-capability",
             "error" => %{
               "code" => -32_021,
               "data" => %{"requiredCapabilities" => %{"roots" => %{}}}
             }
           } = JSON.decode!(conn.resp_body)
  end

  test "POST lets the modern executor map an unknown method to HTTP 404", context do
    conn =
      post_modern(
        context.opts,
        modern_request("com.example/unknown", %{}, id: "unknown-method")
      )

    assert conn.status == 404

    assert %{
             "id" => "unknown-method",
             "error" => %{"code" => -32_601}
           } = JSON.decode!(conn.resp_body)
  end

  test "POST leaves an executor callback failure at HTTP 200", context do
    conn =
      post_modern(
        context.opts,
        modern_request("tools/list", %{"_testCallback" => "raise"}, id: "callback-failure")
      )

    assert conn.status == 200

    assert %{
             "id" => "callback-failure",
             "error" => %{"code" => -32_603}
           } = JSON.decode!(conn.resp_body)
  end

  test "POST streams a successful modern response on the request connection", context do
    conn =
      post_modern(
        context.opts,
        modern_request("tools/list", %{}, id: "sse-http"),
        [{"accept", "text/event-stream, application/json"}]
      )

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["text/event-stream; charset=utf-8"]
    assert get_resp_header(conn, "mcp-session-id") == []

    body = response_body(conn)
    assert body =~ "event: message"
    assert body =~ ~s("id":"sse-http")
    assert body =~ ~s("resultType":"complete")

    refute Enum.any?(String.split(body, "\n"), &String.starts_with?(&1, "id:"))
    refute Enum.any?(String.split(body, "\n"), &String.starts_with?(&1, "retry:"))
  end

  test "GET and DELETE reject the known modern protocol marker with HTTP 405", context do
    for method <- [:get, :delete] do
      conn =
        method
        |> conn("/")
        |> put_req_header("mcp-protocol-version", @version)
        |> StreamableHTTPPlug.call(context.opts)

      assert conn.status == 405
      assert get_resp_header(conn, "allow") == ["POST"]
      assert get_resp_header(conn, "content-type") == []
      assert conn.resp_body == ""
    end
  end

  test "origin validation runs before modern profile routing", _context do
    opts =
      StreamableHTTPPlug.init(
        server: ModernStubServer,
        allowed_origins: ["https://client.example"]
      )

    conn =
      post_modern(
        opts,
        modern_request("tools/list", %{}, id: "blocked-origin"),
        [
          {"origin", "https://attacker.example"},
          {"mcp-protocol-version", "2099-01-01"}
        ]
      )

    assert conn.status == 403
    refute_receive {:modern_init_request, _context}
  end

  test "authorization runs before parsing and its claims reach the modern callback", context do
    auth_config =
      Authorization.parse_config!(
        authorization_servers: ["https://auth.example.com"],
        resource: "https://api.example.com",
        validator: {MockTokenValidator, []}
      )

    :persistent_term.put(
      {ServerSupervisor, ModernStubServer, :authorization_config},
      auth_config
    )

    unauthorized =
      :post
      |> conn("/", "not json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("mcp-protocol-version", @version)
      |> StreamableHTTPPlug.call(context.opts)

    assert unauthorized.status == 401

    authorized =
      post_modern(
        context.opts,
        modern_request("tools/list", %{}, id: "authorized-modern"),
        [{"authorization", "Bearer valid-token"}]
      )

    assert authorized.status == 200
    assert_receive {:modern_callback_context, callback_context}
    assert callback_context.auth.sub == "test-user"
  end

  test "malformed JSON with a modern marker returns parse error with a null id", context do
    conn =
      :post
      |> conn("/", "not json")
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("mcp-protocol-version", @version)
      |> StreamableHTTPPlug.call(context.opts)

    assert conn.status == 400

    assert %{
             "jsonrpc" => "2.0",
             "id" => nil,
             "error" => %{"code" => -32_700}
           } = JSON.decode!(conn.resp_body)
  end

  test "known unsupported legacy version is rejected before malformed JSON is decoded", context do
    conn =
      :post
      |> conn("/", "not json")
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("mcp-protocol-version", "2025-03-26")
      |> StreamableHTTPPlug.call(context.opts)

    assert conn.status == 400

    assert %{
             "error" => %{
               "code" => -32_600,
               "data" => %{
                 "data" => %{
                   "message" => "Unsupported MCP protocol version",
                   "http_status" => 400
                 }
               }
             }
           } = JSON.decode!(conn.resp_body)
  end

  test "fetched non-object body params are an invalid modern request", context do
    conn =
      :post
      |> conn("/", "")
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("mcp-protocol-version", @version)
      |> put_req_header("mcp-method", "tools/list")
      |> then(&%{&1 | body_params: ["not-an-object"]})
      |> StreamableHTTPPlug.call(context.opts)

    assert conn.status == 400

    assert %{
             "jsonrpc" => "2.0",
             "id" => nil,
             "error" => %{"code" => -32_600}
           } = JSON.decode!(conn.resp_body)
  end

  test "modern POST rejects notifications, responses, and malformed envelopes", context do
    valid = modern_request("tools/list", %{}, id: "valid")

    invalid_messages = [
      %{"jsonrpc" => "2.0", "id" => "client-response", "result" => %{}},
      Map.delete(valid, "id"),
      %{valid | "jsonrpc" => "1.0"},
      %{valid | "id" => true},
      %{valid | "params" => []},
      [valid]
    ]

    for message <- invalid_messages do
      conn = raw_modern_post(context.opts, JSON.encode!(message), "tools/list")

      assert conn.status == 400

      assert %{
               "jsonrpc" => "2.0",
               "id" => nil,
               "error" => %{"code" => -32_600}
             } = JSON.decode!(conn.resp_body)
    end
  end

  defp post_modern(opts, request, extra_headers \\ []) do
    post_modern_with_raw_headers(opts, request, extra_headers, [])
  end

  defp post_modern_with_raw_headers(opts, request, extra_headers, raw_headers) do
    headers = [
      {"content-type", "application/json"},
      {"accept", "application/json, text/event-stream"},
      {"mcp-protocol-version", @version},
      {"mcp-method", request["method"]}
    ]

    raw_post(opts, JSON.encode!(request), headers ++ extra_headers, raw_headers)
  end

  defp raw_modern_post(opts, body, method) do
    raw_post(
      opts,
      body,
      [
        {"content-type", "application/json"},
        {"accept", "application/json, text/event-stream"},
        {"mcp-protocol-version", @version},
        {"mcp-method", method}
      ],
      []
    )
  end

  defp raw_post(opts, body, headers, raw_headers) do
    conn =
      :post
      |> conn("/", body)
      |> assign(:test_pid, self())

    headers
    |> Enum.reduce(conn, fn {name, value}, conn -> put_req_header(conn, name, value) end)
    |> then(&%{&1 | req_headers: raw_headers ++ &1.req_headers})
    |> StreamableHTTPPlug.call(opts)
  end

  defp modern_request(method, params, opts) do
    meta = %{
      "io.modelcontextprotocol/protocolVersion" => @version,
      "io.modelcontextprotocol/clientCapabilities" => %{}
    }

    %{
      "jsonrpc" => "2.0",
      "id" => Keyword.fetch!(opts, :id),
      "method" => method,
      "params" => Map.put(params, "_meta", meta)
    }
  end

  defp response_body(%Plug.Conn{resp_body: ""} = conn) do
    case conn.adapter do
      {Plug.Adapters.Test.Conn, %{chunks: chunks}} when is_binary(chunks) -> chunks
      _other -> ""
    end
  end

  defp response_body(%Plug.Conn{resp_body: body}) when is_binary(body), do: body
end

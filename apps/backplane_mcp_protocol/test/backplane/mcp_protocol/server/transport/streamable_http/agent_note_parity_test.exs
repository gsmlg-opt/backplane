defmodule Backplane.McpProtocol.Server.Transport.StreamableHTTP.AgentNoteParityTest do
  use ExUnit.Case, async: false

  alias Backplane.McpProtocol.Server.Registry
  alias Backplane.McpProtocol.Server.Supervisor, as: ServerSupervisor
  alias Backplane.McpProtocol.Server.Transport.StreamableHTTP.Plug, as: StreamableHTTPPlug

  @version "2026-07-28"
  @server_info_key "io.modelcontextprotocol/serverInfo"

  # Wire-contract reference: gsmlg-opt/agent-note at
  # 1a16690d3f0bcdb08e00752e46d76f234313416b,
  # crates/note-mcp/tests/org_transports_test.rs:697-836 and 889 onward.
  defmodule FixtureServer do
    @moduledoc false

    use Backplane.McpProtocol.Server,
      name: "http-parity-fixture",
      version: "1.0.0",
      capabilities: [:tools],
      protocol_versions: ["2026-07-28", "2025-11-25"]

    alias Backplane.McpProtocol.Server.Component.Schema
    alias Backplane.McpProtocol.Server.Frame
    alias Backplane.McpProtocol.Server.Handlers
    alias Backplane.McpProtocol.Server.Response

    @impl true
    def init_request(_context, frame), do: {:ok, register_tool(frame)}

    @impl true
    def init(_client_info, frame), do: {:ok, register_tool(frame)}

    @impl true
    def handle_request(%{"method" => "tools/list"} = request, frame) do
      {:reply, result, frame} = Handlers.handle(request, __MODULE__, frame)

      result =
        Map.merge(result, %{
          "ttlMs" => 30_000,
          "cacheScope" => "public",
          "_meta" => %{
            "fixture" => "preserved",
            "io.modelcontextprotocol/serverInfo" => %{"name" => "spoofed", "version" => "0"}
          }
        })

      {:reply, result, frame}
    end

    def handle_request(request, frame), do: Handlers.handle(request, __MODULE__, frame)

    @impl true
    def handle_tool_call("mutate", %{"outcome" => "conflict"}, frame) do
      details = %{
        "code" => "revision_conflict",
        "message" => "The expected revision is stale",
        "details" => %{"current_revision" => 2},
        "retryable" => false
      }

      response =
        Response.tool()
        |> Response.structured(details)
        |> Response.error(details["message"])

      {:reply, response, frame}
    end

    def handle_tool_call("mutate", %{"outcome" => outcome}, frame) do
      result = %{"changed" => outcome == "changed", "revision" => 2}
      {:reply, Response.structured(Response.tool(), result), frame}
    end

    defp register_tool(frame) do
      Frame.register_tool(frame, "mutate",
        input_schema:
          Schema.raw(%{
            "type" => "object",
            "properties" => %{
              "outcome" => %{"type" => "string", "enum" => ["changed", "noop", "conflict"]}
            },
            "required" => ["outcome"]
          })
      )
    end
  end

  setup do
    start_supervised!({FixtureServer, transport: {:streamable_http, start: true}})
    bypass = Bypass.open()
    opts = StreamableHTTPPlug.init(server: FixtureServer)

    for method <- ["POST", "GET", "DELETE"] do
      Bypass.stub(bypass, method, "/mcp", &StreamableHTTPPlug.call(&1, opts))
    end

    on_exit(fn ->
      for key <- [:session_config, :session_supervisor_mod, :authorization_config] do
        :persistent_term.erase({ServerSupervisor, FixtureServer, key})
      end
    end)

    %{url: "http://127.0.0.1:#{bypass.port}/mcp"}
  end

  test "discovers capabilities and cache metadata without initializing a session", context do
    {response, body} = post(context.url, request("server/discover", %{}, 1))

    assert response.status == 200
    assert header(response, "content-type") == "application/json; charset=utf-8"
    refute header(response, "mcp-session-id")
    assert body["id"] == 1
    assert body["jsonrpc"] == "2.0"
    assert body["result"]["resultType"] == "complete"
    assert is_map(body["result"]["capabilities"]["tools"])
    assert @version in body["result"]["supportedVersions"]
    assert body["result"]["ttlMs"] == 0
    assert body["result"]["cacheScope"] == "private"
    assert_server_info(body["result"])
    assert_no_sessions()
  end

  test "cacheable tool lists preserve hints and replace callback-supplied server identity", context do
    for id <- [1, 2] do
      {response, body} = post(context.url, request("tools/list", %{}, id))

      assert response.status == 200
      refute header(response, "mcp-session-id")
      assert body["id"] == id
      assert body["result"]["resultType"] == "complete"
      assert [%{"name" => "mutate", "inputSchema" => schema}] = body["result"]["tools"]
      assert schema["required"] == ["outcome"]
      assert body["result"]["ttlMs"] == 30_000
      assert body["result"]["cacheScope"] == "public"
      assert body["result"]["_meta"]["fixture"] == "preserved"
      assert_server_info(body["result"])
    end

    assert_no_sessions()
  end

  test "method, version and name header mismatches return HTTP 400", context do
    message = tool_request(%{"outcome" => "changed"}, 3)

    for headers <- [
          [{"mcp-method", "tools/list"}],
          [{"mcp-protocol-version", "2099-01-01"}],
          [{"mcp-name", "other-tool"}]
        ] do
      {response, body} = post(context.url, message, headers)
      assert_rpc_error(response, body, 3, -32_020)
    end

    wrong_body_version =
      put_in(message, ["params", "_meta", "io.modelcontextprotocol/protocolVersion"], "2025-06-18")

    {response, body} = post(context.url, wrong_body_version)
    assert_rpc_error(response, body, 3, -32_020)
    assert_no_sessions()
  end

  test "missing required body metadata returns invalid params over HTTP", context do
    message = request("tools/list", %{}, 4)

    malformed = [
      update_in(message, ["params"], &Map.delete(&1, "_meta")),
      update_in(message, ["params", "_meta"], &Map.delete(&1, "io.modelcontextprotocol/protocolVersion")),
      update_in(message, ["params", "_meta"], &Map.delete(&1, "io.modelcontextprotocol/clientCapabilities"))
    ]

    for message <- malformed do
      {response, body} = post(context.url, message)
      assert_rpc_error(response, body, 4, -32_602)
    end
  end

  test "mutation success, no-op and domain errors remain complete structured tool results", context do
    for {id, outcome, structured, is_error} <- [
          {5, "changed", %{"changed" => true, "revision" => 2}, false},
          {6, "noop", %{"changed" => false, "revision" => 2}, false},
          {7, "conflict",
           %{
             "code" => "revision_conflict",
             "message" => "The expected revision is stale",
             "details" => %{"current_revision" => 2},
             "retryable" => false
           }, true}
        ] do
      {response, body} = post(context.url, tool_request(%{"outcome" => outcome}, id))

      assert response.status == 200
      refute header(response, "mcp-session-id")
      assert body["id"] == id
      refute Map.has_key?(body, "error")
      assert body["result"]["resultType"] == "complete"
      assert body["result"]["isError"] == is_error
      assert body["result"]["structuredContent"] == structured
      assert [%{"type" => "text", "text" => text} | _] = body["result"]["content"]
      assert is_binary(text)
      assert_server_info(body["result"])
    end

    assert_no_sessions()
  end

  test "malformed mutation arguments return JSON-RPC invalid params without a tool result", context do
    for arguments <- [
          %{},
          %{"outcome" => nil},
          %{"outcome" => "invalid"},
          %{"outcome" => 1}
        ] do
      {response, body} = post(context.url, tool_request(arguments, 8))
      assert_rpc_error(response, body, 8, -32_602)
    end
  end

  test "rejects an untrusted Origin before dispatch", context do
    {response, _body} =
      post(context.url, request("tools/list", %{}, 9), [{"origin", "https://evil.example.test"}])

    assert response.status == 403
    assert_no_sessions()
  end

  test "modern GET and DELETE advertise POST-only transport", context do
    for method <- [:get, :delete] do
      assert {:ok, response} =
               method
               |> Finch.build(context.url, [{"mcp-protocol-version", @version}])
               |> Finch.request(Backplane.McpProtocol.Finch)

      assert response.status == 405
      assert header(response, "allow") == "POST"
      assert response.body == ""
      refute header(response, "mcp-session-id")
    end
  end

  defp request(method, params, id) do
    meta = %{
      "io.modelcontextprotocol/protocolVersion" => @version,
      "io.modelcontextprotocol/clientCapabilities" => %{},
      "io.modelcontextprotocol/clientInfo" => %{"name" => "http-parity-client", "version" => "1.0.0"}
    }

    %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => Map.put(params, "_meta", meta)}
  end

  defp tool_request(arguments, id), do: request("tools/call", %{"name" => "mutate", "arguments" => arguments}, id)

  defp post(url, message, overrides \\ []) do
    headers = [
      {"content-type", "application/json"},
      {"accept", "application/json, text/event-stream"},
      {"mcp-protocol-version", @version},
      {"mcp-method", message["method"]}
    ]

    headers =
      if message["method"] == "tools/call" do
        headers ++ [{"mcp-name", "mutate"}]
      else
        headers
      end

    headers =
      Enum.reduce(overrides, headers, fn {name, value}, headers -> List.keystore(headers, name, 0, {name, value}) end)

    assert {:ok, response} =
             :post
             |> Finch.build(url, headers, JSON.encode!(message))
             |> Finch.request(Backplane.McpProtocol.Finch)

    {response, JSON.decode!(response.body)}
  end

  defp header(response, name), do: response.headers |> List.keyfind(name, 0, {name, nil}) |> elem(1)

  defp assert_rpc_error(response, body, id, code) do
    assert response.status == 400
    assert body["jsonrpc"] == "2.0"
    assert body["id"] == id
    assert body["error"]["code"] == code
    refute Map.has_key?(body, "result")
    refute header(response, "mcp-session-id")
  end

  defp assert_server_info(result) do
    assert result["_meta"][@server_info_key] == %{"name" => "http-parity-fixture", "version" => "1.0.0"}
  end

  defp assert_no_sessions do
    assert DynamicSupervisor.count_children(Registry.session_supervisor_name(FixtureServer)).active == 0
  end
end

defmodule Backplane.McpProtocol.Server.Modern.RequestContextTest do
  use ExUnit.Case, async: true

  alias Backplane.McpProtocol.Protocol.Registry
  alias Backplane.McpProtocol.Server.Context
  alias Backplane.McpProtocol.Server.Modern.RequestContext

  setup do
    {:ok, profile} = Registry.profile("2026-07-28")
    %{profile: profile}
  end

  test "builds a modern request and keeps MRTR inputs in params", %{profile: profile} do
    request =
      %{
        "progressToken" => 7,
        "io.modelcontextprotocol/clientInfo" => %{"name" => "test-client", "version" => "1.0"},
        "io.modelcontextprotocol/logLevel" => "info",
        "com.example/trace" => "trace-1"
      }
      |> request()
      |> put_in(["params", "inputResponses"], %{"confirm" => %{"action" => "accept"}})
      |> put_in(["params", "requestState"], "opaque-state")

    transport_context = %{
      transport: :http,
      headers: %{"authorization" => "Bearer hidden"},
      remote_ip: {127, 0, 0, 1},
      auth: %{sub: "user-1"},
      assigns: %{tenant: "acme"}
    }

    assert {:ok, context} = RequestContext.build(profile, request, transport_context)
    assert context.protocol_version == "2026-07-28"
    assert context.method == "tools/list"
    assert context.request_id == 1
    assert context.client_capabilities == %{}
    assert context.client_info == %{"name" => "test-client", "version" => "1.0"}
    assert context.log_level == "info"
    assert context.progress_token == 7
    assert context.request_meta["com.example/trace"] == "trace-1"
    assert context.input_responses == %{"confirm" => %{"action" => "accept"}}
    assert context.request_state == "opaque-state"
    assert context.assigns == %{tenant: "acme"}

    assert %Context{
             session_id: nil,
             era: :modern,
             execution_mode: :stateless,
             protocol_version: "2026-07-28",
             client_capabilities: %{},
             input_responses: %{"confirm" => %{"action" => "accept"}},
             request_state: "opaque-state"
           } = RequestContext.to_server_context(context)
  end

  test "accepts omitted recommended metadata and ignores MRTR-shaped custom metadata", %{profile: profile} do
    request =
      request(%{
        "inputResponses" => %{"wrong" => true},
        "requestState" => "wrong-place"
      })

    assert {:ok, context} = RequestContext.build(profile, request, %{transport: :stdio})
    assert context.client_info == nil
    assert context.input_responses == nil
    assert context.request_state == nil
  end

  test "validates and preserves the full client implementation and declared capabilities", %{
    profile: profile
  } do
    client_info = %{
      "name" => "test-client",
      "version" => "1.0",
      "title" => "Test Client",
      "description" => "Exercises modern MCP",
      "websiteUrl" => "https://example.test/client",
      "icons" => [
        %{
          "src" => "data:image/png;base64,AA==",
          "mimeType" => "image/png",
          "sizes" => ["48x48", "any"],
          "theme" => "dark"
        },
        %{"src" => "https://example.test/icon.svg", "theme" => "light"}
      ]
    }

    capabilities = %{
      "roots" => %{},
      "sampling" => %{"context" => %{}, "tools" => %{}, "com.example/setting" => true},
      "elicitation" => %{"form" => %{}, "url" => %{}},
      "experimental" => %{"com.example/feature" => %{"enabled" => true}},
      "extensions" => %{"io.modelcontextprotocol/example" => %{"mode" => "strict"}},
      "com.example/unknown" => ["preserved"]
    }

    request =
      request(%{
        "io.modelcontextprotocol/clientInfo" => client_info,
        "io.modelcontextprotocol/clientCapabilities" => capabilities
      })

    assert {:ok, context} = RequestContext.build(profile, request, %{transport: :stdio})
    assert context.client_info == client_info
    assert context.client_capabilities == capabilities
  end

  test "rejects malformed optional client implementation fields", %{profile: profile} do
    valid = %{"name" => "test-client", "version" => "1.0"}

    invalid_client_info = [
      Map.put(valid, "title", 1),
      Map.put(valid, "description", []),
      Map.put(valid, "websiteUrl", "relative/path"),
      Map.put(valid, "icons", %{}),
      Map.put(valid, "icons", [nil]),
      Map.put(valid, "icons", [%{}]),
      Map.put(valid, "icons", [%{"src" => 7}]),
      Map.put(valid, "icons", [%{"src" => "relative/icon.png"}]),
      Map.put(valid, "icons", [%{"src" => "https://example.test/icon", "mimeType" => 7}]),
      Map.put(valid, "icons", [%{"src" => "https://example.test/icon", "sizes" => "48x48"}]),
      Map.put(valid, "icons", [%{"src" => "https://example.test/icon", "sizes" => [48]}]),
      Map.put(valid, "icons", [%{"src" => "https://example.test/icon", "theme" => "auto"}])
    ]

    for client_info <- invalid_client_info do
      invalid = request(%{"io.modelcontextprotocol/clientInfo" => client_info})

      assert {:error, %{code: -32_602}} =
               RequestContext.build(profile, invalid, %{transport: :stdio})
    end
  end

  test "rejects malformed known client capability declarations", %{profile: profile} do
    invalid_capabilities = [
      %{"roots" => []},
      %{"sampling" => []},
      %{"sampling" => %{"context" => true}},
      %{"sampling" => %{"tools" => []}},
      %{"elicitation" => []},
      %{"elicitation" => %{"form" => true}},
      %{"elicitation" => %{"url" => "enabled"}},
      %{"experimental" => []},
      %{"experimental" => %{"com.example/feature" => true}},
      %{"extensions" => []},
      %{"extensions" => %{"io.modelcontextprotocol/example" => []}}
    ]

    for capabilities <- invalid_capabilities do
      invalid = request(%{"io.modelcontextprotocol/clientCapabilities" => capabilities})

      assert {:error, %{code: -32_602}} =
               RequestContext.build(profile, invalid, %{transport: :stdio})
    end
  end

  test "normalizes the existing Streamable HTTP transport context shape", %{profile: profile} do
    transport_context = %{type: :http, req_headers: [{"MCP-Method", "tools/list"}]}

    assert {:ok, context} = RequestContext.build(profile, request(%{}), transport_context)
    assert context.transport == :http
    assert context.headers == %{"mcp-method" => "tools/list"}
  end

  test "rejects missing or invalid required body metadata", %{profile: profile} do
    valid = request(%{})

    invalid_requests = [
      Map.delete(valid, "params"),
      put_in(valid, ["params", "_meta"], nil),
      update_in(valid, ["params", "_meta"], &Map.delete(&1, "io.modelcontextprotocol/protocolVersion")),
      put_in(valid, ["params", "_meta", "io.modelcontextprotocol/protocolVersion"], 2026),
      update_in(valid, ["params", "_meta"], &Map.delete(&1, "io.modelcontextprotocol/clientCapabilities")),
      put_in(valid, ["params", "_meta", "io.modelcontextprotocol/clientCapabilities"], [])
    ]

    for invalid <- invalid_requests do
      assert {:error, %{code: -32_602}} =
               RequestContext.build(profile, invalid, %{transport: :stdio})
    end
  end

  test "rejects malformed optional metadata and MRTR params, including explicit null", %{profile: profile} do
    invalid_requests = [
      request(%{"io.modelcontextprotocol/clientInfo" => nil}),
      request(%{"io.modelcontextprotocol/clientInfo" => %{"name" => "only-name"}}),
      request(%{"io.modelcontextprotocol/logLevel" => "verbose"}),
      request(%{"progressToken" => %{}}),
      put_in(request(%{}), ["params", "inputResponses"], nil),
      put_in(request(%{}), ["params", "inputResponses"], []),
      put_in(request(%{}), ["params", "requestState"], nil),
      put_in(request(%{}), ["params", "requestState"], 123)
    ]

    for invalid <- invalid_requests do
      assert {:error, %{code: -32_602}} =
               RequestContext.build(profile, invalid, %{transport: :stdio})
    end
  end

  test "additive server context defaults do not change the legacy session path" do
    assert %Context{
             session_id: nil,
             client_info: nil,
             headers: %{},
             remote_ip: nil,
             auth: nil,
             protocol_version: nil,
             era: nil,
             execution_mode: nil,
             client_capabilities: %{},
             request_meta: %{},
             input_responses: nil,
             request_state: nil
           } = %Context{}
  end

  defp request(extra_meta) do
    meta =
      Map.merge(
        %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => %{}
        },
        extra_meta
      )

    %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/list",
      "params" => %{"_meta" => meta}
    }
  end
end

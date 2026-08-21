defmodule Backplane.Transport.ModernMcpTest do
  use Backplane.ConnCase, async: false

  alias Backplane.MCP.Info
  alias Backplane.Registry.{PromptRegistry, ToolRegistry}
  alias Backplane.Transport.{McpPlug, Session}

  @version "2026-07-28"

  defmodule PromptService do
    @moduledoc false

    def get_prompt("fixture_prompt", %{"topic" => topic}, _auth) when is_binary(topic) do
      {:ok,
       %{
         description: "Fixture prompt",
         messages: [
           %{role: "user", content: %{type: "text", text: "Discuss #{topic}"}}
         ]
       }}
    end

    def get_prompt("fixture_prompt", _arguments, _auth), do: {:error, :invalid_arguments}
  end

  defmodule ResourceService do
    @moduledoc false

    def resources(_auth) do
      [
        %{
          uri: "fixture://resource",
          name: "fixture-resource",
          description: "Fixture resource",
          mime_type: "application/json"
        }
      ]
    end

    def resource_templates(_auth), do: []
    def read_resource("fixture://resource", _auth), do: {:ok, ~s({"fixture":true})}
    def read_resource(_uri, _auth), do: {:error, :not_found}
  end

  setup do
    previous_memory_service = Application.get_env(:backplane_mcp, :memory_service)
    previous_tools = :ets.tab2list(:backplane_tools)

    Application.put_env(:backplane_mcp, :memory_service, ResourceService)
    :ets.delete_all_objects(:backplane_tools)
    PromptRegistry.clear()
    register_tools()

    :ok =
      PromptRegistry.register_managed(
        "fixture",
        [
          %{
            name: "fixture_prompt",
            description: "Fixture prompt",
            arguments: [%{name: "topic", required: true}]
          }
        ],
        PromptService
      )

    on_exit(fn ->
      :ets.delete_all_objects(:backplane_tools)
      :ets.insert(:backplane_tools, previous_tools)
      PromptRegistry.clear()

      if is_nil(previous_memory_service) do
        Application.delete_env(:backplane_mcp, :memory_service)
      else
        Application.put_env(:backplane_mcp, :memory_service, previous_memory_service)
      end
    end)

    :ok
  end

  test "discovers and lists modern tools without creating a legacy session" do
    before_count = Session.count()

    discover = modern_conn("server/discover", %{}, id: "discover") |> call_mcp()
    tools = modern_conn("tools/list", %{}, id: "tools") |> call_mcp()

    assert discover.status == 200
    assert get_resp_header(discover, "mcp-session-id") == []

    assert %{
             "result" => %{
               "supportedVersions" => [@version],
               "resultType" => "complete",
               "_meta" => %{
                 "io.modelcontextprotocol/serverInfo" => %{"name" => "backplane"}
               }
             }
           } = response(discover)

    assert tools.status == 200
    assert get_resp_header(tools, "mcp-session-id") == []

    assert %{
             "result" => %{
               "resultType" => "complete",
               "ttlMs" => 0,
               "cacheScope" => "private",
               "tools" => listed_tools
             }
           } = response(tools)

    assert Enum.map(listed_tools, & &1["name"]) == ["public::echo", "secret::echo"]
    assert Session.count() == before_count
  end

  test "keeps an unmarked initialize request on the legacy default" do
    before_count = Session.count()

    conn =
      legacy_conn("initialize", %{
        "protocolVersion" => @version,
        "clientInfo" => %{"name" => "legacy-test", "version" => "1.0.0"},
        "capabilities" => %{}
      })
      |> call_mcp()

    assert conn.status == 200
    assert get_in(response(conn), ["result", "protocolVersion"]) == Info.protocol_version()
    assert Info.protocol_version() == "2025-11-25"
    assert [session_id] = get_resp_header(conn, "mcp-session-id")
    assert Session.count() == before_count + 1

    on_exit(fn -> Session.delete(session_id) end)
  end

  test "rejects removed modern request surfaces" do
    for method <- [
          "initialize",
          "ping",
          "logging/setLevel",
          "resources/subscribe",
          "resources/unsubscribe",
          "tasks/create",
          "tasks/get",
          "tasks/result",
          "tasks/cancel"
        ] do
      conn = modern_conn(method, %{}, id: method) |> call_mcp()

      assert conn.status == 404
      assert get_in(response(conn), ["error", "code"]) == -32_601
    end
  end

  test "validates required modern metadata and mirrored headers" do
    missing_capabilities =
      "tools/list"
      |> modern_message(%{}, id: "missing-capabilities")
      |> update_in(
        ["params", "_meta"],
        &Map.delete(&1, "io.modelcontextprotocol/clientCapabilities")
      )
      |> modern_message_conn()
      |> call_mcp()

    assert missing_capabilities.status == 400
    assert get_in(response(missing_capabilities), ["error", "code"]) == -32_602

    mismatch =
      modern_conn("tools/list", %{}, id: "method-mismatch", method_header: "prompts/list")
      |> call_mcp()

    assert mismatch.status == 400
    assert get_in(response(mismatch), ["error", "code"]) == -32_020
    assert get_resp_header(mismatch, "x-mcp-protocol-version") == [@version]

    unsupported =
      modern_conn("tools/list", %{}, id: "unsupported", version: "2099-01-01")
      |> call_mcp()

    assert unsupported.status == 400
    assert get_in(response(unsupported), ["error", "code"]) == -32_022
    assert get_resp_header(unsupported, "x-mcp-protocol-version") == [@version]
  end

  test "unknown modern markers retain the modern version on oversized bodies" do
    conn =
      conn(:post, "/", String.duplicate("x", 2_000_000))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("mcp-protocol-version", "2099-01-01")
      |> put_req_header("mcp-method", "tools/list")
      |> call_mcp()

    assert conn.status == 413
    assert response(conn) == %{"error" => "Request body too large"}
    assert get_resp_header(conn, "x-mcp-protocol-version") == [@version]
  end

  test "rejects modern JSON batches as invalid requests" do
    batch = [modern_message("tools/list", %{}, id: "batch-item")]

    conn = raw_modern_conn(JSON.encode!(batch), "tools/list") |> call_mcp()

    assert conn.status == 400
    assert get_in(response(conn), ["error", "code"]) == -32_600
  end

  test "rejects a modern marker combined with a legacy session" do
    session_id = "modern-request-with-legacy-session"
    Session.create(session_id, "2025-11-25", %{}, %{})
    on_exit(fn -> Session.delete(session_id) end)

    conn =
      "tools/list"
      |> modern_conn(%{}, id: "session-conflict")
      |> put_req_header("mcp-session-id", session_id)
      |> call_mcp()

    assert conn.status == 400
    assert get_in(response(conn), ["error", "code"]) == -32_600
    assert Session.get(session_id)
  end

  test "contains modern callback failures as internal errors" do
    ToolRegistry.register_managed("broken", [
      %{
        name: "broken::tool",
        description: "Malformed callback fixture",
        input_schema: :not_a_schema,
        handler: fn _arguments -> {:ok, %{}} end
      }
    ])

    conn = modern_conn("tools/list", %{}, id: "callback-failure") |> call_mcp()

    assert conn.status == 200
    assert get_in(response(conn), ["error", "code"]) == -32_603
  end

  test "enforces scoped modern tool listing and calls" do
    {_client, token} =
      Backplane.Fixtures.insert_client(
        token: "modern-scoped-token",
        scopes: ["public::echo", "fixture::*"]
      )

    list = modern_conn("tools/list", %{}, auth_token: token) |> call_mcp()

    assert get_in(response(list), ["result", "tools"]) |> Enum.map(& &1["name"]) == [
             "public::echo"
           ]

    allowed =
      modern_conn(
        "tools/call",
        %{"name" => "public::echo", "arguments" => %{"value" => "hello"}},
        auth_token: token
      )
      |> call_mcp()

    assert get_in(response(allowed), ["result", "structuredContent"]) == %{"echo" => "hello"}

    denied =
      modern_conn(
        "tools/call",
        %{"name" => "secret::echo", "arguments" => %{"value" => "hidden"}},
        auth_token: token
      )
      |> call_mcp()

    assert get_in(response(denied), ["error"]) == %{
             "code" => -32_000,
             "message" => "insufficient_scope"
           }
  end

  test "serves modern resources, prompts, and completions" do
    resources = modern_conn("resources/list", %{}) |> call_mcp() |> response()
    assert get_in(resources, ["result", "resources", Access.at(0), "uri"]) == "fixture://resource"

    resource =
      modern_conn("resources/read", %{"uri" => "fixture://resource"})
      |> call_mcp()
      |> response()

    assert get_in(resource, ["result", "contents", Access.at(0), "text"]) == ~s({"fixture":true})

    prompts = modern_conn("prompts/list", %{}) |> call_mcp() |> response()
    assert get_in(prompts, ["result", "prompts", Access.at(0), "name"]) == "fixture_prompt"

    prompt =
      modern_conn(
        "prompts/get",
        %{"name" => "fixture_prompt", "arguments" => %{"topic" => "Elixir"}}
      )
      |> call_mcp()
      |> response()

    assert get_in(prompt, ["result", "messages", Access.at(0), "content", "text"]) ==
             "Discuss Elixir"

    completion =
      modern_conn(
        "completion/complete",
        %{
          "ref" => %{"type" => "ref/tool", "name" => "public::echo"},
          "argument" => %{"name" => "tool_name", "value" => "public"}
        }
      )
      |> call_mcp()
      |> response()

    assert get_in(completion, ["result", "completion", "values"]) == ["public::echo"]
  end

  test "uses the modern parse-error envelope only for marked malformed JSON" do
    modern = raw_modern_conn("not json", "tools/list") |> call_mcp()

    assert modern.status == 400
    assert get_resp_header(modern, "x-mcp-protocol-version") == [@version]

    assert response(modern) == %{
             "jsonrpc" => "2.0",
             "id" => nil,
             "error" => %{
               "code" => -32_700,
               "message" => "Parse error",
               "data" => %{"message" => "Invalid JSON"}
             }
           }

    legacy =
      conn(:post, "/", "not json")
      |> put_req_header("content-type", "application/json")
      |> call_mcp()

    assert legacy.status == 400
    assert get_resp_header(legacy, "x-mcp-protocol-version") == [Info.protocol_version()]
    assert response(legacy) == %{"error" => "Malformed request body"}
  end

  defp register_tools do
    input_schema = %{
      "type" => "object",
      "properties" => %{"value" => %{"type" => "string"}},
      "required" => ["value"],
      "additionalProperties" => false
    }

    ToolRegistry.register_managed("public", [
      %{
        name: "public::echo",
        description: "Echo a value",
        input_schema: input_schema,
        output_schema: %{
          "type" => "object",
          "properties" => %{"echo" => %{"type" => "string"}}
        },
        handler: fn arguments -> {:ok, %{"echo" => arguments["value"]}} end
      }
    ])

    ToolRegistry.register_managed("secret", [
      %{
        name: "secret::echo",
        description: "Hidden echo",
        input_schema: input_schema,
        handler: fn arguments -> {:ok, arguments} end
      }
    ])
  end

  defp modern_conn(method, params, opts \\ []) do
    method
    |> modern_message(params, opts)
    |> modern_message_conn(opts)
  end

  defp modern_message_conn(message, opts \\ []) do
    version = Keyword.get(opts, :version, @version)
    method_header = Keyword.get(opts, :method_header, message["method"])

    conn = raw_modern_conn(JSON.encode!(message), method_header, version: version)
    conn = maybe_put_name_header(conn, message["method"], message["params"])

    case Keyword.get(opts, :auth_token) do
      token when is_binary(token) -> put_req_header(conn, "authorization", "Bearer #{token}")
      nil -> conn
    end
  end

  defp raw_modern_conn(body, method, opts \\ []) do
    version = Keyword.get(opts, :version, @version)

    conn(:post, "/", body)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json")
    |> put_req_header("mcp-protocol-version", version)
    |> put_req_header("mcp-method", method)
  end

  defp modern_message(method, params, opts) do
    version = Keyword.get(opts, :version, @version)

    %{
      "jsonrpc" => "2.0",
      "id" => Keyword.get(opts, :id, System.unique_integer([:positive, :monotonic])),
      "method" => method,
      "params" =>
        Map.put(params, "_meta", %{
          "io.modelcontextprotocol/protocolVersion" => version,
          "io.modelcontextprotocol/clientCapabilities" => %{},
          "io.modelcontextprotocol/clientInfo" => %{
            "name" => "backplane-modern-endpoint-test",
            "version" => "1.0.0"
          }
        })
    }
  end

  defp legacy_conn(method, params) do
    body = %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}

    conn(:post, "/", JSON.encode!(body))
    |> put_req_header("content-type", "application/json")
  end

  defp maybe_put_name_header(conn, method, params)

  defp maybe_put_name_header(conn, "resources/read", params),
    do: put_req_header(conn, "mcp-name", params["uri"])

  defp maybe_put_name_header(conn, method, params) when method in ["prompts/get", "tools/call"],
    do: put_req_header(conn, "mcp-name", params["name"])

  defp maybe_put_name_header(conn, _method, _params), do: conn

  defp call_mcp(conn), do: McpPlug.call(conn, McpPlug.init([]))
  defp response(conn), do: JSON.decode!(conn.resp_body)
end

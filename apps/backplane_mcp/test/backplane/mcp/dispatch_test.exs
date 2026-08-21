defmodule Backplane.MCP.DispatchTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Backplane.MCP.Dispatch
  alias Backplane.Registry.{PromptRegistry, Tool, ToolRegistry}
  alias Backplane.Transport.McpHandler

  @required_context_keys [:protocol_version, :scopes, :auth, :client]
  @malformed_context_cases [
    :non_map,
    :non_binary_protocol_version,
    :non_map_auth,
    :non_binary_scope
  ]

  defmodule PromptService do
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
    def get_prompt("failing_prompt", _arguments, _auth), do: {:error, :backend_failed}
  end

  defmodule ResourceService do
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

    def resource_templates(_auth) do
      [
        %{
          uri_template: "fixture://resource/{id}",
          name: "fixture-template",
          description: "Fixture template",
          mime_type: "application/json"
        }
      ]
    end

    def read_resource("fixture://resource", _auth), do: {:ok, ~s({"fixture":true})}
    def read_resource(_uri, _auth), do: {:error, :not_found}
  end

  setup do
    previous_memory_service = Application.get_env(:backplane_mcp, :memory_service)
    Application.put_env(:backplane_mcp, :memory_service, ResourceService)

    :ets.delete_all_objects(:backplane_tools)
    PromptRegistry.clear()

    register_tools(self())

    :ok =
      PromptRegistry.register_managed(
        "fixture",
        [
          %{
            name: "fixture_prompt",
            description: "Fixture prompt",
            arguments: [%{name: "topic", required: true}]
          },
          %{name: "failing_prompt", description: "Failing prompt", arguments: []}
        ],
        PromptService
      )

    on_exit(fn ->
      :ets.delete_all_objects(:backplane_tools)
      PromptRegistry.clear()

      if is_nil(previous_memory_service) do
        Application.delete_env(:backplane_mcp, :memory_service)
      else
        Application.put_env(:backplane_mcp, :memory_service, previous_memory_service)
      end
    end)

    :ok
  end

  test "lists and calls scoped tools with string-keyed payloads" do
    assert {:ok, %{"tools" => tools}} = Dispatch.execute("tools/list", %{}, context())
    assert Enum.all?(tools, &Map.has_key?(&1, "name"))
    assert Enum.any?(tools, &(&1["name"] == "fixture::echo"))
    refute Enum.any?(tools, &(&1["name"] == "hub::hidden"))

    assert {:ok,
            %{
              "content" => [%{"type" => "text", "text" => text}],
              "structuredContent" => %{"echo" => "hello"}
            }} =
             Dispatch.execute(
               "tools/call",
               %{"name" => "fixture::echo", "arguments" => %{"value" => "hello"}},
               context()
             )

    assert JSON.decode!(text) == %{"echo" => "hello"}

    assert [%Tool{name: "fixture::echo"}] =
             Dispatch.visible_tools(context(["fixture::echo"]))
             |> Enum.filter(&(&1.name == "fixture::echo"))

    refute Enum.any?(
             Dispatch.visible_tools(context(["fixture::echo"])),
             &(&1.name == "secret::echo")
           )
  end

  test "projects modern catalog metadata without changing legacy version shapes" do
    :ok =
      ToolRegistry.register_native(%Tool{
        name: "catalog::lookup",
        title: "Lookup",
        description: "Find one record",
        input_schema: %{"type" => "object"},
        output_schema: %{"type" => "boolean"},
        annotations: %{"readOnlyHint" => true},
        icon: %{"url" => "https://example.test/legacy.svg"},
        icons: [%{"src" => "https://example.test/modern.svg"}],
        meta: %{"vendor" => %{"stable" => true}},
        execution: %{"taskSupport" => "required"},
        origin: :native
      })

    legacy_keys = %{
      "2024-11-05" => ~w(description inputSchema name),
      "2025-03-26" => ~w(annotations description inputSchema name),
      "2025-06-18" => ~w(annotations description inputSchema name outputSchema),
      "2025-11-25" => ~w(annotations description icon inputSchema name outputSchema)
    }

    for {version, expected_keys} <- legacy_keys do
      version_context = %{context(["catalog::*"]) | protocol_version: version}
      assert {:ok, %{"tools" => tools}} = Dispatch.execute("tools/list", %{}, version_context)

      assert %{"name" => "catalog::lookup"} =
               tool = Enum.find(tools, &(&1["name"] == "catalog::lookup"))

      assert Enum.sort(Map.keys(tool)) == Enum.sort(expected_keys)
      refute Map.has_key?(tool, "execution")
    end

    modern_context = %{context(["*"]) | protocol_version: "2026-07-28"}
    assert {:ok, %{"tools" => modern_tools}} = Dispatch.execute("tools/list", %{}, modern_context)

    assert %{
             "name" => "catalog::lookup",
             "title" => "Lookup",
             "icons" => [%{"src" => "https://example.test/modern.svg"}],
             "_meta" => %{"vendor" => %{"stable" => true}}
           } = modern = Enum.find(modern_tools, &(&1["name"] == "catalog::lookup"))

    assert Enum.sort(Map.keys(modern)) ==
             Enum.sort(
               ~w(_meta annotations description icons inputSchema name outputSchema title)
             )

    refute Map.has_key?(modern, "icon")
    refute Map.has_key?(modern, "execution")
    refute get_in(modern, ["execution", "taskSupport"])

    assert fixture = Enum.find(modern_tools, &(&1["name"] == "fixture::echo"))
    refute Map.has_key?(fixture, "title")
    refute Map.has_key?(fixture, "icons")
    refute Map.has_key?(fixture, "_meta")
  end

  test "lists and reads resources with string-keyed payloads" do
    assert {:ok,
            %{
              "resources" => [
                %{
                  "uri" => "fixture://resource",
                  "name" => "fixture-resource",
                  "mimeType" => "application/json"
                }
              ]
            }} = Dispatch.execute("resources/list", %{}, context())

    assert {:ok,
            %{
              "resourceTemplates" => [
                %{
                  "uriTemplate" => "fixture://resource/{id}",
                  "name" => "fixture-template"
                }
              ]
            }} = Dispatch.execute("resources/templates/list", %{}, context())

    assert {:ok,
            %{
              "contents" => [
                %{
                  "uri" => "fixture://resource",
                  "mimeType" => "application/json",
                  "text" => ~s({"fixture":true})
                }
              ]
            }} =
             Dispatch.execute(
               "resources/read",
               %{"uri" => "fixture://resource"},
               context()
             )
  end

  test "lists and gets authorized prompts with string-keyed payloads" do
    assert {:ok, %{"prompts" => prompts}} = Dispatch.execute("prompts/list", %{}, context())
    assert Enum.any?(prompts, &(&1["name"] == "fixture_prompt"))

    assert {:ok,
            %{
              "description" => "Fixture prompt",
              "messages" => [
                %{
                  "role" => "user",
                  "content" => %{"type" => "text", "text" => "Discuss Elixir"}
                }
              ]
            }} =
             Dispatch.execute(
               "prompts/get",
               %{"name" => "fixture_prompt", "arguments" => %{"topic" => "Elixir"}},
               context()
             )
  end

  test "returns string-keyed completion results" do
    assert {:ok,
            %{
              "completion" => %{
                "values" => values,
                "hasMore" => false,
                "total" => total
              }
            }} =
             Dispatch.execute(
               "completion/complete",
               %{
                 "ref" => %{"type" => "ref/tool", "name" => "fixture::echo"},
                 "argument" => %{"name" => "tool_name", "value" => "fixture"}
               },
               context()
             )

    assert "fixture::echo" in values
    assert total == length(values)
  end

  test "returns semantic application errors" do
    assert {:error, :invalid_params, _message} =
             Dispatch.execute("tools/call", %{"arguments" => %{}}, context())

    assert {:error, :not_found, _message} =
             Dispatch.execute(
               "resources/read",
               %{"uri" => "fixture://missing"},
               context()
             )

    assert {:error, :method_not_found, _message} =
             Dispatch.execute("unknown/method", %{}, context())

    assert {:error, :insufficient_scope, _message} =
             Dispatch.execute(
               "tools/call",
               %{"name" => "secret::echo", "arguments" => %{"value" => "hidden"}},
               context(["fixture::*"])
             )

    assert {:error, :internal_error, _message} =
             Dispatch.execute(
               "prompts/get",
               %{"name" => "failing_prompt", "arguments" => %{}},
               context()
             )
  end

  test "preserves false and explicit nil structured content by key presence" do
    assert {:ok, false_result} =
             Dispatch.execute(
               "tools/call",
               %{"name" => "fixture::structured_false", "arguments" => %{}},
               context()
             )

    assert Map.fetch(false_result, "structuredContent") == {:ok, false}

    assert {:ok, nil_result} =
             Dispatch.execute(
               "tools/call",
               %{"name" => "fixture::structured_nil", "arguments" => %{}},
               context()
             )

    assert Map.fetch(nil_result, "structuredContent") == {:ok, nil}
  end

  test "keeps the raw public tool-call seam compatible" do
    assert {:ok, %{"echo" => "direct"}} =
             Dispatch.call_tool("fixture::echo", %{"value" => "direct"}, context().auth)

    assert {:ok, %{"echo" => "delegated"}} =
             McpHandler.dispatch_tool_call("fixture::echo", %{"value" => "delegated"})

    assert {:ok, %{"echo" => "authenticated"}} =
             McpHandler.dispatch_tool_call(
               "fixture::echo",
               %{"value" => "authenticated"},
               context().auth
             )

    assert {:error, message} = Dispatch.call_tool("missing::tool", %{}, context().auth)
    assert message =~ "Unknown tool"
  end

  test "opens the legacy SSE response before executing a slow tool" do
    test_pid = self()
    handler_id = "dispatch-sse-order-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:backplane, :sse_stream, :start],
        fn _event, _measurements, metadata, pid ->
          send(pid, {:sse_started, metadata.tool})
        end,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    request_body = %{
      "jsonrpc" => "2.0",
      "id" => "slow-sse",
      "method" => "tools/call",
      "params" => %{"name" => "fixture::slow", "arguments" => %{}}
    }

    request =
      Task.async(fn ->
        :post
        |> conn("/", "")
        |> put_req_header("accept", "text/event-stream")
        |> assign(:tool_scopes, ["*"])
        |> assign(:resource_auth, context().auth)
        |> then(&%{&1 | body_params: request_body})
        |> McpHandler.handle()
      end)

    assert_receive {:sse_started, "fixture::slow"}, 250
    assert_receive {:slow_tool_started, slow_tool}
    send(slow_tool, :finish)
    assert %Plug.Conn{status: 200} = Task.await(request, 1_000)
  end

  for context_key <- @required_context_keys do
    test "execute rejects a context missing #{context_key}" do
      incomplete_context = Map.delete(context(), unquote(context_key))

      assert {:error, :internal_error, "Internal error"} =
               Dispatch.execute("tools/list", %{}, incomplete_context)
    end

    test "visible_tools rejects a context missing #{context_key}" do
      incomplete_context = Map.delete(context(["fixture::echo"]), unquote(context_key))

      assert {:error, :internal_error, "Internal error"} =
               Dispatch.visible_tools(incomplete_context)
    end

    test "validate_tool_call rejects a context missing #{context_key}" do
      incomplete_context = Map.delete(context(["fixture::echo"]), unquote(context_key))

      assert {:error, :internal_error, "Internal error"} =
               Dispatch.validate_tool_call(
                 %{"name" => "secret::echo", "arguments" => %{"value" => "hidden"}},
                 incomplete_context
               )
    end
  end

  for context_case <- @malformed_context_cases do
    test "execute rejects #{context_case} context" do
      assert {:error, :internal_error, "Internal error"} =
               Dispatch.execute("tools/list", %{}, malformed_context(unquote(context_case)))
    end

    test "visible_tools rejects #{context_case} context" do
      assert {:error, :internal_error, "Internal error"} =
               Dispatch.visible_tools(malformed_context(unquote(context_case)))
    end

    test "validate_tool_call rejects #{context_case} context" do
      assert {:error, :internal_error, "Internal error"} =
               Dispatch.validate_tool_call(
                 %{"name" => "secret::echo", "arguments" => %{"value" => "hidden"}},
                 malformed_context(unquote(context_case))
               )
    end
  end

  defp register_tools(test_pid) do
    ToolRegistry.register_managed("fixture", [
      %{
        name: "fixture::echo",
        description: "Echo a value",
        input_schema: %{
          "type" => "object",
          "properties" => %{"value" => %{"type" => "string"}},
          "required" => ["value"],
          "additionalProperties" => false
        },
        output_schema: %{
          "type" => "object",
          "properties" => %{"echo" => %{"type" => "string"}}
        },
        handler: fn arguments -> {:ok, %{"echo" => arguments["value"]}} end
      },
      %{
        name: "fixture::structured_false",
        description: "Return false structured content",
        input_schema: %{"type" => "object"},
        handler: fn _arguments ->
          {:ok,
           %{
             "content" => [%{"type" => "text", "text" => "false"}],
             "structuredContent" => false
           }}
        end
      },
      %{
        name: "fixture::structured_nil",
        description: "Return nil structured content",
        input_schema: %{"type" => "object"},
        handler: fn _arguments ->
          {:ok,
           %{
             "content" => [%{"type" => "text", "text" => "nil"}],
             "structuredContent" => nil
           }}
        end
      },
      %{
        name: "fixture::slow",
        description: "Block until the test releases the call",
        input_schema: %{"type" => "object"},
        handler: fn _arguments ->
          send(test_pid, {:slow_tool_started, self()})

          receive do
            :finish -> {:ok, "finished"}
          after
            1_000 -> {:error, "test timeout"}
          end
        end
      }
    ])

    ToolRegistry.register_managed("secret", [
      %{
        name: "secret::echo",
        description: "Hidden echo",
        input_schema: %{"type" => "object"},
        handler: fn arguments -> {:ok, arguments} end
      }
    ])

    ToolRegistry.register_managed("hub", [
      %{
        name: "hub::hidden",
        description: "Management tool",
        input_schema: %{"type" => "object"},
        handler: fn arguments -> {:ok, arguments} end
      }
    ])
  end

  defp context(scopes \\ ["*"]) do
    %{
      protocol_version: "2025-11-25",
      scopes: scopes,
      auth: %{kind: :open, client_id: nil, scopes: [], subject: nil, principal_metadata: %{}},
      client: nil
    }
  end

  defp malformed_context(:non_map), do: :invalid_context

  defp malformed_context(:non_binary_protocol_version) do
    %{context() | protocol_version: 20_260_728}
  end

  defp malformed_context(:non_map_auth), do: %{context() | auth: :invalid_auth}
  defp malformed_context(:non_binary_scope), do: %{context() | scopes: ["fixture::*", :invalid]}
end

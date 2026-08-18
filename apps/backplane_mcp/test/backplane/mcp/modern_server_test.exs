defmodule Backplane.MCP.ModernServerTest do
  use ExUnit.Case, async: false

  alias Backplane.MCP.ModernServer
  alias Backplane.McpProtocol.MCP.Error
  alias Backplane.McpProtocol.Protocol.Registry
  alias Backplane.McpProtocol.Server.Frame
  alias Backplane.McpProtocol.Server.Modern.{Executor, RequestContext}
  alias Backplane.Registry.{PromptRegistry, ToolRegistry}
  alias Backplane.Transport.Session

  @version "2026-07-28"
  @input_schema %{
    "type" => "object",
    "properties" => %{"value" => %{"type" => "string"}},
    "required" => ["value"],
    "additionalProperties" => false
  }
  @output_schema %{
    "type" => "object",
    "properties" => %{"echo" => %{"type" => "string"}}
  }
  @annotations %{"readOnlyHint" => true}

  defmodule PromptService do
    @moduledoc false

    def get_prompt("failing_prompt", _arguments, _auth), do: {:error, :backend_failed}
  end

  defmodule ResourceService do
    @moduledoc false

    def resources(_auth), do: []
    def resource_templates(_auth), do: []
    def read_resource(_uri, _auth), do: {:error, :not_found}
  end

  setup do
    task_supervisor = start_supervised!({Task.Supervisor, []})
    previous_memory_service = Application.get_env(:backplane_mcp, :memory_service)
    Application.put_env(:backplane_mcp, :memory_service, ResourceService)

    :ets.delete_all_objects(:backplane_tools)
    PromptRegistry.clear()
    register_base_tools()

    :ok =
      PromptRegistry.register_managed(
        "fixture",
        [%{name: "failing_prompt", description: "Failing prompt", arguments: []}],
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

    %{task_supervisor: task_supervisor}
  end

  test "discovers only the approved modern capabilities", %{task_supervisor: task_supervisor} do
    assert {:response, %{"result" => discovery}} =
             execute_modern("server/discover", %{}, request_context(), task_supervisor)

    assert discovery["supportedVersions"] == [@version]

    assert discovery["capabilities"] == %{
             "completions" => %{},
             "prompts" => %{},
             "resources" => %{},
             "tools" => %{}
           }

    for removed <- ~w(extensions experimental tasks logging subscriptions) do
      refute Map.has_key?(discovery["capabilities"], removed)
    end
  end

  test "lists and calls only tools visible to request-local scopes", %{
    task_supervisor: task_supervisor
  } do
    allowed_context = request_context(["public::echo"])

    assert {:response, %{"result" => %{"tools" => tools}}} =
             execute_modern("tools/list", %{}, allowed_context, task_supervisor)

    assert Enum.map(tools, & &1["name"]) == ["public::echo"]

    assert {:response,
            %{
              "result" => %{
                "structuredContent" => %{"echo" => "hello"},
                "resultType" => "complete"
              }
            }} =
             execute_modern(
               "tools/call",
               %{"name" => "public::echo", "arguments" => %{"value" => "hello"}},
               allowed_context,
               task_supervisor
             )

    assert {:response,
            %{
              "error" => %{
                "code" => -32_000,
                "message" => "insufficient_scope"
              }
            }} =
             execute_modern(
               "tools/call",
               %{"name" => "secret::echo", "arguments" => %{"value" => "hidden"}},
               allowed_context,
               task_supervisor
             )
  end

  test "does not create legacy sessions for modern calls", %{task_supervisor: task_supervisor} do
    before_count = Session.count()

    assert {:response, %{"result" => _result}} =
             execute_modern("tools/list", %{}, request_context(), task_supervisor)

    assert {:response, %{"result" => _result}} =
             execute_modern("server/discover", %{}, request_context(), task_supervisor)

    assert Session.count() == before_count
  end

  test "maps shared dispatch errors to modern protocol errors", %{
    task_supervisor: task_supervisor
  } do
    context = request_context(["public::echo"])

    for {method, params, code, message} <- [
          {"subscriptions/listen", %{}, -32_601, "Method not found"},
          {"tools/call", %{"arguments" => %{}}, -32_602, "Invalid params"},
          {"resources/read", %{"uri" => "fixture://missing"}, -32_602, "Invalid params"},
          {"tools/call", %{"name" => "secret::echo", "arguments" => %{}}, -32_000,
           "insufficient_scope"},
          {"prompts/get", %{"name" => "failing_prompt", "arguments" => %{}}, -32_603,
           "Internal error"}
        ] do
      assert {:response,
              %{
                "error" => %{
                  "code" => ^code,
                  "message" => ^message
                }
              }} = execute_modern(method, params, context, task_supervisor)
    end
  end

  test "preserves false and nil structured content", %{task_supervisor: task_supervisor} do
    register_structured_tools()
    context = request_context(["structured::*"])

    assert {:response, %{"result" => false_result}} =
             execute_modern(
               "tools/call",
               %{"name" => "structured::false", "arguments" => %{}},
               context,
               task_supervisor
             )

    assert Map.fetch(false_result, "structuredContent") == {:ok, false}

    assert {:response, %{"result" => nil_result}} =
             execute_modern(
               "tools/call",
               %{"name" => "structured::nil", "arguments" => %{}},
               context,
               task_supervisor
             )

    assert Map.fetch(nil_result, "structuredContent") == {:ok, nil}
  end

  test "initializes fresh frames with the complete dispatch context and visible tool schemas" do
    client = %{id: "client-1", name: "Modern client"}

    assigns = %{
      resource_auth: auth(["public::echo"]),
      tool_scopes: ["public::echo"],
      client: client
    }

    context = build_request_context(assigns)

    assert {:ok, frame} = ModernServer.init_request(context, Frame.new(context.assigns))

    assert frame.assigns.dispatch_context == %{
             protocol_version: @version,
             scopes: ["public::echo"],
             auth: auth(["public::echo"]),
             client: client
           }

    assert Map.keys(frame.assigns.dispatch_context) |> Enum.sort() ==
             [:auth, :client, :protocol_version, :scopes]

    assert %{
             "public::echo" => %{
               input_schema: @input_schema,
               output_schema: @output_schema,
               annotations: @annotations
             }
           } = frame.tools

    empty_context =
      build_request_context(%{
        resource_auth: auth(["*"]),
        tool_scopes: [],
        client: client
      })

    assert {:ok, empty_frame} =
             ModernServer.init_request(empty_context, Frame.new(empty_context.assigns))

    assert empty_frame.assigns.dispatch_context.scopes == []
    assert empty_frame.tools == %{}
    assert frame.tools != empty_frame.tools
  end

  test "uses a trusted open fallback only when request assigns omit auth and scopes" do
    context = build_request_context(%{})

    assert {:ok, frame} = ModernServer.init_request(context, Frame.new(context.assigns))

    assert frame.assigns.dispatch_context == %{
             protocol_version: @version,
             scopes: ["*"],
             auth: %{kind: :open, client_id: nil, scopes: ["*"]},
             client: nil
           }
  end

  test "uses restricted transport auth when Backplane assigns are absent", %{
    task_supervisor: task_supervisor
  } do
    context = transport_context(restricted_auth(["public::echo"]), %{})

    assert {:response, %{"result" => %{"tools" => tools}}} =
             execute_modern("tools/list", %{}, context, task_supervisor)

    assert Enum.map(tools, & &1["name"]) == ["public::echo"]

    assert {:response, %{"error" => %{"code" => -32_000, "message" => "insufficient_scope"}}} =
             execute_modern(
               "tools/call",
               %{"name" => "secret::echo", "arguments" => %{"value" => "hidden"}},
               context,
               task_supervisor
             )
  end

  test "normalizes consistent string-keyed Backplane auth assigns", %{
    task_supervisor: task_supervisor
  } do
    resource_auth = restricted_auth(["public::echo"])
    client = %{"id" => "client-1", "name" => "Modern client"}

    assigns = %{
      "resource_auth" => string_keyed_auth(resource_auth),
      "tool_scopes" => ["public::echo"],
      "client" => client
    }

    context = transport_context(resource_auth, assigns)

    assert {:response, %{"result" => %{"tools" => tools}}} =
             execute_modern("tools/list", %{}, context, task_supervisor)

    assert Enum.map(tools, & &1["name"]) == ["public::echo"]

    request_context = build_request_context(assigns, resource_auth)

    assert {:ok, frame} =
             ModernServer.init_request(request_context, Frame.new(request_context.assigns))

    assert frame.assigns.dispatch_context.auth == resource_auth
    assert frame.assigns.dispatch_context.scopes == ["public::echo"]
    assert frame.assigns.dispatch_context.client == client
  end

  test "keeps explicit empty scopes deny-all under restricted transport auth", %{
    task_supervisor: task_supervisor
  } do
    resource_auth = restricted_auth(["public::echo"])
    context = transport_context(resource_auth, %{tool_scopes: []})

    assert {:response, %{"result" => %{"tools" => []}}} =
             execute_modern("tools/list", %{}, context, task_supervisor)
  end

  test "fails closed for explicit nil, malformed, conflicting, or broadened auth assigns" do
    restricted = restricted_auth(["public::echo"])
    secret = restricted_auth(["secret::echo"])

    malformed_assigns = [
      %{resource_auth: nil},
      %{"resource_auth" => nil},
      %{tool_scopes: nil},
      %{"tool_scopes" => nil},
      %{resource_auth: :invalid},
      %{tool_scopes: :invalid},
      %{tool_scopes: ["public::echo", :invalid]},
      %{resource_auth: secret, tool_scopes: ["secret::echo"]},
      %{resource_auth: restricted, tool_scopes: ["secret::echo"]},
      %{"resource_auth" => string_keyed_auth(secret), resource_auth: restricted},
      %{"tool_scopes" => ["secret::echo"], tool_scopes: ["public::echo"]}
    ]

    for assigns <- malformed_assigns do
      context = build_request_context(assigns, restricted)

      assert {:error, %Error{code: -32_603, reason: :internal_error}, %Frame{}} =
               ModernServer.init_request(context, Frame.new(context.assigns))
    end
  end

  test "does not leak request-local tools between restricted authorities", %{
    task_supervisor: task_supervisor
  } do
    public_context = transport_context(restricted_auth(["public::echo"]), %{})
    secret_context = transport_context(restricted_auth(["secret::echo"]), %{})

    assert {:response, %{"result" => %{"tools" => public_tools}}} =
             execute_modern("tools/list", %{}, public_context, task_supervisor)

    assert {:response, %{"result" => %{"tools" => secret_tools}}} =
             execute_modern("tools/list", %{}, secret_context, task_supervisor)

    assert Enum.map(public_tools, & &1["name"]) == ["public::echo"]
    assert Enum.map(secret_tools, & &1["name"]) == ["secret::echo"]
  end

  test "supervises the production callback task supervisor" do
    pid = Process.whereis(Backplane.MCP.ModernTaskSupervisor)

    assert is_pid(pid)
    assert Process.alive?(pid)

    assert Enum.any?(
             Supervisor.which_children(BackplaneMcp.Supervisor),
             &match?({_id, ^pid, :supervisor, _modules}, &1)
           )
  end

  defp register_base_tools do
    ToolRegistry.register_managed("public", [
      %{
        name: "public::echo",
        description: "Echo a value",
        input_schema: @input_schema,
        output_schema: @output_schema,
        annotations: @annotations,
        handler: fn arguments -> {:ok, %{"echo" => arguments["value"]}} end
      }
    ])

    ToolRegistry.register_managed("secret", [
      %{
        name: "secret::echo",
        description: "Hidden echo",
        input_schema: @input_schema,
        handler: fn arguments -> {:ok, arguments} end
      }
    ])
  end

  defp register_structured_tools do
    ToolRegistry.register_managed("structured", [
      %{
        name: "structured::false",
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
        name: "structured::nil",
        description: "Return nil structured content",
        input_schema: %{"type" => "object"},
        handler: fn _arguments ->
          {:ok,
           %{
             "content" => [%{"type" => "text", "text" => "nil"}],
             "structuredContent" => nil
           }}
        end
      }
    ])
  end

  defp execute_modern(method, params, context, task_supervisor) do
    Executor.execute(ModernServer, modern_request(method, params), context,
      task_supervisor: task_supervisor,
      timeout: 1_000
    )
  end

  defp request_context(scopes \\ ["*"]) do
    resource_auth = auth(scopes)

    %{
      type: :stdio,
      auth: resource_auth,
      assigns: %{
        resource_auth: resource_auth,
        tool_scopes: scopes,
        client: %{id: "client-1", name: "Modern client"}
      }
    }
  end

  defp build_request_context(assigns, transport_auth \\ nil) do
    {:ok, profile} = Registry.profile(@version)

    {:ok, context} =
      RequestContext.build(profile, modern_request("tools/list", %{}), %{
        type: :stdio,
        auth: transport_auth,
        assigns: assigns
      })

    context
  end

  defp modern_request(method, params) do
    meta = %{
      "io.modelcontextprotocol/protocolVersion" => @version,
      "io.modelcontextprotocol/clientCapabilities" => %{},
      "io.modelcontextprotocol/clientInfo" => %{
        "name" => "modern-server-test",
        "version" => "1.0.0"
      }
    }

    %{
      "jsonrpc" => "2.0",
      "id" => System.unique_integer([:positive, :monotonic]),
      "method" => method,
      "params" => Map.put(params, "_meta", meta)
    }
  end

  defp auth(scopes) do
    %{
      kind: :open,
      client_id: nil,
      scopes: scopes,
      subject: nil,
      principal_metadata: %{}
    }
  end

  defp restricted_auth(scopes) do
    %{
      kind: :client_token,
      subject: nil,
      client_id: "client-1",
      principal_metadata: %{},
      resource: :mcp,
      scopes: scopes
    }
  end

  defp string_keyed_auth(auth) do
    Map.new(auth, fn
      {:kind, kind} -> {"kind", Atom.to_string(kind)}
      {:resource, resource} -> {"resource", Atom.to_string(resource)}
      {key, value} -> {Atom.to_string(key), value}
    end)
  end

  defp transport_context(resource_auth, assigns) do
    %{type: :stdio, auth: resource_auth, assigns: assigns}
  end
end

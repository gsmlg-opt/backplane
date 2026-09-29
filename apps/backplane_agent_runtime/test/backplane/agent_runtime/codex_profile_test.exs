defmodule Backplane.AgentRuntime.CodexProfileTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{Codex, Conversation, EphemeralStore, Error}

  alias Backplane.AgentRuntime.Codex.{
    DynamicRuntime,
    ExtensionRuntime,
    MultiAgent,
    ResourceRegistry
  }

  defmodule Provider do
    def stream(request, context) do
      send(context.test, {:provider, request, self()})

      Stream.resource(
        fn -> nil end,
        fn state ->
          receive do
            {:events, events} -> {events, state}
          end
        end,
        fn _ -> :ok end
      )
    end
  end

  defmodule SearchAdapter do
    def search(query, _opts), do: {:ok, %{results: [%{title: query}]}}
  end

  @tag :tmp_dir
  test "pinned freeform tool executes through strict Conversation dispatch", %{tmp_dir: root} do
    authority = %{
      caller: "host",
      run_id: "codex-profile",
      grants: ["apply_patch"],
      tool_revisions: %{"apply_patch" => 1}
    }

    assert {:ok, profile} =
             Codex.profile(:pinned_local, %{workspace: root}, authority, tools: ["apply_patch"])

    assert [%{type: "custom", name: "apply_patch", format: %{"syntax" => "lark"}}] =
             profile.tools

    assert profile.registry.tools["apply_patch"].backend_context == %{
             family: :local,
             context: %{workspace: root}
           }

    refute inspect(profile.tools) =~ root

    {:ok, store} = EphemeralStore.new(1)

    {:ok, conversation} =
      Conversation.start_link(
        run_id: "codex-profile",
        store: EphemeralStore,
        context: store,
        provider: Provider,
        provider_context: %{test: self()},
        subscriber: self(),
        registry: profile.registry,
        tools: profile.tools,
        authority: profile.authority,
        schema_admission: :strict,
        work: 10,
        run_timeout: 5_000
      )

    assert {:ok, _} = Conversation.prompt(conversation, "patch")
    assert_receive {:provider, %{tools: [%{type: "custom", name: "apply_patch"}]}, provider}

    patch = "*** Begin Patch\n*** Add File: result.txt\n+from conversation\n*** End Patch\n"

    send(provider, {
      :events,
      [
        %{
          type: :tool_call_completed,
          tool_call: %{id: "patch-1", name: "apply_patch", arguments: patch}
        },
        %{type: :response_completed, message: %{role: :assistant, content: "patching"}}
      ]
    })

    assert_receive {:agent_runtime, "codex-profile", %{type: :tool_completed}}, 5_000
    assert File.read!(Path.join(root, "result.txt")) == "from conversation\n"
    assert_receive {:provider, %{tools: [%{type: "custom"}]}, final_provider}

    send(final_provider, {
      :events,
      [%{type: :response_completed, message: %{role: :assistant, content: "done"}}]
    })

    assert_receive {:agent_runtime, "codex-profile", %{type: :run_completed}}
  end

  test "profiles require exact host authority and exclude unavailable families" do
    context = %{workspace: "/tmp"}

    assert {:error, %Error{class: :forbidden}} =
             Codex.profile(
               :pinned_local,
               context,
               %{caller: "host", run_id: "run", grants: []},
               tools: ["apply_patch"]
             )

    assert {:error, %Error{class: :unsupported_capability}} =
             Codex.profile(
               :pinned_local,
               context,
               %{
                 caller: "host",
                 run_id: "run",
                 grants: ["new_context"],
                 tool_revision: 1
               },
               tools: ["new_context"]
             )

    assert {:error, %Error{class: :unsupported_capability}} =
             Codex.profile(
               :service_compat,
               %{},
               %{caller: "host", run_id: "run", grants: []}
             )
  end

  test "service tools use descriptor host context and reject model-selected backends" do
    authority = %{
      caller: "host",
      run_id: "service-profile",
      grants: ["web::search"],
      tool_revisions: %{"web::search" => 1}
    }

    assert {:ok, profile} =
             Codex.profile(:service_compat, %{search_adapter: SearchAdapter}, authority,
               tools: ["web::search"]
             )

    {:ok, store} = EphemeralStore.new(1)

    {:ok, conversation} =
      Conversation.start_link(
        run_id: "service-profile",
        store: EphemeralStore,
        context: store,
        provider: Provider,
        provider_context: %{test: self()},
        subscriber: self(),
        registry: profile.registry,
        tools: profile.tools,
        authority: profile.authority,
        schema_admission: :strict,
        work: 10,
        run_timeout: 5_000
      )

    assert {:ok, _} = Conversation.prompt(conversation, "search")
    assert_receive {:provider, _, provider}

    send(provider, {
      :events,
      [
        %{
          type: :tool_call_completed,
          tool_call: %{
            id: "search-1",
            name: "web::search",
            arguments: %{"query" => "pinned", "backend" => "model-selected"}
          }
        },
        %{type: :response_completed, message: %{role: :assistant, content: "searching"}}
      ]
    })

    assert_receive {:provider, %{messages: messages}, final_provider}
    assert %{is_error: true, error: error} = List.last(messages).result
    assert inspect(error) =~ "validation"

    send(final_provider, {
      :events,
      [
        %{
          type: :tool_call_completed,
          tool_call: %{
            id: "search-2",
            name: "web::search",
            arguments: %{"query" => "pinned"}
          }
        },
        %{type: :response_completed, message: %{role: :assistant, content: "retrying"}}
      ]
    })

    assert_receive {:agent_runtime, "service-profile", %{type: :tool_completed}}
    assert_receive {:provider, %{messages: messages}, done_provider}
    assert %{is_error: false, results: [%{title: "pinned"}]} = List.last(messages).result

    send(done_provider, {
      :events,
      [%{type: :response_completed, message: %{role: :assistant, content: "done"}}]
    })

    assert_receive {:agent_runtime, "service-profile", %{type: :run_completed}}
  end

  test "configured profile combines selected CT-04 through CT-09 families" do
    resource_registry = start_supervised!(ResourceRegistry)

    collaboration_runtime =
      start_supervised!(
        {MultiAgent,
         parent_run_id: "configured-run",
         parent_name: "/root",
         parent_authority: %{caller: "host", run_id: "configured-run", grants: []},
         child_options: fn _, _, _ -> {:error, :unused} end}
      )

    scope = %{host_id: "h", caller_id: "host", run_id: "configured-run", project_id: "p"}
    extension_runtime = start_supervised!({ExtensionRuntime, scope: scope})

    dynamic_runtime =
      start_supervised!(
        {DynamicRuntime,
         candidates: [
           %{
             namespace: "mcp",
             name: "echo",
             description: "echo",
             backend: SearchAdapter,
             schema: %{"type" => "object", "properties" => %{}},
             safety: %{read_only: true, retry_safe: true, parallel_safe: true}
           }
         ]}
      )

    context = %{
      root?: true,
      collaboration_runtime: collaboration_runtime,
      extension_runtime: extension_runtime,
      dynamic_runtime: dynamic_runtime,
      resource_registry: resource_registry,
      search_adapter: SearchAdapter
    }

    tools = [
      "request_user_input",
      "list_agents",
      "get_goal",
      "tool_search",
      "exec",
      "web::search"
    ]

    authority = %{
      caller: "host",
      run_id: "configured-run",
      grants: tools,
      tool_revisions: Map.new(tools, &{&1, 1})
    }

    assert {:ok, profile} =
             Codex.profile(:configured, context, authority,
               families: [
                 :interactive,
                 :collaboration_v2,
                 :extensions,
                 :dynamic,
                 :code_mode,
                 :services
               ],
               tools: tools
             )

    assert MapSet.new(profile.registry.tools, fn {name, _} -> name end) == MapSet.new(tools)
    assert MapSet.new(profile.tools, & &1.name) == MapSet.new(tools)
  end
end

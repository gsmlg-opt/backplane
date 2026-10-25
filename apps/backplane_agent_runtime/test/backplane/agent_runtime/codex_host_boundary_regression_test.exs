defmodule Backplane.AgentRuntime.CodexHostBoundaryRegressionTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{Conversation, EphemeralStore}
  alias Backplane.AgentRuntime.Codex.{ApplyPatch, Catalog, DynamicRuntime, Tools}

  @moduletag :tmp_dir

  defmodule Provider do
    def stream(request, context) do
      send(context.test, {:boundary_provider, request, self()})

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

  defmodule Backend do
    def execute(%{tool_name: "host_publish"} = operation) do
      send(operation.backend_context.test, {:host_publisher, operation, self()})

      receive do
        {:publish, update} ->
          receipt = operation.backend_context.stage_catalog.(update)
          send(operation.backend_context.test, {:host_published, receipt})
          {:ok, %{text: "host catalog staged"}}
      end
    end

    def execute(%{tool_name: "outer"} = operation) do
      result =
        operation.backend_context.nested_dispatch.(%{
          tool_name: "tool_search",
          arguments: %{"query" => "echo"}
        })

      send(operation.backend_context.test, {:nested_discovery, result})
      {:ok, %{is_error: true, text: "outer discarded"}}
    end

    def execute(operation) do
      send(operation.backend_context.test, {:boundary_effect, operation})
      {:ok, %{text: "echo"}}
    end
  end

  defmodule PatchPolicy do
    def prepare_tool(%{tool_name: "apply_patch", arguments: patch}, context) do
      {:ok, preflight} = ApplyPatch.preflight(context.workspace, patch)
      send(context.test, {:host_preflight, preflight})

      if Enum.any?(preflight.operations, &(Path.basename(&1.path) == "forbidden.txt")),
        do: {:deny, "host denies forbidden.txt"},
        else: :allow
    end
  end

  test "discarded nested discovery remains discoverable and later committed" do
    candidate = contract("echo", "mcp")
    runtime = start_supervised!({DynamicRuntime, candidates: [candidate]})
    contracts = [contract("outer", nil) | DynamicRuntime.contracts(%{dynamic_runtime: runtime})]
    {:ok, profile} = Catalog.admit(contracts, authority("nested", ["outer", "tool_search"]))
    {conversation, _store} = conversation("nested", profile)
    assert {:ok, _} = Conversation.prompt(conversation, "discover inside failed outer")
    assert_receive {:boundary_provider, _, provider}, 1_000
    send(provider, {:events, [call("outer", %{}), done()]})

    assert_receive {:nested_discovery,
                    {:ok, %{tools: [%{name: "mcp::echo"}], publication: %{status: :staged}}}},
                   2_000

    assert_receive {:boundary_provider, %{catalog_revision: 1}, provider}, 2_000
    assert Conversation.status(conversation).pending_catalog_publication == nil

    send(provider, {:events, [call("tool_search", %{"query" => "echo"}), done()]})

    assert_receive {:boundary_provider, %{catalog_revision: 2, messages: messages, tools: tools},
                    provider},
                   2_000

    assert %{is_error: false, tools: [%{name: "mcp::echo"}]} = List.last(messages).result
    assert Enum.any?(tools, &(&1.name == "mcp::echo"))

    send(provider, {:events, [call("mcp::echo", %{}), done()]})
    assert_receive {:boundary_effect, %{tool_name: "mcp::echo", catalog_revision: 2}}, 2_000
    assert_receive {:boundary_provider, _, provider}, 2_000
    send(provider, {:events, [done()]})
    assert_receive {:agent_runtime, "nested", %{type: :run_completed}}, 1_000
  end

  test "host prepare preflights all patch actions and denies before any intent or filesystem effect",
       %{tmp_dir: root} do
    contracts = Tools.contracts(%{workspace: root}) |> Enum.filter(&(&1.name == "apply_patch"))
    {:ok, profile} = Catalog.admit(contracts, authority("patch-policy", ["apply_patch"]))

    {conversation, store} =
      conversation("patch-policy", profile,
        hooks: PatchPolicy,
        provider_context: %{workspace: root, test: self()}
      )

    patch =
      "*** Begin Patch\n*** Add File: allowed.txt\n+safe\n*** Add File: forbidden.txt\n+denied\n*** End Patch\n"

    assert {:ok, _} = Conversation.prompt(conversation, "apply two files")
    assert_receive {:boundary_provider, _, provider}, 1_000
    send(provider, {:events, [call("apply_patch", patch), done()]})

    assert_receive {:host_preflight, %{operations: [first, second]}}, 1_000
    assert first.path == Path.join(root, "allowed.txt")
    assert second.path == Path.join(root, "forbidden.txt")
    assert_receive {:boundary_provider, %{messages: messages}, provider}, 1_000
    assert List.last(messages).result.is_error
    assert File.ls!(root) == []
    assert {:ok, record} = EphemeralStore.load(store, "patch-policy")
    refute Enum.any?(record.run.execution_intents, fn {_id, intent} -> intent.type == :tool end)
    send(provider, {:events, [done()]})
    assert_receive {:agent_runtime, "patch-policy", %{type: :run_completed}}, 1_000
  end

  test "intervening committed host publication preserves dynamic discovery bookkeeping" do
    runtime = start_supervised!({DynamicRuntime, candidates: [contract("echo", "mcp")]})

    contracts = [
      contract("host_publish", nil) | DynamicRuntime.contracts(%{dynamic_runtime: runtime})
    ]

    {:ok, profile} =
      Catalog.admit(contracts, authority("intervening", ["host_publish", "tool_search"]))

    {conversation, _store} = conversation("intervening", profile)
    assert {:ok, _} = Conversation.prompt(conversation, "publish and retain echo")
    assert_receive {:boundary_provider, _, provider}, 1_000
    send(provider, {:events, [call("tool_search", %{"query" => "echo"}), done()]})
    assert_receive {:boundary_provider, %{catalog_revision: 2}, provider}, 2_000

    send(provider, {:events, [call("host_publish", %{}), done()]})
    assert_receive {:host_publisher, operation, publisher}, 1_000
    current = operation.backend_context.catalog_snapshot

    update = %{
      run_id: "intervening",
      incarnation: 1,
      expected_revision: 2,
      publication_id: "intervening-host-publication",
      catalog: Map.take(current, [:registry, :authority, :tools]) |> Map.put(:revision, 3)
    }

    send(publisher, {:publish, update})
    assert_receive {:host_published, {:ok, %{status: :staged}}}, 1_000
    assert_receive {:boundary_provider, %{catalog_revision: 3}, provider}, 2_000
    send(provider, {:events, [call("tool_search", %{"query" => "echo"}), done()]})

    assert_receive {:boundary_provider, %{catalog_revision: 3, messages: messages}, provider},
                   2_000

    assert %{is_error: false, tools: [], publication: %{status: :no_matches}} =
             List.last(messages).result

    send(provider, {:events, [call("mcp::echo", %{}), done()]})
    assert_receive {:boundary_effect, %{tool_name: "mcp::echo", catalog_revision: 3}}, 2_000
    assert_receive {:boundary_provider, _, provider}, 2_000
    send(provider, {:events, [done()]})
    assert_receive {:agent_runtime, "intervening", %{type: :run_completed}}, 1_000
  end

  defp conversation(run, profile, extra \\ []) do
    {:ok, store} = EphemeralStore.new(1)

    opts =
      Keyword.merge(
        [
          run_id: run,
          incarnation: 1,
          store: EphemeralStore,
          context: store,
          provider: Provider,
          provider_context: %{test: self()},
          subscriber: self(),
          registry: profile.registry,
          tools: profile.tools,
          authority: profile.authority,
          work: 20,
          run_timeout: 10_000
        ],
        extra
      )

    {start_supervised!({Conversation, opts}, id: make_ref()), store}
  end

  defp contract(name, namespace) do
    %{
      name: name,
      namespace: namespace,
      description: "echo nested discovery",
      backend: Backend,
      backend_context: %{test: self()},
      schema: %{"type" => "object", "properties" => %{}},
      safety: %{read_only: true, retry_safe: true, parallel_safe: false}
    }
  end

  defp authority(run, grants),
    do: %{caller: "host", run_id: run, grants: grants, tool_revision: 1}

  defp call(name, arguments),
    do: %{
      type: :tool_call_completed,
      tool_call: %{
        id: name <> Integer.to_string(System.unique_integer([:positive])),
        name: name,
        arguments: arguments
      }
    }

  defp done, do: %{type: :response_completed, message: %{role: :assistant, content: "done"}}
end

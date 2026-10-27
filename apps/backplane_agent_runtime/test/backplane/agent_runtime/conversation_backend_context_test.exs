defmodule Backplane.AgentRuntime.ConversationBackendContextTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{Conversation, EphemeralStore, ToolRegistry}

  @runtime_keys [
    :append_feedback,
    :catalog_snapshot,
    :emit,
    :effect_deadline,
    :interact,
    :nested_dispatch,
    :request_new_context,
    :resource_owner_pid,
    :stage_catalog
  ]

  defmodule Provider do
    def stream(request, context) do
      send(context.test, {:provider, request, context, self()})

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

  defmodule Selector do
    def tool_effect_timeout(invocation, context) do
      send(context.test, {:selected_catalog, invocation, context.catalog_snapshot})
      :default
    end
  end

  defmodule Backend do
    def execute(operation) do
      send(operation.backend_context.test, {:backend, operation, self()})

      receive do
        :finish ->
          {:ok, %{text: "read complete"}}

        :nested ->
          result =
            operation.backend_context.nested_dispatch.(%{tool_name: "read", arguments: %{}})

          send(operation.backend_context.test, {:nested_result, result})
          {:ok, %{text: "outer complete"}}
      end
    end
  end

  test "direct and nested backends receive only projected runtime fields across publication" do
    assert_context_parity(%{})
  end

  test "projection preserves descriptor-owned fields with provider and internal names" do
    assert_context_parity(%{
      provider_marker: :descriptor_marker,
      provider_emit: :descriptor_emit,
      producer_invocation: :descriptor_producer,
      publication_boundary: :descriptor_boundary
    })
  end

  defp assert_context_parity(extra) do
    domain = Map.merge(%{test: self(), credential: "descriptor credential"}, extra)
    initial = registry(domain, 1)
    revised = registry(domain, 2)
    authority = %{caller: "host", run_id: "context", grants: ["read", "outer"], tool_revision: 1}
    {:ok, store} = EphemeralStore.new(1)

    pid =
      start_supervised!(
        {Conversation,
         run_id: "context",
         store: EphemeralStore,
         context: store,
         provider: Provider,
         hooks: Selector,
         provider_context: %{
           test: self(),
           credential: "provider credential",
           provider_marker: :provider_marker,
           catalog_snapshot: :spoofed
         },
         registry: initial,
         authority: authority,
         subscriber: self(),
         run_timeout: 10_000}
      )

    assert {:ok, _} = Conversation.prompt(pid, "read directly and through an outer tool")
    assert_receive {:provider, %{catalog_revision: 1}, context, provider}, 1_000

    send(
      provider,
      {:events,
       [call("direct-1", "read"), call("outer-1", "outer"), call("old-batch", "read"), done()]}
    )

    assert_receive {:backend, direct, direct_worker}, 1_000
    assert_backend(direct, pid, domain, context.catalog_snapshot)
    assert direct.enclosing_invocation_id == direct.invocation_id
    send(direct_worker, :finish)
    assert_receive {:backend, outer, outer_worker}, 1_000
    send(outer_worker, :nested)
    assert_receive {:backend, nested, nested_worker}, 1_000
    assert_backend(nested, pid, domain, context.catalog_snapshot)
    assert nested.enclosing_invocation_id == outer.invocation_id
    assert nested.invocation_id != outer.invocation_id

    assert :ok = nested.backend_context.emit.(%{type: :tool_update, text: "nested read"})

    assert {:ok, feedback} =
             nested.backend_context.append_feedback.(%{
               id: "nested-feedback",
               text: "read context",
               source: "context-test",
               stage: "PostToolUse"
             })

    assert feedback.correlation.invocation_id == nested.invocation_id
    assert feedback.correlation.enclosing_invocation_id == outer.invocation_id

    update = %{
      publication_id: "context-2",
      run_id: "context",
      incarnation: 1,
      expected_revision: 1,
      catalog: %{
        revision: 2,
        registry: revised,
        authority: %{authority | tool_revision: 2},
        tools:
          Enum.map(["read", "outer"], fn name ->
            descriptor = revised.tools[name]
            %{name: name, description: descriptor.description, parameters: descriptor.schema}
          end)
      }
    }

    assert {:ok, %{status: :staged}} = nested.backend_context.stage_catalog.(update)
    send(nested_worker, :finish)
    assert_receive {:nested_result, {:ok, %{text: "read complete"}}}, 1_000
    assert_receive {:backend, old_batch, old_worker}, 1_000
    assert old_batch.tool_call_id == "old-batch"
    assert_backend(old_batch, pid, domain, context.catalog_snapshot)
    send(old_worker, :finish)

    assert_receive {:provider, %{catalog_revision: 2} = request, next_context, next}, 1_000
    assert next_context.catalog_snapshot.revision == 2
    assert Enum.any?(request.messages, &(&1[:role] == :tool and &1[:tool_call_id] == "outer-1"))
    assert nested.backend_context.catalog_snapshot.revision == 1
    send(next, {:events, [call("direct-2", "read"), call("outer-2", "outer"), done()]})
    assert_receive {:backend, direct, direct_worker}, 1_000
    assert_backend(direct, pid, domain, next_context.catalog_snapshot)
    send(direct_worker, :finish)
    assert_receive {:backend, outer, outer_worker}, 1_000
    send(outer_worker, :nested)
    assert_receive {:backend, nested, nested_worker}, 1_000
    assert_backend(nested, pid, domain, next_context.catalog_snapshot)
    assert nested.enclosing_invocation_id == outer.invocation_id
    send(nested_worker, :finish)
    assert_receive {:nested_result, {:ok, %{text: "read complete"}}}, 1_000
    assert_receive {:provider, _, _, final_provider}, 1_000
    send(final_provider, {:events, [done()]})
    assert_receive {:agent_runtime, "context", %{type: :run_completed}}, 1_000
    assert {:ok, %{run: run}} = EphemeralStore.load(store, "context")
    assert run.active_tools == %{}
    assert Enum.all?(run.tool_results, fn {_, result} -> result.is_error == false end)
  end

  defp assert_backend(operation, owner, domain, catalog) do
    context = operation.backend_context
    invocation_id = operation.invocation_id

    assert_receive {:selected_catalog, %{invocation_id: ^invocation_id} = selected, ^catalog},
                   1_000

    assert selected.invocation_id == operation.invocation_id
    assert selected.arguments == operation.arguments
    assert Map.take(context, Map.keys(domain)) == domain
    assert Enum.sort(Map.keys(context)) == Enum.sort(Enum.uniq(Map.keys(domain) ++ @runtime_keys))
    assert context.resource_owner_pid == owner
    assert context.catalog_snapshot == catalog
    assert operation.catalog_revision == catalog.revision

    for key <- @runtime_keys -- [:catalog_snapshot, :resource_owner_pid] do
      assert is_function(context[key])
    end
  end

  defp registry(context, revision) do
    Enum.reduce(["read", "outer"], %ToolRegistry{}, fn name, registry ->
      {:ok, registry} =
        ToolRegistry.register(registry, %{
          tool_name: name,
          tool_revision: revision,
          description: "#{name} context probe",
          backend: Backend,
          backend_context: context,
          schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => false},
          safety: %{read_only: true, retry_safe: true, parallel_safe: false}
        })

      registry
    end)
  end

  defp call(id, name),
    do: %{type: :tool_call_completed, tool_call: %{id: id, name: name, arguments: %{}}}

  defp done,
    do: %{type: :response_completed, message: %{role: :assistant, content: "complete"}}
end

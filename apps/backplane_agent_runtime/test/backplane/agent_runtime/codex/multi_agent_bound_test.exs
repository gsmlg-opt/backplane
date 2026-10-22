defmodule Backplane.AgentRuntime.Codex.MultiAgentBoundTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{
    Budget,
    EphemeralStore,
    Error,
    Execution,
    Policy,
    ToolEffects,
    ToolRegistry
  }

  alias Backplane.AgentRuntime.Codex.{Catalog, Contract, MultiAgent}

  @actions [:spawn, :message, :followup, :list, :wait, :interrupt]
  @binding %{run_id: "root", run_incarnation: 1, owner_id: "host-session", incarnation: 1}

  defmodule Provider do
    def stream(request, context) do
      send(context.test, {:provider, request.run_id, request, self()})

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

  defmodule Adapter do
    def execute(operation) do
      send(operation.backend_context.test, {:bound_operation, operation})
      MultiAgent.call_bound(operation, operation.arguments["request"])
    end
  end

  defmodule OtherAdapter do
    defdelegate execute(operation), to: Adapter
  end

  defmodule FailedStore do
    defdelegate mode(), to: EphemeralStore
    defdelegate capabilities(), to: EphemeralStore
    def store(_, _, _), do: {:error, Error.new(:resource_conflict, "commit failed")}
  end

  defmodule FailedCleanupStore do
    defdelegate mode(), to: EphemeralStore
    defdelegate capabilities(), to: EphemeralStore

    def store(context, run, meta) do
      if elem(meta.command, 0) == :cleanup_settled,
        do: {:error, Error.new(:execution_failure, "cleanup acknowledgement lost")},
        else: EphemeralStore.store(context, run, meta)
    end
  end

  test "host-named actions share birth, mailbox, wait, followup and targeted interruption" do
    context = runtime()
    original = operation(context, :spawn, spawn_arguments("worker"))
    assert {:ok, %{task_name: "/root/worker"}} = call(original)
    assert_receive {:child_preparation, _, first_run, parent}, 1_000
    assert parent.child.triggering_invocation.tool_name == original.tool_name
    assert parent.child.triggering_invocation.arguments_digest == digest(original.arguments)
    assert_receive {:receipt, %{status: :created, triggering_invocation: trigger}}, 1_000
    assert trigger.collaboration_binding == original.collaboration_binding
    assert_receive {:provider, ^first_run, _, provider}, 1_000

    assert {:ok, %{agents: [%{agent_name: "/root/worker", agent_status: :running}]}} =
             call(operation(context, :list, %{}))

    assert {:ok, %{accepted: true}} =
             call(
               operation(context, :message, %{"target" => "/root/worker", "message" => "queued"})
             )

    assert Process.alive?(provider)
    assert {:ok, %{timed_out: true}} = call(operation(context, :wait, %{"timeout_ms" => 0}))
    complete(context, "/root/worker", provider)
    assert {:ok, %{timed_out: false}} = call(operation(context, :wait, %{"timeout_ms" => 0}))
    {:ok, before_followup} = MultiAgent.snapshot(context.runtime)

    assert {:ok, %{accepted: true}} =
             call(
               operation(context, :followup, %{"target" => "/root/worker", "message" => "again"})
             )

    assert_receive {:provider, next_run, request, _provider}, 1_000
    refute next_run == first_run
    assert Enum.any?(request.messages, &(&1[:content] == "done"))
    assert Enum.any?(request.messages, &(&1[:content] == "again"))
    {:ok, after_followup} = MultiAgent.snapshot(context.runtime)
    assert hd(before_followup.agents).agent_id == hd(after_followup.agents).agent_id
    assert hd(after_followup.agents).incarnation == 2

    assert {:ok, %{status: :interrupted}} =
             call(operation(context, :interrupt, %{"target" => "/root/worker"}))

    assert :ok = MultiAgent.close_session(context.runtime)
  end

  test "actual descriptor changes cannot reuse an old binding grant" do
    context = runtime()
    descriptor = Contract.descriptor(context.contracts.spawn)
    invocation = operation(context, :spawn, spawn_arguments("worker"))
    assert {:ok, _} = Policy.authorize_tool(context.authority, descriptor, invocation)

    stripped = Map.delete(descriptor, :collaboration_binding)

    assert {:error, %Error{class: :forbidden}} =
             Policy.authorize_tool(context.authority, stripped, invocation)

    for changed <- [
          put_in(descriptor.schema["description"], "different schema"),
          put_in(descriptor.collaboration_binding.action, :list),
          %{descriptor | tool_name: "host::renamed"},
          %{descriptor | tool_revision: 2},
          %{descriptor | backend: OtherAdapter},
          put_in(descriptor.safety.read_only, true)
        ] do
      authority = %{
        context.authority
        | grants: [changed.tool_name],
          tool_revisions: %{changed.tool_name => changed.tool_revision}
      }

      invocation = %{
        invocation
        | tool_name: changed.tool_name,
          tool_revision: changed.tool_revision
      }

      assert {:error, %Error{class: :forbidden}} =
               Policy.authorize_tool(authority, changed, invocation)

      assert {:error, %Error{class: :forbidden}} =
               Catalog.admit([contract_from_descriptor(changed)], authority)
    end

    assert {:ok, revised} =
             MultiAgent.bind_contract(context.runtime, :list, %{
               context.contracts.spawn
               | tool_revision: 2
             })

    refute revised.collaboration_binding.fingerprint ==
             context.contracts.spawn.collaboration_binding.fingerprint

    authority = authority([revised])
    assert {:ok, _} = Catalog.admit([revised], authority)

    assert {:ok, _} =
             Catalog.admit([context.contracts.spawn], authority([context.contracts.spawn]))
  end

  test "bound direct calls require exact authority, run incarnation and session owner" do
    context = runtime()
    original = operation(context, :spawn, spawn_arguments("worker"))
    {:ok, before} = MultiAgent.snapshot(context.runtime)

    for invalid <- [
          Map.delete(original, :effective_authority),
          put_in(original.effective_authority.grants, []),
          put_in(original.effective_authority.tool_bindings, %{}),
          put_in(original.effective_authority.run_id, "other-run"),
          put_in(original.effective_authority.caller, "other-caller"),
          original
          |> Map.put(:caller, "other-caller")
          |> put_in([:effective_authority, :caller], "other-caller"),
          Map.put(original, :caller, "other-caller"),
          %{original | incarnation: 2},
          %{original | run_id: "other-run"},
          %{original | tool_name: "host::other"},
          %{original | tool_revision: 2},
          put_in(original.collaboration_binding.action, :list),
          put_in(original.backend_context.resource_owner.owner_id, "wrong-owner"),
          update_in(original.backend_context, &Map.delete(&1, :resource_owner))
        ] do
      assert {:rejected, proof} = call(invalid)
      assert {:ok, %{is_error: true}} = ToolEffects.validate_rejection(proof, invalid)
    end

    assert {:rejected, _} =
             MultiAgent.call(update_in(original.backend_context, &Map.put(&1, :profile, :v2)))

    assert {:ok, ^before} = MultiAgent.snapshot(context.runtime)
    refute_receive {:child_preparation, _, _, _}, 20

    revoked = %{context.authority | grants: []}
    assert :ok = MultiAgent.rebind_parent(context.runtime, @binding, revoked)
    assert {:rejected, _} = call(original)
    refute_receive {:provider, _, _, _}, 20

    assert :ok = MultiAgent.detach_parent(context.runtime, @binding)
    assert {:rejected, _} = call(original)
  end

  test "capacity refusal retains original identity and never reserves converted arguments" do
    context = runtime(max_concurrent_threads_per_session: 1)
    original = operation(context, :spawn, spawn_arguments("external"))
    {:ok, before} = MultiAgent.snapshot(context.runtime)
    assert {:rejected, proof} = MultiAgent.call_bound(original, spawn_arguments("converted"))

    assert {:ok, %{error: %Error{class: :resource_conflict}}} =
             ToolEffects.validate_rejection(proof, original)

    for changed <- [
          %{original | arguments: %{"request" => spawn_arguments("converted")}},
          %{original | tool_name: "spawn_agent"},
          put_in(original.collaboration_binding.action, :list)
        ] do
      assert {:error, %Error{class: :unknown_outcome}} =
               ToolEffects.validate_rejection(proof, changed)
    end

    assert {:ok, ^before} = MultiAgent.snapshot(context.runtime)
    refute_receive {:child_preparation, _, _, _}, 20
    refute_receive {:receipt, _}, 20
    refute_receive {:provider, _, _, _}, 20
  end

  test "a host contract using a native name cannot remove its binding to use native dispatch" do
    context = runtime()

    attrs =
      MultiAgent.contracts(:v2, context.runtime)
      |> Enum.find(&(&1.name == "spawn_agent"))
      |> Map.merge(%{
        backend: Adapter,
        backend_context: context.contracts.spawn.backend_context
      })

    assert {:ok, contract} = MultiAgent.bind_contract(context.runtime, :spawn, attrs)
    authority = authority([contract])
    assert :ok = MultiAgent.rebind_parent(context.runtime, @binding, authority)
    context = %{context | authority: authority, contracts: %{spawn: contract}}

    original =
      operation(context, :spawn, spawn_arguments("worker"))
      |> Map.put(:arguments, spawn_arguments("worker"))

    downgraded =
      original
      |> Map.delete(:collaboration_binding)
      |> put_in([:backend_context, :profile], :v2)

    {:ok, before} = MultiAgent.snapshot(context.runtime)

    for invalid <- [downgraded, Map.delete(downgraded, :effective_authority)] do
      assert {:rejected, proof} = MultiAgent.call(invalid)

      assert {:ok, %{error: %Error{class: :forbidden}}} =
               ToolEffects.validate_rejection(proof, invalid)
    end

    assert {:ok, ^before} = MultiAgent.snapshot(context.runtime)
    refute_receive {:child_preparation, _, _, _}, 20
    refute_receive {:provider, _, _, _}, 20
  end

  test "a custom binding cannot be renamed into an ungranted native action" do
    context = runtime()

    renamed =
      operation(context, :spawn, spawn_arguments("worker"))
      |> Map.delete(:collaboration_binding)
      |> Map.put(:tool_name, "spawn_agent")
      |> Map.put(:arguments, spawn_arguments("worker"))
      |> put_in([:backend_context, :profile], :v2)

    {:ok, before} = MultiAgent.snapshot(context.runtime)

    for invalid <- [renamed, Map.delete(renamed, :effective_authority)] do
      assert {:rejected, proof} = MultiAgent.call(invalid)

      assert {:ok, %{error: %Error{class: :forbidden}}} =
               ToolEffects.validate_rejection(proof, invalid)
    end

    assert {:ok, ^before} = MultiAgent.snapshot(context.runtime)
    refute_receive {:child_preparation, _, _, _}, 20

    authority =
      context.authority
      |> Map.update!(:grants, &["spawn_agent" | &1])
      |> put_in([:tool_revisions, "spawn_agent"], 1)

    assert :ok = MultiAgent.rebind_parent(context.runtime, @binding, authority)

    assert {:ok, %{task_name: "/root/worker"}} =
             MultiAgent.call(%{renamed | effective_authority: authority})

    assert_receive {:provider, _, _, _}, 1_000
  end

  test "admission failure after reservation remains uncertain for the original trigger" do
    context = runtime(preparation_error: true)
    original = operation(context, :spawn, spawn_arguments("worker"))
    assert {:error, %Error{class: :execution_failure}} = result = call(original)
    assert ToolEffects.settlement(result, %{read_only: false}) == :uncertain
    assert_receive {:receipt, %{status: :rejected, triggering_invocation: trigger}}, 1_000
    assert trigger.invocation_id == original.invocation_id
    assert trigger.arguments_digest == digest(original.arguments)
    refute_receive {:provider, _, _, _}, 20
  end

  test "failed created receipt prevents provider effects and does not prove pre-effect refusal" do
    context = runtime(receipt_error: true)

    assert {:error, %Error{}} =
             result = call(operation(context, :spawn, spawn_arguments("worker")))

    assert ToolEffects.settlement(result, %{read_only: false}) == :uncertain
    assert_receive {:receipt, %{status: :created}}, 1_000
    refute_receive {:provider, _, _, _}, 20
  end

  test "nested calls inherit bindings and target interruption leaves descendants alive" do
    context = runtime()
    assert {:ok, _} = call(operation(context, :spawn, spawn_arguments("parent")))
    assert_receive {:provider, parent_run, _, parent_provider}, 1_000

    send(
      parent_provider,
      {:events,
       [
         %{
           type: :tool_call_completed,
           tool_call: %{
             id: "nested",
             name: context.contracts.spawn.tool_name,
             arguments: %{"request" => spawn_arguments("child")}
           }
         },
         %{type: :response_completed, message: %{role: :assistant, content: "delegating"}}
       ]}
    )

    assert_receive {:bound_operation, %{run_id: ^parent_run, collaboration_binding: binding}},
                   1_000

    assert binding == context.contracts.spawn.collaboration_binding
    assert_receive {:provider, ^parent_run, _, _}, 1_000
    assert_receive {:provider, child_run, _, child_provider}, 1_000
    refute child_run == parent_run
    assert eventually(fn -> Enum.any?(agents(context), &(&1.name == "/root/parent/child")) end)
    assert {:ok, _} = call(operation(context, :interrupt, %{"target" => "/root/parent"}))
    assert Process.alive?(child_provider)
    assert :ok = MultiAgent.close_session(context.runtime)
    refute Process.alive?(child_provider)
  end

  test "cleanup uncertainty reserves the same slot and prevents spawn or followup replay" do
    context = runtime(max_concurrent_threads_per_session: 2, child_store: FailedCleanupStore)
    assert {:ok, _} = call(operation(context, :spawn, spawn_arguments("worker")))
    assert_receive {:provider, _, _, _}, 1_000

    assert {:error, %Error{class: :unknown_outcome}} =
             call(operation(context, :interrupt, %{"target" => "/root/worker"}))

    assert {:rejected, _} = call(operation(context, :spawn, spawn_arguments("blocked")))

    assert {:error, %Error{class: :unknown_outcome}} =
             call(
               operation(context, :followup, %{"target" => "/root/worker", "message" => "again"})
             )

    refute_receive {:provider, _, _, _}, 20
  end

  test "a surviving descendant respects its replaced parent's current narrower authority" do
    context = runtime()
    assert {:ok, _} = call(operation(context, :spawn, spawn_arguments("parent")))
    assert_receive {:provider, parent_run, _, parent_provider}, 1_000

    nested = as_child(operation(context, :spawn, spawn_arguments("child")), parent_run)
    assert {:ok, %{task_name: "/root/parent/child"}} = call(nested)
    assert_receive {:provider, child_run, _, _}, 1_000
    complete(context, "/root/parent", parent_provider)

    contracts = context.contracts |> Map.delete(:message) |> Map.values()
    {:ok, narrowed} = Catalog.admit(contracts, authority(contracts))
    :ets.insert(context.table, {:bundle, narrowed})

    assert {:ok, %{accepted: true}} =
             call(
               operation(context, :followup, %{
                 "target" => "/root/parent",
                 "message" => "new policy"
               })
             )

    assert_receive {:provider, new_parent_run, _, _}, 1_000
    refute new_parent_run == parent_run

    stale_parent = as_child(operation(context, :spawn, spawn_arguments("stale")), parent_run)
    assert {:rejected, _} = call(stale_parent)

    message =
      as_child(
        operation(context, :message, %{"target" => "/root/parent", "message" => "denied"}),
        child_run
      )

    assert {:rejected, proof} = call(message)

    assert {:ok, %{error: %Error{class: :forbidden}}} =
             ToolEffects.validate_rejection(proof, message)

    assert {:ok, _} = call(as_child(operation(context, :list, %{}), child_run))
  end

  test "delegation excludes ordinary tools revoked upstream while bound spawn remains authorized" do
    context = runtime(include_ordinary: true)
    assert {:ok, _} = call(operation(context, :spawn, spawn_arguments("parent")))
    assert_receive {:provider, parent_run, _, _}, 1_000
    assert_receive {:child_preparation, _, ^parent_run, _}, 1_000

    ordinary = context.contracts.ordinary.tool_name
    narrowed = %{context.authority | grants: List.delete(context.authority.grants, ordinary)}
    assert :ok = MultiAgent.rebind_parent(context.runtime, @binding, narrowed)

    nested = as_child(operation(context, :spawn, spawn_arguments("forbidden_child")), parent_run)
    assert {:error, %Error{class: :forbidden}} = result = call(nested)
    assert ToolEffects.settlement(result, %{read_only: false}) == :uncertain
    assert_receive {:child_preparation, _, _, parent}, 1_000
    refute ordinary in parent.authority.grants
    refute_receive {:provider, _, _, _}, 20
  end

  test "delegation excludes ordinary tools whose upstream revision changed" do
    context = runtime(include_ordinary: true)
    assert {:ok, _} = call(operation(context, :spawn, spawn_arguments("parent")))
    assert_receive {:provider, parent_run, _, _}, 1_000
    assert_receive {:child_preparation, _, ^parent_run, _}, 1_000

    ordinary = context.contracts.ordinary.tool_name
    revised = put_in(context.authority, [:tool_revisions, ordinary], 2)
    assert :ok = MultiAgent.rebind_parent(context.runtime, @binding, revised)

    nested = as_child(operation(context, :spawn, spawn_arguments("outdated_child")), parent_run)
    assert {:error, %Error{class: :forbidden}} = result = call(nested)
    assert ToolEffects.settlement(result, %{read_only: false}) == :uncertain
    assert_receive {:child_preparation, _, _, parent}, 1_000
    refute ordinary in parent.authority.grants
    refute_receive {:provider, _, _, _}, 20
  end

  test "catalog narrowing retains only admitted binding grants" do
    context = runtime()
    contract = context.contracts.list
    authority = authority([contract]) |> put_in([:tool_bindings, "unused"], "unused-fingerprint")
    assert {:ok, bundle} = Catalog.admit([contract], authority)

    assert bundle.authority.tool_bindings == %{
             contract.tool_name => contract.collaboration_binding.fingerprint
           }
  end

  test "an old bound approval cannot authorize a new unbound descriptor of the same name and revision" do
    context = runtime()
    contract = context.contracts.list
    original = operation(context, :list, %{})

    descriptor =
      contract
      |> Contract.descriptor()
      |> Map.delete(:collaboration_binding)
      |> put_in([:safety, :requires_approval], true)

    {:ok, registry} = ToolRegistry.register(%ToolRegistry{}, descriptor)
    {:ok, store} = EphemeralStore.new(1)
    {:ok, budget} = Budget.new(%{root_run_id: "root", work: 2})
    authority = %{context.authority | tool_bindings: %{}}

    approval = %{
      approval_id: "approval",
      run_id: "root",
      tool_name: contract.tool_name,
      tool_revision: 1,
      arguments_digest:
        :crypto.hash(:sha256, :erlang.term_to_binary(original.arguments))
        |> Base.encode16(case: :lower),
      collaboration_binding: contract.collaboration_binding,
      current_time: 10,
      expires_at: 20
    }

    decision =
      approval
      |> Map.take([
        :approval_id,
        :tool_name,
        :tool_revision,
        :arguments_digest,
        :collaboration_binding
      ])
      |> Map.merge(%{decision: :approved, resolver_id: "human"})

    assert {:error, %Error{class: :forbidden}} =
             Execution.run(
               EphemeralStore,
               store,
               record(),
               %{command: {:tool_invoked, 11, original}},
               registry: registry,
               authority: authority,
               budget: budget,
               approval: approval,
               approval_decision: decision
             )

    refute_receive {:bound_operation, _}, 20
  end

  test "store-first execution journals the original binding and commit failure prevents dispatch" do
    context = runtime()
    original = operation(context, :list, %{})
    {:ok, store} = EphemeralStore.new(1)
    {:ok, budget} = Budget.new(%{root_run_id: "root", work: 2})
    opts = [registry: context.bundle.registry, authority: context.authority, budget: budget]

    assert {:error, %Error{class: :resource_conflict}} =
             Execution.run(
               FailedStore,
               nil,
               record(),
               %{command: {:tool_invoked, 11, original}},
               opts
             )

    refute_receive {:bound_operation, _}, 20

    assert {:ok, committed, result} =
             Execution.run(
               EphemeralStore,
               store,
               record(),
               %{command: {:tool_invoked, 11, original}},
               opts
             )

    assert_receive {:bound_operation, dispatched}, 1_000
    assert dispatched.tool_name == original.tool_name
    assert dispatched.arguments == original.arguments
    assert dispatched.collaboration_binding == original.collaboration_binding
    assert dispatched.effective_authority.tool_bindings == context.authority.tool_bindings
    assert result.operation.collaboration_binding == original.collaboration_binding
    assert hd(committed.outbox).operation.collaboration_binding == original.collaboration_binding
    assert result.effects == [%{agents: []}]
  end

  defp runtime(options \\ []) do
    test = self()
    table = :ets.new(:bound_catalog, [:set, :public])

    runtime =
      start_supervised!(
        {MultiAgent,
         parent_run_id: "root",
         parent_name: "/root",
         parent_authority: %{caller: "host", run_id: "root", grants: []},
         min_wait_timeout_ms: 0,
         max_concurrent_threads_per_session:
           Keyword.get(options, :max_concurrent_threads_per_session, 4),
         admission_receipt: fn receipt ->
           send(test, {:receipt, receipt})

           if Keyword.get(options, :receipt_error),
             do: {:error, Error.new(:execution_failure, "receipt store failed")},
             else: :ok
         end,
         child_options: fn request, run_id, parent ->
           send(test, {:child_preparation, request, run_id, parent})

           if Keyword.get(options, :preparation_error) do
             {:error, Error.new(:execution_failure, "admission store failed")}
           else
             [{:bundle, bundle}] = :ets.lookup(table, :bundle)
             {:ok, store} = EphemeralStore.new(1)

             {:ok,
              [
                run_id: run_id,
                incarnation: parent.child.incarnation,
                store: Keyword.get(options, :child_store, EphemeralStore),
                context: store,
                provider: Provider,
                provider_context: %{test: test},
                registry: bundle.registry,
                tools: bundle.tools,
                authority: Map.put(bundle.authority, :run_id, run_id),
                schema_admission: :strict,
                work: 30,
                run_timeout: :infinity
              ]}
           end
         end}
      )

    contracts =
      Map.new(@actions, fn action ->
        {:ok, contract} =
          MultiAgent.bind_contract(runtime, action, %{
            namespace: "host",
            name: "sessions_#{action}",
            tool_revision: 1,
            backend: Adapter,
            backend_context: %{
              test: test,
              resource_owner: Map.take(@binding, [:owner_id, :incarnation])
            },
            schema: %{
              "type" => "object",
              "properties" => %{"request" => %{"type" => "object"}},
              "required" => ["request"],
              "additionalProperties" => false
            },
            safety: %{
              read_only: action in [:list, :wait],
              retry_safe: false,
              parallel_safe: false
            }
          })

        {action, contract}
      end)

    contracts =
      if Keyword.get(options, :include_ordinary) do
        {:ok, ordinary} =
          Contract.new(%{
            name: "ordinary",
            tool_revision: 1,
            backend: Adapter,
            schema: %{"type" => "object"},
            safety: %{read_only: false, retry_safe: false, parallel_safe: false}
          })

        Map.put(contracts, :ordinary, ordinary)
      else
        contracts
      end

    authority = authority(Map.values(contracts))
    {:ok, bundle} = Catalog.admit(Map.values(contracts), authority)
    :ets.insert(table, {:bundle, bundle})
    :ok = MultiAgent.rebind_parent(runtime, @binding, authority)
    %{runtime: runtime, contracts: contracts, authority: authority, bundle: bundle, table: table}
  end

  defp authority(contracts),
    do: %{
      caller: "host",
      run_id: "root",
      grants: Enum.map(contracts, & &1.tool_name),
      tool_revisions: Map.new(contracts, &{&1.tool_name, &1.tool_revision}),
      tool_bindings:
        contracts
        |> Enum.filter(&Map.has_key?(&1, :collaboration_binding))
        |> Map.new(&{&1.tool_name, &1.collaboration_binding.fingerprint})
    }

  defp operation(context, action, arguments) do
    contract = context.contracts[action]

    %{
      run_id: "root",
      incarnation: 1,
      step_id: "step",
      attempt_id: "attempt",
      invocation_id: "invocation",
      tool_call_id: "call",
      turn_id: "turn",
      catalog_revision: 1,
      tool_name: contract.tool_name,
      tool_revision: contract.tool_revision,
      collaboration_binding: contract.collaboration_binding,
      arguments: %{"request" => arguments},
      backend_context: contract.backend_context,
      effective_authority: context.authority,
      caller: "host"
    }
  end

  defp call(operation), do: MultiAgent.call_bound(operation, operation.arguments["request"])

  defp as_child(operation, run_id),
    do: %{
      operation
      | run_id: run_id,
        effective_authority: Map.put(operation.effective_authority, :run_id, run_id)
    }

  defp spawn_arguments(name), do: %{"task_name" => name, "message" => name}

  defp digest(arguments),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary(arguments, [:deterministic]))
      |> Base.encode16(case: :lower)

  defp agents(context) do
    {:ok, snapshot} = MultiAgent.snapshot(context.runtime)
    snapshot.agents
  end

  defp complete(context, name, provider) do
    send(
      provider,
      {:events, [%{type: :response_completed, message: %{role: :assistant, content: "done"}}]}
    )

    assert eventually(fn ->
             Enum.any?(agents(context), &(&1.name == name and &1.status == :completed))
           end)
  end

  defp eventually(check, remaining \\ 100)
  defp eventually(_check, 0), do: false

  defp eventually(check, remaining) do
    if check.(),
      do: true,
      else:
        (
          Process.sleep(5)
          eventually(check, remaining - 1)
        )
  end

  defp contract_from_descriptor(descriptor) do
    {:ok, {namespace, name}} = Contract.split_name(descriptor.tool_name)

    %{
      namespace: namespace,
      name: name,
      tool_revision: descriptor.tool_revision,
      schema: descriptor.schema,
      backend: descriptor.backend,
      safety: descriptor.safety,
      collaboration_binding: descriptor.collaboration_binding
    }
  end

  defp record,
    do: %{
      run_id: "root",
      incarnation: 1,
      expected_revision: 0,
      state: :running,
      admitted: true,
      current_step: %{step_id: "step", attempt_id: "attempt"},
      deadline: nil,
      outcome: nil,
      context: %{},
      children: []
    }
end

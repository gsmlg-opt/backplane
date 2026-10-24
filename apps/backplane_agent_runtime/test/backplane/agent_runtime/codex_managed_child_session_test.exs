defmodule Backplane.AgentRuntime.CodexManagedChildSessionTest do
  use ExUnit.Case, async: false
  alias Backplane.AgentRuntime.{Conversation, EphemeralStore, Plan, Error, Command, ToolEffects}

  alias Backplane.AgentRuntime.Codex.{
    Session,
    MultiAgent,
    Catalog,
    Contract,
    Tools,
    ResourceRegistry,
    CodeMode
  }

  @moduletag :tmp_dir
  @moduletag capture_log: true

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

  defmodule InteractionHook do
    def prepare_tool(_invocation, context) do
      context.interact.(%{prompt: "approve managed child work"})
      :allow
    end
  end

  defmodule BoundAdapter do
    def execute(operation) do
      send(operation.backend_context.test, {:bound_operation, operation})
      MultiAgent.call_bound(operation, operation.arguments)
    end
  end

  defmodule FailedPromptStore do
    defdelegate mode(), to: EphemeralStore
    defdelegate capabilities(), to: EphemeralStore

    def store(_, _, _),
      do: {:error, Error.new(:unknown_outcome, "prompt persistence acknowledgement lost")}
  end

  defmodule FinishBarrierStore do
    defdelegate mode(), to: EphemeralStore
    defdelegate capabilities(), to: EphemeralStore

    def store(context, run, meta) do
      if elem(meta.command, 0) == :finish do
        send(context.test, {:finish_barrier, self()})

        receive do
          :lose -> {:error, Error.new(:unknown_outcome, "finish acknowledgement lost")}
        end
      else
        EphemeralStore.store(context.table, run, meta)
      end
    end
  end

  test "public managed children keep native collaboration and independent retained plans" do
    ctx = runtime()
    %{root: root, child: child, provider: provider} = ctx

    {provider, result} =
      tool(provider, "root", "spawn_agent", %{"task_name" => "worker", "message" => "work"})

    assert result.task_name == "/root/worker"
    assert_receive {:child_binding, first}
    assert_receive {:provider, run, _, child_provider}, 1_000
    {child_provider, result} = tool(child_provider, run, "list_agents", %{})
    assert [%{agent_name: "/root/worker"}] = result.agents

    {child_provider, _} =
      tool(child_provider, run, "update_plan", %{
        "plan" => [%{"step" => "retain", "status" => "in_progress"}]
      })

    send(child_provider, {:events, [done()]})
    eventually(fn -> Session.status(child).phase == :idle end)

    {provider, result} =
      tool(provider, "root", "followup_task", %{"target" => "/root/worker", "message" => "again"})

    assert result.accepted
    assert_receive {:child_binding, second}
    assert second.session == first.session
    assert second.token != first.token
    assert second.run_incarnation == 2
    assert_receive {:provider, next_run, _, next_provider}, 1_000
    refute next_run == run
    send(next_provider, {:events, [done()]})
    eventually(fn -> Session.status(child).phase == :idle end)
    send(provider, {:events, [done()]})
    eventually(fn -> Session.status(root).phase == :idle end)
    assert {:ok, %{status: :confirmed}} = Session.close(root)
    assert Session.status(child).phase == :closed
    assert {:ok, %{content: %{"plan" => [%{"step" => "retain"}]}}} = Plan.read(ctx.child_plan)
    assert {:ok, %{content: %{}}} = Plan.read(ctx.root_plan)
  end

  test "adoption validates identity, semantic authority, and stable association without crashing" do
    session =
      start_supervised!(Supervisor.child_spec({Session, owner_pid: self()}, id: :adoption))

    auth = %{authority("one", ["a", "b"]) | tool_revision: 2}
    {:ok, binding} = Session.bind(session, auth)

    admission = %{
      manager: self(),
      manager_id: "manager",
      agent_id: "agent",
      attempt_id: "attempt",
      run_id: "one",
      incarnation: 1
    }

    for {bad_binding, bad_admission, bad_authority} <- [
          {nil, admission, auth},
          {binding, nil, auth},
          {binding, %{}, auth},
          {%{binding | token: make_ref()}, admission, auth},
          {binding, %{admission | run_id: "wrong"}, auth},
          {binding, %{admission | manager: session}, auth},
          {binding, admission, %{auth | grants: nil}},
          {binding, admission, %{auth | caller: ""}},
          {binding, admission, Map.put(auth, :tool_revisions, nil)},
          {binding, admission, Map.put(auth, :tool_bindings, [])},
          {binding, admission, %{auth | grants: ["extra"]}},
          {binding, admission, %{auth | tool_revision: 3}}
        ] do
      assert {:error, %Error{}} =
               Session.adopt_managed_child(bad_binding, bad_admission, bad_authority)

      assert Process.alive?(session)
    end

    reordered = Map.put(%{auth | grants: ["b", "a"]}, :tool_revisions, %{"a" => 2, "b" => 2})
    assert :ok = Session.adopt_managed_child(binding, admission, reordered)
    assert :ok = Session.adopt_managed_child(binding, admission, reordered)

    assert {:error, %Error{}} =
             Session.adopt_managed_child(binding, %{admission | attempt_id: "foreign"}, reordered)

    {:ok, catalog} = Catalog.admit([], %{auth | grants: []})
    assert :ok = Session.attach(binding, catalog)
    assert :ok = Session.prepare_detach(binding)
    assert {:ok, %{status: :retained}} = Session.detach(binding)
    {:ok, next} = Session.bind(session, %{auth | run_id: "two"}, incarnation: 2)

    assert {:error, %Error{}} =
             Session.adopt_managed_child(
               next,
               %{admission | run_id: "two", incarnation: 2, agent_id: "other"},
               %{auth | run_id: "two"}
             )

    assert {:ok, %{status: :confirmed}} = Session.close(session)
  end

  test "root Session cannot be adopted and rejected foreign allocations stay host-owned" do
    ctx = runtime()
    # Return the root's real active binding as a child allocation. Adoption must
    # refuse it without closing the root's registry or manager.
    :ets.insert(ctx.table, {{:binding_override, "/root/worker"}, ctx.binding})

    assert {:error, %Error{}} =
             call(ctx, "spawn_agent", %{"task_name" => "worker", "message" => "work"})

    provider = ctx.provider
    assert Session.status(ctx.root).phase == :active
    refute :sys.get_state(ctx.manager).session_closed
    {_, result} = tool(provider, "root", "list_agents", %{})
    refute result[:is_error]
    assert {:ok, %{status: :confirmed}} = Session.close(ctx.root)
  end

  test "child mailbox and nested spawn survive target-only interrupt" do
    ctx = runtime()

    {root_provider, _} =
      tool(ctx.provider, "root", "spawn_agent", %{"task_name" => "worker", "message" => "work"})

    assert_receive {:child_binding, first}
    assert_receive {:provider, run, _, provider}, 1_000

    {provider, result} =
      tool(provider, run, "send_message", %{"target" => "/root", "message" => "from child"})

    assert result.accepted

    {provider, result} =
      tool(provider, run, "spawn_agent", %{"task_name" => "nested", "message" => "independent"})

    assert result.task_name == "/root/worker/nested"
    assert_receive {:child_binding, nested}
    assert_receive {:provider, nested_run, _, nested_provider}, 1_000

    {root_provider, result} =
      tool(root_provider, "root", "interrupt_agent", %{"target" => "/root/worker"})

    assert result.status == :interrupted
    assert Session.status(first.session).phase == :closed
    assert Session.status(nested.session).phase == :active
    assert Process.alive?(nested_provider)
    {nested_provider, result} = tool(nested_provider, nested_run, "list_agents", %{})
    refute result[:is_error]
    assert Process.alive?(root_provider)
    refute Process.alive?(provider)
    send(nested_provider, {:events, [done()]})
    eventually(fn -> Session.status(nested.session).phase == :idle end)
    assert {:ok, %{status: :confirmed}} = Session.close(ctx.root)
    assert Session.status(nested.session).phase == :closed
  end

  test "monitor from run A fences Session infrastructure loss during run B; stale notifications do not" do
    ctx = runtime()

    {root_provider, _} =
      tool(ctx.provider, "root", "spawn_agent", %{"task_name" => "worker", "message" => "work"})

    assert_receive {:child_binding, first}
    assert_receive {:provider, _, _, provider}, 1_000
    old = :sys.get_state(ctx.manager).child_sessions |> Map.values() |> hd()
    send(provider, {:events, [done()]})
    eventually(fn -> Session.status(ctx.child).phase == :idle end)

    {_, _} =
      tool(root_provider, "root", "followup_task", %{
        "target" => "/root/worker",
        "message" => "again"
      })

    assert_receive {:child_binding, current}
    assert_receive {:provider, current_run, _, current_provider}, 1_000

    send(
      ctx.manager,
      {:managed_child_session_closed, Map.take(old, [:admission, :binding, :authority]),
       {:ok, %{status: :confirmed}}}
    )

    assert {:ok, _} = MultiAgent.snapshot(ctx.manager)
    assert hd(Map.values(:sys.get_state(ctx.manager).child_sessions)).binding == current

    assert {:error, %Error{class: :forbidden}} =
             Session.validate(first, %{run_id: first.run_id, incarnation: 1})

    # The monitor is deliberately the one installed in A, not a fresh run monitor.
    assert hd(Map.values(:sys.get_state(ctx.manager).child_sessions)).monitor == old.monitor
    GenServer.stop(ctx.child, :normal)
    eventually(fn -> :sys.get_state(ctx.manager).agents["/root/worker"].execution_reserved end)
    assert eventually(fn -> not Process.alive?(current_provider) end)
    agent = :sys.get_state(ctx.manager).agents["/root/worker"]
    assert agent.run_id == current_run
    assert match?({:uncertain, _}, agent.closure)
  end

  test "manager loss locally closes idle adopted Sessions" do
    ctx = runtime()

    {_, _} =
      tool(ctx.provider, "root", "spawn_agent", %{"task_name" => "worker", "message" => "work"})

    assert_receive {:provider, _, _, provider}, 1_000
    send(provider, {:events, [done()]})
    eventually(fn -> Session.status(ctx.child).phase == :idle end)
    GenServer.stop(ctx.manager, :normal)
    eventually(fn -> Session.status(ctx.child).phase == :closed end)
    assert {:ok, %{status: :confirmed}} = Session.close(ctx.child)
  end

  test "recursive close independently checks every idle child Session receipt" do
    ctx = runtime()

    {root_provider, _} =
      tool(ctx.provider, "root", "spawn_agent", %{"task_name" => "worker", "message" => "work"})

    assert_receive {:child_binding, first}
    assert_receive {:provider, _, _, provider}, 1_000
    send(provider, {:events, [done()]})
    eventually(fn -> Session.status(first.session).phase == :idle end)

    {_, _} =
      tool(root_provider, "root", "spawn_agent", %{"task_name" => "sibling", "message" => "work"})

    assert_receive {:child_binding, sibling}
    assert_receive {:provider, _, _, sibling_provider}, 1_000
    send(sibling_provider, {:events, [done()]})
    eventually(fn -> Session.status(sibling.session).phase == :idle end)

    {:ok, _} =
      ResourceRegistry.register(first.resource_registry, first.owner_id, :logical, :uncertain,
        owner_pid: first.session,
        cleanup: fn ->
          {:error, Error.new(:unknown_outcome, "injected child cleanup uncertainty")}
        end
      )

    assert {:error, %Error{class: :unknown_outcome}} = Session.close(ctx.root)
    assert Session.status(first.session).phase == :closed
    assert Session.status(sibling.session).phase == :closed
    assert {:ok, %{status: :confirmed}} = Session.close(sibling.session)
    assert :sys.get_state(ctx.manager).agents["/root/worker"].execution_reserved
  end

  test "exact managed binding and live ancestor authority fence forged and revoked native calls" do
    ctx = runtime()
    assert {:ok, _} = call(ctx, "spawn_agent", %{"task_name" => "worker", "message" => "work"})
    assert_receive {:child_binding, binding}
    assert_receive {:provider, _, _, _}, 1_000
    {:ok, owner} = Session.validate(binding, %{run_id: binding.run_id, incarnation: 1})
    child = %{ctx | binding: binding}
    assert {:ok, _} = call(child, "list_agents", %{})

    for forged <- [
          Map.delete(owner, :session_binding),
          %{owner | owner_pid: self()},
          %{owner | session_binding: %{binding | token: make_ref()}}
        ] do
      assert {:error, %Error{class: :forbidden}} = call(child, "list_agents", %{}, forged)
    end

    narrowed =
      authority("root", [
        "spawn_agent",
        "list_agents",
        "followup_task",
        "interrupt_agent",
        "update_plan"
      ])

    assert :ok = MultiAgent.rebind_parent(ctx.manager, ctx.binding, narrowed)

    assert {:error, %Error{class: :forbidden}} =
             call(child, "send_message", %{"target" => "/root", "message" => "revoked"})

    assert {:ok, _} = call(child, "list_agents", %{})
    assert {:ok, %{status: :confirmed}} = Session.close(ctx.root)
  end

  test "adopted native child cannot replace its Session capability with its Conversation PID" do
    ctx = runtime()
    assert {:ok, _} = call(ctx, "spawn_agent", %{"task_name" => "worker", "message" => "work"})
    assert_receive {:child_binding, binding}
    assert_receive {:provider, _, _, _}, 1_000
    agent = :sys.get_state(ctx.manager).agents["/root/worker"]

    operation = %{
      tool_name: "list_agents",
      tool_revision: 1,
      run_id: agent.run_id,
      incarnation: agent.incarnation,
      caller: agent.authority.caller,
      effective_authority: agent.authority,
      arguments: %{},
      backend_context: %{runtime: ctx.manager, profile: :v2, resource_owner_pid: agent.pid}
    }

    assert {:error, %Error{class: :forbidden}} = MultiAgent.call(operation)

    assert {:ok, _} =
             MultiAgent.call(put_in(operation.backend_context[:session_binding], binding))

    assert {:ok, _} = call(%{ctx | binding: binding}, "list_agents", %{})
    assert {:ok, %{status: :confirmed}} = Session.close(ctx.root)
  end

  test "host-bound collaboration executes under the adopted child's exact Session capability" do
    ctx = runtime(bound_contract: true)

    {_, _} =
      tool(ctx.provider, "root", "spawn_agent", %{"task_name" => "worker", "message" => "work"})

    assert_receive {:child_binding, binding}
    assert_receive {:provider, run, _, provider}, 1_000
    {provider, result} = tool(provider, run, "host::child_list", %{})
    assert [%{agent_name: "/root/worker"}] = result.agents
    assert_receive {:bound_operation, operation}
    assert operation.backend_context.session_binding == binding
    agent = :sys.get_state(ctx.manager).agents["/root/worker"]

    omitted =
      update_in(operation.backend_context, fn backend ->
        backend
        |> Map.drop([:session_binding, :resource_owner])
        |> Map.put(:resource_owner_pid, agent.pid)
      end)

    forged = put_in(operation.backend_context.session_binding.token, make_ref())

    for invalid <- [omitted, forged] do
      assert {:rejected, proof} = MultiAgent.call_bound(invalid, %{})

      assert {:ok, %{error: %Error{class: :forbidden}}} =
               ToolEffects.validate_rejection(proof, invalid)
    end

    assert {:ok, _} = MultiAgent.call_bound(operation, %{})
    assert Process.alive?(provider)
    assert {:ok, %{status: :confirmed}} = Session.close(ctx.root)
  end

  test "sessionless children retain native and host-bound Conversation ownership" do
    ctx =
      runtime(
        bound_contract: true,
        child_transform: fn opts ->
          opts
          |> Keyword.delete(:session_binding)
          |> Keyword.update!(:registry, fn registry ->
            %{
              registry
              | tools:
                  Map.new(registry.tools, fn {name, descriptor} ->
                    {name,
                     update_in(descriptor.backend_context, &Map.delete(&1, :session_binding))}
                  end)
            }
          end)
        end
      )

    {_, _} =
      tool(ctx.provider, "root", "spawn_agent", %{"task_name" => "worker", "message" => "work"})

    assert_receive {:provider, run, _, provider}, 1_000
    {provider, native} = tool(provider, run, "list_agents", %{})
    assert [%{agent_name: "/root/worker"}] = native.agents
    {_, bound} = tool(provider, run, "host::child_list", %{})
    assert [%{agent_name: "/root/worker"}] = bound.agents
    assert_receive {:bound_operation, operation}
    refute Map.has_key?(operation.backend_context, :session_binding)
    refute Map.has_key?(operation.backend_context, :resource_owner)
    assert is_pid(operation.backend_context.resource_owner_pid)
    assert :sys.get_state(ctx.manager).child_sessions == %{}
    assert {:ok, %{status: :confirmed}} = Session.close(ctx.root)
  end

  test "V1 recursive close reaches retained idle child and grandchild Session resources" do
    ctx = runtime(v1_contracts: true)
    test = self()

    {root_provider, _} =
      tool(ctx.provider, "root", "spawn_agent", %{"task_name" => "worker", "message" => "work"})

    assert_receive {:child_binding, child}
    assert_receive {:provider, run, _, provider}, 1_000

    {provider, _} =
      tool(provider, run, "spawn_agent", %{"task_name" => "nested", "message" => "nested"})

    assert_receive {:child_binding, nested}
    assert_receive {:provider, _, _, nested_provider}, 1_000

    for {name, binding} <- [child: child, grandchild: nested] do
      assert {:ok, _} =
               ResourceRegistry.register(
                 binding.resource_registry,
                 binding.owner_id,
                 :logical,
                 name,
                 owner_pid: binding.session,
                 cleanup: fn ->
                   send(test, {:closed_resource, name})
                   :ok
                 end
               )
    end

    send(provider, {:events, [done()]})
    send(nested_provider, {:events, [done()]})
    eventually(fn -> Session.status(child.session).phase == :idle end)
    eventually(fn -> Session.status(nested.session).phase == :idle end)
    refute_receive {:closed_resource, _}, 20

    {root_provider, result} =
      tool(root_provider, "root", "multi_agent_v1::close_agent", %{"target" => run})

    assert result.status == :shutdown
    assert_receive {:closed_resource, :child}
    assert_receive {:closed_resource, :grandchild}
    assert Session.status(child.session).phase == :closed
    assert Session.status(nested.session).phase == :closed
    assert Session.status(ctx.root).phase == :active
    assert Process.alive?(root_provider)
    assert {:ok, %{status: :confirmed}} = Session.close(ctx.root)
  end

  test "replacement Session is refused until retained ownership has confirmed closure" do
    ctx = runtime()
    assert {:ok, _} = call(ctx, "spawn_agent", %{"task_name" => "worker", "message" => "work"})
    assert_receive {:provider, _, _, provider}, 1_000
    send(provider, {:events, [done()]})
    eventually(fn -> Session.status(ctx.child).phase == :idle end)
    replacement = ctx.sessions["/replacement"]
    :ets.insert(ctx.table, {{:session_override, "/root/worker"}, replacement})

    assert {:error, %Error{class: :resource_conflict}} =
             call(ctx, "followup_task", %{"target" => "/root/worker", "message" => "refused"})

    assert Session.status(ctx.child).phase == :idle
    assert hd(Map.values(:sys.get_state(ctx.manager).child_sessions)).binding.session == ctx.child
    assert {:ok, %{status: :confirmed}} = Session.close(ctx.child)
    assert {:ok, _} = MultiAgent.snapshot(ctx.manager)
    # Rejected callback allocations remain the host's responsibility.
    {replacement_session, replacement_plan} = replacement
    assert {:ok, %{status: :confirmed}} = Session.close(replacement_session)
    fresh = start_supervised!(Supervisor.child_spec({Session, owner_pid: self()}, id: :fresh))
    :ets.insert(ctx.table, {{:session_override, "/root/worker"}, {fresh, replacement_plan}})

    assert {:ok, %{accepted: true}} =
             call(ctx, "followup_task", %{"target" => "/root/worker", "message" => "accepted"})

    assert_receive {:provider, _, _, _}, 1_000
    assert Session.status(fresh).phase == :active
    assert {:ok, %{status: :confirmed}} = Session.close(ctx.root)
  end

  test "untagged and mismatched run notifications cannot settle the managed activation" do
    ctx = runtime()
    assert {:ok, _} = call(ctx, "spawn_agent", %{"task_name" => "worker", "message" => "work"})
    assert_receive {:child_binding, binding}
    assert_receive {:provider, run, _, provider}, 1_000
    child = hd(Map.values(:sys.get_state(ctx.manager).child_sessions))
    identity = Map.take(child, [:admission, :binding])
    event = %{type: :run_completed, run_id: run, incarnation: binding.run_incarnation}
    send(ctx.manager, {:agent_runtime, run, event})

    for forged <- [
          put_in(identity.admission.attempt_id, "old"),
          put_in(identity.binding.token, make_ref()),
          put_in(identity.admission.manager_id, "other")
        ] do
      send(ctx.manager, {:managed_child_runtime, forged, run, event})
    end

    assert {:ok, %{agents: [%{status: :running, cleanup: :pending}]}} =
             MultiAgent.snapshot(ctx.manager)

    send(provider, {:events, [done()]})
    eventually(fn -> Session.status(ctx.child).phase == :idle end)
    eventually(fn -> :sys.get_state(ctx.manager).agents["/root/worker"].status == :completed end)
    assert {:ok, %{status: :confirmed}} = Session.close(ctx.root)
  end

  test "lost created acknowledgement closes adopted resources but retains the execution obligation" do
    ctx =
      runtime(
        admission_receipt: fn
          %{status: :created} ->
            {:error, Error.new(:unknown_outcome, "receipt acknowledgement lost")}

          _ ->
            :ok
        end
      )

    assert {:error, %Error{}} =
             call(ctx, "spawn_agent", %{"task_name" => "worker", "message" => "work"})

    assert_receive {:child_binding, binding}
    eventually(fn -> Session.status(binding.session).phase == :closed end)
    agent = :sys.get_state(ctx.manager).agents["/root/worker"]
    assert agent.execution_reserved
    assert match?({:uncertain, _}, agent.closure)

    assert {:error, %Error{class: :unknown_outcome}} =
             call(ctx, "followup_task", %{"target" => "/root/worker", "message" => "no replay"})

    refute_receive {:provider, _, _, _}, 20
  end

  test "real command and yielded Code Mode resources survive a successful child follow-up",
       test_ctx do
    server = start_supervised!({Backplane.AgentRuntime.Tools.LocalCommand, name: nil})

    {:ok, command} =
      Command.new(%{
        adapter: Backplane.AgentRuntime.Tools.LocalCommand,
        server: server,
        allowed_environment: %{}
      })

    child_workspace = Path.join(test_ctx.tmp_dir, "child")
    File.mkdir_p!(child_workspace)

    ctx =
      runtime(
        context: %{workspace: test_ctx.tmp_dir, command: command},
        child_context: %{workspace: child_workspace},
        extra_tools: ["exec_command", "write_stdin", "exec", "wait"]
      )

    {root_provider, root_command} =
      tool(ctx.provider, "root", "exec_command", %{
        "cmd" => "read value; printf 'ROOT:%s' \"$value\"",
        "login" => false,
        "yield_time_ms" => 0
      })

    {root_provider, _} =
      tool(root_provider, "root", "spawn_agent", %{"task_name" => "worker", "message" => "work"})

    assert_receive {:child_binding, binding}
    assert_receive {:provider, run, _, provider}, 1_000

    {provider, child_command} =
      tool(provider, run, "exec_command", %{
        "cmd" => "read value; printf 'CHILD:%s' \"$value\"",
        "login" => false,
        "yield_time_ms" => 0
      })

    {provider, cell} =
      tool(
        provider,
        run,
        "exec",
        "// @exec: {\"yield_time_ms\":10}\nawait new Promise(resolve => setTimeout(resolve, 250)); return \"retained-cell\";"
      )

    assert cell.status == :yielded
    {:ok, resources} = ResourceRegistry.owner_status(binding.resource_registry, binding.owner_id)
    assert is_integer(child_command.session_id)
    assert length(resources) == 2
    send(provider, {:events, [done()]})
    eventually(fn -> Session.status(ctx.child).phase == :idle end)

    {root_provider, _} =
      tool(root_provider, "root", "followup_task", %{
        "target" => "/root/worker",
        "message" => "continue resources"
      })

    assert_receive {:child_binding, next}
    assert_receive {:provider, next_run, _, next_provider}, 1_000

    {next_provider, result} =
      tool(next_provider, next_run, "write_stdin", %{
        "session_id" => child_command.session_id,
        "chars" => "continued\n",
        "yield_time_ms" => 1_000
      })

    assert result.output =~ "CHILD:continued"

    {next_provider, result} =
      tool(next_provider, next_run, "wait", %{"cell_id" => cell.cell_id, "yield_time_ms" => 1_000})

    assert result.status == :completed
    assert result.value == "retained-cell"
    assert next.session == binding.session
    assert {:ok, %{status: :confirmed}} = Session.close(ctx.child)

    {_, result} =
      tool(root_provider, "root", "write_stdin", %{
        "session_id" => root_command.session_id,
        "chars" => "survived\n",
        "yield_time_ms" => 1_000
      })

    assert result.output =~ "ROOT:survived"
    refute Process.alive?(next_provider)
    assert {:ok, %{status: :confirmed}} = Session.close(ctx.root)
    assert Process.alive?(server)
  end

  test "an unknown Session close receipt cannot be replaced by an old successful Conversation snapshot" do
    ctx = runtime()
    assert {:ok, _} = call(ctx, "spawn_agent", %{"task_name" => "worker", "message" => "work"})
    assert_receive {:child_binding, first}
    assert_receive {:provider, _, _, provider}, 1_000
    send(provider, {:events, [done()]})
    eventually(fn -> Session.status(first.session).phase == :idle end)
    assert {:ok, _} = call(ctx, "spawn_agent", %{"task_name" => "sibling", "message" => "work"})
    assert_receive {:child_binding, sibling}
    assert_receive {:provider, _, _, sibling_provider}, 1_000
    send(sibling_provider, {:events, [done()]})
    eventually(fn -> Session.status(sibling.session).phase == :idle end)
    :ok = :sys.suspend(first.session)
    on_exit(fn -> if Process.alive?(first.session), do: :sys.resume(first.session) end)
    closer = Task.async(fn -> MultiAgent.close_session(ctx.manager) end)
    # Observation remains responsive while the close receipt is unavailable.
    assert {:ok, _} = MultiAgent.snapshot(ctx.manager)
    assert {:error, %Error{class: :unknown_outcome}} = Task.await(closer, 12_000)
    assert Session.status(sibling.session).phase == :closed
    assert :sys.get_state(ctx.manager).agents["/root/worker"].execution_reserved
    :ok = :sys.resume(first.session)
    eventually(fn -> Session.status(first.session).phase == :closed end)
  end

  test "an adoption acknowledgement lost before attach preserves the exact obligation" do
    ctx = runtime()
    :ets.insert(ctx.table, {:suspend_adoption, true})

    assert {:error, %Error{class: :unknown_outcome}} =
             call(ctx, "spawn_agent", %{"task_name" => "worker", "message" => "work"})

    assert_receive {:child_binding, binding}
    entry = hd(Map.values(:sys.get_state(ctx.manager).child_sessions))
    assert entry.binding == binding
    assert entry.status == :uncertain
    :ok = :sys.resume(binding.session)
    eventually(fn -> Session.status(binding.session).phase == :closed end)
    assert :sys.get_state(ctx.manager).agents["/root/worker"].execution_reserved

    assert {:error, %Error{class: :unknown_outcome}} =
             call(ctx, "followup_task", %{"target" => "/root/worker", "message" => "no replay"})

    refute_receive {:provider, _, _, _}, 20
  end

  test "accepted adoption is locally closed after failed Conversation startup or prompt admission" do
    for override <- [[work: -1], [store: FailedPromptStore]] do
      ctx = runtime(child_overrides: override, fixture: make_ref())

      assert {:error, %Error{}} =
               call(ctx, "spawn_agent", %{"task_name" => "worker", "message" => "work"})

      assert_receive {:child_binding, binding}
      eventually(fn -> Session.status(binding.session).phase == :closed end)
      assert :sys.get_state(ctx.manager).agents["/root/worker"].execution_reserved
      assert Session.status(ctx.root).phase == :active
      refute :sys.get_state(ctx.manager).session_closed
      refute_receive {:provider, _, _, _}, 20
    end
  end

  test "lost durable finish acknowledgement fences a managed child and keeps follow-up unavailable" do
    test = self()

    ctx =
      runtime(
        child_transform: fn opts ->
          Keyword.merge(opts,
            store: FinishBarrierStore,
            context: %{test: test, table: opts[:context]}
          )
        end
      )

    assert {:ok, _} = call(ctx, "spawn_agent", %{"task_name" => "worker", "message" => "work"})
    assert_receive {:child_binding, binding}
    assert_receive {:provider, _, _, provider}, 1_000
    send(provider, {:events, [done()]})
    assert_receive {:finish_barrier, store}, 1_000
    assert Session.status(binding.session).phase == :detaching

    assert {:error, %Error{}} =
             Session.bind(binding.session, authority("forbidden", []), incarnation: 2)

    assert {:ok, _} = MultiAgent.snapshot(ctx.manager)
    send(store, :lose)
    eventually(fn -> Session.status(binding.session).phase == :closed end)

    assert {:error, %Error{class: :unknown_outcome}} =
             call(ctx, "followup_task", %{"target" => "/root/worker", "message" => "no replay"})

    assert :sys.get_state(ctx.manager).agents["/root/worker"].execution_reserved
    assert Session.status(ctx.root).phase == :active
  end

  test "child host loss closes only local resources while siblings and root remain active" do
    ctx = runtime()
    assert {:ok, _} = call(ctx, "spawn_agent", %{"task_name" => "worker", "message" => "work"})
    assert_receive {:child_binding, binding}
    assert_receive {:provider, _, _, provider}, 1_000

    assert {:ok, _} =
             call(ctx, "spawn_agent", %{"task_name" => "sibling", "message" => "independent"})

    assert_receive {:child_binding, sibling}
    assert_receive {:provider, _, _, sibling_provider}, 1_000
    # The fixture gives each stable child a distinct host owner.
    host = :sys.get_state(binding.session).owner
    send(host, :stop)
    eventually(fn -> Session.status(binding.session).phase == :closed end)
    assert Session.status(sibling.session).phase == :active
    assert Session.status(ctx.root).phase == :active
    assert Process.alive?(sibling_provider)
    refute Process.alive?(provider)
    assert {:ok, %{status: :confirmed}} = Session.close(ctx.root)
  end

  test "interaction cancellation independently confirms its managed Session close" do
    ctx = runtime(child_overrides: [hooks: InteractionHook])
    {:ok, _} = MultiAgent.subscribe(ctx.manager)
    assert {:ok, _} = call(ctx, "spawn_agent", %{"task_name" => "worker", "message" => "work"})
    assert_receive {:child_binding, binding}
    assert_receive {:provider, _, _, provider}, 1_000

    send(
      provider,
      {:events,
       [
         %{
           type: :tool_call_completed,
           tool_call: %{id: "plan", name: "update_plan", arguments: %{"plan" => []}}
         },
         done()
       ]}
    )

    assert_receive {:codex_collaboration,
                    %{
                      type: :interaction_requested,
                      agent: %{pending_interaction: %{correlation: correlation}}
                    }},
                   1_000

    assert :ok = MultiAgent.cancel_interaction(ctx.manager, correlation, "cancel local child")
    assert Session.status(binding.session).phase == :closed
    entry = hd(Map.values(:sys.get_state(ctx.manager).child_sessions))
    assert entry.status == :closed
    assert {:ok, %{status: :confirmed}} = entry.close_result
    assert Session.status(ctx.root).phase == :active
    assert {:ok, %{status: :confirmed}} = Session.close(ctx.root)
  end

  test "unknown local close of a retained idle Session reserves execution capacity" do
    ctx = runtime()
    assert {:ok, _} = call(ctx, "spawn_agent", %{"task_name" => "worker", "message" => "work"})
    assert_receive {:child_binding, binding}
    assert_receive {:provider, _, _, provider}, 1_000
    send(provider, {:events, [done()]})
    eventually(fn -> Session.status(binding.session).phase == :idle end)

    eventually(fn ->
      not :sys.get_state(ctx.manager).agents["/root/worker"].execution_reserved
    end)

    {:ok, _} =
      ResourceRegistry.register(binding.resource_registry, binding.owner_id, :logical, :unknown,
        owner_pid: binding.session,
        cleanup: fn -> {:error, Error.new(:unknown_outcome, "local close unconfirmed")} end
      )

    assert {:error, %Error{class: :unknown_outcome}} = Session.close(binding.session)
    eventually(fn -> :sys.get_state(ctx.manager).agents["/root/worker"].execution_reserved end)

    assert {:error, %Error{class: :unknown_outcome}} =
             call(ctx, "followup_task", %{"target" => "/root/worker", "message" => "no replay"})
  end

  defp call(ctx, name, arguments, owner \\ nil) do
    binding = ctx.binding

    owner =
      owner ||
        elem(
          Session.validate(binding, %{
            run_id: binding.run_id,
            incarnation: binding.run_incarnation
          }),
          1
        )

    authority =
      case :sys.get_state(ctx.manager).run_index[binding.run_id] do
        nil ->
          authority(binding.run_id, [
            "spawn_agent",
            "list_agents",
            "followup_task",
            "send_message",
            "interrupt_agent",
            "update_plan"
          ])

        child_name ->
          :sys.get_state(ctx.manager).agents[child_name].authority
      end

    MultiAgent.call(%{
      tool_name: name,
      tool_revision: 1,
      run_id: binding.run_id,
      incarnation: binding.run_incarnation,
      caller: authority.caller,
      effective_authority: authority,
      arguments: arguments,
      backend_context: %{runtime: ctx.manager, profile: :v2, resource_owner: owner}
    })
  end

  defp runtime(opts \\ []) do
    test = self()
    fixture = Keyword.get(opts, :fixture, :default)

    root =
      start_supervised!(
        Supervisor.child_spec({Session, owner_pid: test, cleanup_timeout: 2_000},
          id: {:root, fixture}
        )
      )

    sessions =
      for name <- ["/root/worker", "/root/worker/nested", "/root/sibling", "/replacement"],
          into: %{} do
        host =
          spawn(fn ->
            receive do
              :stop -> :ok
            end
          end)

        on_exit(fn -> send(host, :stop) end)

        session =
          start_supervised!(
            Supervisor.child_spec({Session, owner_pid: host, cleanup_timeout: 1_000},
              id: {name, fixture}
            )
          )

        {:ok, plan} = Plan.start_link(name)
        {name, {session, plan}}
      end

    {child, child_plan} = sessions["/root/worker"]

    tools =
      [
        "spawn_agent",
        "list_agents",
        "followup_task",
        "send_message",
        "interrupt_agent",
        "update_plan"
      ] ++
        Keyword.get(opts, :extra_tools, []) ++
        if(Keyword.get(opts, :bound_contract), do: ["host::child_list"], else: []) ++
        if(Keyword.get(opts, :v1_contracts), do: ["multi_agent_v1::close_agent"], else: [])

    native_context = Keyword.get(opts, :context, %{})
    opts_config = opts
    {:ok, root_plan} = Plan.start_link(:root)
    table = :ets.new(:contracts, [:public])

    {:ok, manager} =
      MultiAgent.start_link(
        parent_run_id: "root",
        parent_name: "/root",
        admission_receipt: Keyword.get(opts, :admission_receipt),
        parent_authority: authority("root", tools),
        min_wait_timeout_ms: 0,
        child_options: fn _, run, parent ->
          {session, plan} =
            case :ets.lookup(table, {:session_override, parent.child.name}) do
              [{_, replacement}] -> replacement
              [] -> sessions[parent.child.name]
            end

          tools =
            case :ets.lookup(table, :child_tools) do
              [{_, tools}] -> tools
              [] -> parent.authority.grants
            end

          opts =
            case :ets.lookup(table, {:binding_override, parent.child.name}) do
              [{_, binding}] ->
                [run_id: run, session_binding: binding, authority: authority(run, [])]

              [] ->
                options(
                  session,
                  run,
                  parent.child.incarnation,
                  tools,
                  {:ets.lookup_element(table, :contracts, 2), plan},
                  test,
                  Map.merge(native_context, Keyword.get(opts, :child_context, %{}))
                )
            end

          opts = Keyword.merge(opts, Keyword.get(opts_config, :child_overrides, []))
          opts = Keyword.get(opts_config, :child_transform, &Function.identity/1).(opts)
          if :ets.member(table, :suspend_adoption), do: :sys.suspend(session)
          send(test, {:child_binding, opts[:session_binding]})
          {:ok, opts}
        end
      )

    on_exit(fn ->
      if Process.alive?(root), do: Session.close(root)
      if Process.alive?(manager), do: GenServer.stop(manager)
    end)

    contracts = MultiAgent.contracts(:v2, manager)

    contracts =
      if Keyword.get(opts, :v1_contracts),
        do: contracts ++ MultiAgent.contracts(:v1, manager),
        else: contracts

    contracts =
      if Keyword.get(opts, :bound_contract) do
        {:ok, bound} =
          MultiAgent.bind_contract(manager, :list, %{
            namespace: "host",
            name: "child_list",
            tool_revision: 1,
            backend: BoundAdapter,
            backend_context: %{test: test},
            schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => false},
            safety: %{read_only: true, retry_safe: false, parallel_safe: false}
          })

        contracts ++ [bound]
      else
        contracts
      end

    :ets.insert(table, {:contracts, contracts})
    opts = options(root, "root", 1, tools, {contracts, root_plan}, test, native_context)
    {:ok, pid} = Conversation.start_link(opts)
    {:ok, _} = Conversation.prompt(pid, "start")
    assert_receive {:provider, "root", _, provider}, 1_000

    %{
      root: root,
      child: child,
      manager: manager,
      pid: pid,
      provider: provider,
      table: table,
      root_plan: root_plan,
      child_plan: child_plan,
      sessions: sessions,
      binding: opts[:session_binding]
    }
  end

  defp authority(run, tools), do: %{caller: "host", run_id: run, grants: tools, tool_revision: 1}

  defp options(session, run, incarnation, tools, {contracts, plan}, test, native_context) do
    authority = authority(run, tools)

    bindings =
      Map.new(
        for contract <- contracts,
            Map.has_key?(contract, :collaboration_binding),
            contract.tool_name in tools,
            do: {contract.tool_name, contract.collaboration_binding.fingerprint}
      )

    authority =
      if map_size(bindings) > 0, do: Map.put(authority, :tool_bindings, bindings), else: authority

    {:ok, binding} = Session.bind(session, authority, incarnation: incarnation)

    context =
      Map.merge(native_context, %{
        plan: plan,
        resource_registry: binding.resource_registry,
        session_registry: binding.resource_registry,
        session_binding: binding,
        caller: %{run_id: run}
      })

    local = Tools.contracts(context) ++ CodeMode.contracts(context)

    selected =
      Enum.filter(
        local ++ contracts,
        &(Contract.canonical_name(&1[:namespace], &1.name) in tools)
      )

    {:ok, profile} = Catalog.admit(selected, authority)

    registry = %{
      profile.registry
      | tools:
          Map.new(profile.registry.tools, fn {name, descriptor} ->
            {name, put_in(descriptor.backend_context[:session_binding], binding)}
          end)
    }

    {:ok, table} = EphemeralStore.new(1)

    [
      run_id: run,
      incarnation: incarnation,
      session_binding: binding,
      registry: registry,
      tools: profile.tools,
      authority: profile.authority,
      store: EphemeralStore,
      context: table,
      provider: Provider,
      provider_context: %{test: test},
      work: 30,
      run_timeout: 15_000,
      cleanup_timeout: 2_000
    ]
  end

  defp tool(provider, run, name, arguments) do
    send(
      provider,
      {:events,
       [
         %{
           type: :tool_call_completed,
           tool_call: %{
             id: name <> Integer.to_string(System.unique_integer([:positive])),
             name: name,
             arguments: arguments
           }
         },
         done()
       ]}
    )

    assert_receive {:provider, ^run, request, next}, 7_000
    message = request.messages |> Enum.reverse() |> Enum.find(&(&1[:role] == :tool))
    {next, message.result}
  end

  defp done, do: %{type: :response_completed, message: %{role: :assistant, content: "done"}}
  defp eventually(fun, tries \\ 300)
  defp eventually(_, 0), do: flunk("lifecycle did not settle")

  defp eventually(fun, tries) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          eventually(fun, tries - 1)
        )
  end
end

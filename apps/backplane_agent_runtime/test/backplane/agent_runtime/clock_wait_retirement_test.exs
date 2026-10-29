Code.require_file("../../fixtures/reconciliation_host.exs", __DIR__)

defmodule Backplane.AgentRuntime.ClockWaitRetirementTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Codex, Conversation, EphemeralStore, Error, ToolEffects}

  alias Backplane.AgentRuntime.Codex.{
    Backend,
    MultiAgent,
    Reconciliation,
    ResourceRegistry,
    Session,
    Tools
  }

  alias Backplane.AgentRuntime.Codex.Reconciliation.Evidence
  alias Backplane.AgentRuntime.ReconciliationHostFixture, as: Host

  @moduletag capture_log: true
  @names ~w(clock::sleep clock::curr_time exec wait)
  @collaboration ~w(spawn_agent interrupt_agent list_agents)

  defmodule Provider do
    def stream(request, %{test: test}) do
      send(test, {:clock_provider, request.run_id, request, self()})

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

  defmodule ProbeBackend do
    def execute(operation) do
      original = operation.backend_context.register_cancellation
      test = operation.backend_context.test

      gate = Map.get(operation.backend_context, :startup_gate, :after_ack)

      if operation.tool_name == "clock::sleep" and gate == :before_backend do
        send(test, {:clock_startup_pending, operation, self()})
        receive do: (:continue_clock_startup -> :ok)
      end

      register = fn admitted, registration ->
        if gate == :before_ack do
          send(test, {:clock_registration_pending, admitted, registration, self()})
          send(test, {:clock_registration_callback, admitted.invocation_id, original})
          receive do: (:continue_clock_registration -> :ok)
        end

        result = original.(admitted, registration)

        if match?({:ok, _}, result) do
          send(test, {:clock_registered, admitted, registration, self()})

          if gate == :before_backend do
            repeated = original.(admitted, registration)
            send(test, {:clock_registration_repeated, admitted, registration, repeated})
          end
        end

        result
      end

      operation = put_in(operation.backend_context.register_cancellation, register)
      result = Backend.execute(operation)
      send(test, {:clock_returned, operation.invocation_id, result})
      result
    end
  end

  defmodule UnrelatedBackend do
    def execute(operation) do
      send(operation.backend_context.test, {:unrelated_clock_started, operation, self()})
      receive do: (:never_finish_unrelated_work -> {:ok, %{effect: "unrelated"}})
    end
  end

  defmodule AckStore do
    defdelegate mode(), to: EphemeralStore
    defdelegate capabilities(), to: EphemeralStore

    def store(context, run, meta) do
      kind = elem(meta.command, 0)

      if kind in [:tool_invoked, :tool_completed] do
        send(context.test, {:clock_ack_pending, kind, self()})

        receive do
          :ack -> :ok
        end
      end

      EphemeralStore.store(context.table, run, meta)
    end
  end

  defmodule MissingEvidenceStore do
    defdelegate mode(), to: EphemeralStore
    defdelegate capabilities(), to: EphemeralStore

    def load(table, run_id, opts) do
      with {:ok, record} <- EphemeralStore.load(table, run_id, opts) do
        {:ok, put_in(record, [:run, :outcome, "cleanup", "evidence"], [])}
      end
    end
  end

  defmodule BadAckStore do
    defdelegate mode(), to: EphemeralStore
    defdelegate capabilities(), to: EphemeralStore

    def store(context, run, meta) do
      if elem(meta.command, 0) == context.kind do
        send(context.test, {:clock_bad_ack, context.kind, context.behavior, run.run_id})

        case context.behavior do
          :reject ->
            {:error, Error.new(:execution_failure, "fixture rejected clock commit")}

          :malformed ->
            {:ok, _} = EphemeralStore.store(context.table, run, meta)
            {:ok, %{revision: :invalid}}

          :lost ->
            {:ok, _} = EphemeralStore.store(context.table, run, meta)

            receive do
              :never_ack -> :unavailable
            end
        end
      else
        EphemeralStore.store(context.table, run, meta)
      end
    end
  end

  @tag invalid_clock_duration: true
  test "invalid clock durations keep validation errors without allocating a startup waiter" do
    for {duration, index} <- Enum.with_index([0, -1, 1.5, 43_200_001]) do
      host = Host.new()
      run = "invalid-clock-#{index}"

      context =
        start_root(host, run,
          startup_gate: :before_backend,
          store: AckStore,
          context: %{table: host.store, test: self()}
        )

      registry = context.binding.resource_registry
      assert 1 == :erlang.trace(registry, true, [:receive, {:tracer, self()}])

      try do
        provider = prompt(context, "validate the native clock duration")
        send(provider, {:events, [call("clock::sleep", %{"duration_ms" => duration}), done()]})
        assert_receive {:clock_ack_pending, :tool_invoked, intent_writer}, 1_000
        send(intent_writer, :ack)
        assert_receive {:clock_startup_pending, operation, executor}, 1_000
        refute Map.has_key?(operation.backend_context, :clock_wait_admission)

        assert {:ok, inventory} =
                 ResourceRegistry.owner_status(registry, context.binding.owner_id)

        refute Enum.any?(inventory, &(&1.kind == :resource))

        send(executor, :continue_clock_startup)
        invocation = operation.invocation_id

        assert_receive {:clock_returned, ^invocation,
                        {:error, %Error{class: :validation, message: message} = error}},
                       1_000

        assert message == "duration_ms must be between 1 and 43200000"
        eventually(fn -> Conversation.status(context.conversation).phase == :terminal end)
        status = Conversation.status(context.conversation)
        assert status.error == error
        assert status.run.state == :unknown_outcome
        assert status.run.tool_results == %{}
        assert status.retirement_evidence == []
        assert {:ok, stored} = EphemeralStore.load(host.store, run)
        assert stored.run == status.run

        assert Enum.any?(stored.run.execution_intents, fn {_key, intent} ->
                 intent.type == :tool and intent.operation.invocation_id == invocation and
                   intent.status == :uncertain
               end)

        refute_receive {:clock_registered, _, _, _}, 30
        refute_receive {:clock_ack_pending, :tool_completed, _}, 30
        refute_receive {:clock_provider, ^run, _, _}, 30
        assert 1 == :erlang.trace(registry, false, [:receive])
        delivered = :erlang.trace_delivered(registry)
        assert_receive {:trace_delivered, ^registry, ^delivered}, 1_000

        refute_receive {:trace, ^registry, :receive,
                        {:"$gen_call", _, {:start_clock_wait, _, _, _}}},
                       30
      after
        if Process.alive?(registry), do: :erlang.trace(registry, false, [:receive])
      end
    end
  end

  test "normal clock completion waits for both Store ACKs and retains elapsed result" do
    host = Host.new()

    context =
      start_root(host, "normal", store: AckStore, context: %{table: host.store, test: self()})

    provider = prompt(context, "sleep briefly")
    send(provider, {:events, [call("clock::sleep", %{"duration_ms" => 10}), done()]})
    assert_receive {:clock_ack_pending, :tool_invoked, intent_writer}, 1_000
    refute_receive {:clock_registered, _, _, _}, 30
    send(intent_writer, :ack)
    assert_receive {:clock_registered, operation, _, _}, 1_000
    assert_receive {:clock_returned, invocation, {:ok, result}}, 1_000
    assert invocation == operation.invocation_id
    assert result.wall_time_seconds >= 0.01
    assert_receive {:clock_ack_pending, :tool_completed, result_writer}, 1_000
    refute_receive {:clock_provider, "normal", _, _}, 30

    assert {:error, %Error{class: :unknown_outcome}} =
             ResourceRegistry.owner_transfer_ready(
               context.binding.resource_registry,
               context.binding.owner_id
             )

    send(result_writer, :ack)
    assert_receive {:clock_provider, "normal", request, next}, 1_000
    assert List.last(request.messages).result.wall_time_seconds == result.wall_time_seconds

    assert :ok =
             ResourceRegistry.owner_transfer_ready(
               context.binding.resource_registry,
               context.binding.owner_id
             )

    finish(context, next)
  end

  for kind <- [:tool_completed, :cleanup_settled], behavior <- [:reject, :malformed, :lost] do
    @tag ack_kind: kind, ack_behavior: behavior
    test "#{kind} #{behavior} ACK retains clock registration and blocks provider continuation",
         %{ack_kind: kind, ack_behavior: behavior} do
      host = Host.new()
      run = "ack-#{kind}-#{behavior}"

      context =
        start_root(host, run,
          store: BadAckStore,
          context: %{table: host.store, test: self(), kind: kind, behavior: behavior},
          commit_timeout: 100
        )

      provider = prompt(context, "wait for a clock commit")
      duration = if kind == :tool_completed, do: 10, else: 60_000
      send(provider, {:events, [call("clock::sleep", %{"duration_ms" => duration}), done()]})
      assert_receive {:clock_registered, operation, registration, _}, 1_000
      if kind == :cleanup_settled, do: assert(:ok == Conversation.cancel(context.conversation))
      assert_receive {:clock_bad_ack, ^kind, ^behavior, ^run}, 2_000
      eventually(fn -> Conversation.status(context.conversation).phase == :storage_failed end)
      state = :sys.get_state(context.conversation)
      assert state.cancellations[operation.invocation_id].registration == registration

      assert state.cancellations[operation.invocation_id].operation.clock_wait_admission ==
               operation.clock_wait_admission

      refute_receive {:clock_provider, ^run, _, _}, 30

      if kind == :tool_completed do
        assert_receive {:clock_returned, invocation, {:ok, %{wall_time_seconds: elapsed}}}, 1_000
        assert invocation == operation.invocation_id
        assert elapsed >= 0.01
      end
    end
  end

  test "clock name and local family do not grant unrelated backend retirement authority" do
    host = Host.new()

    context =
      start_root(host, "unrelated-clock",
        startup_gate: :unrelated,
        host_context: %{clock_wait_admission: %{forged: true}}
      )

    provider = prompt(context, "invoke the unrelated host tool")
    send(provider, {:events, [call("clock::sleep", %{"duration_ms" => 60_000}), done()]})
    assert_receive {:unrelated_clock_started, operation, executor}, 1_000
    refute Map.has_key?(operation.backend_context, :clock_wait_admission)

    assert {:ok, inventory} =
             ResourceRegistry.owner_status(
               context.binding.resource_registry,
               context.binding.owner_id
             )

    refute Enum.any?(inventory, &(&1.kind == :resource))
    monitor = Process.monitor(executor)
    assert :ok = Conversation.cancel(context.conversation)
    eventually(fn -> Conversation.status(context.conversation).phase == :terminal end)
    assert_receive {:DOWN, ^monitor, :process, ^executor, _}, 1_000
    status = Conversation.status(context.conversation)
    assert status.run.state == :unknown_outcome
    assert status.retirement_evidence == []
    assert {:ok, original} = EphemeralStore.load(host.store, context.run)

    refute Enum.any?(
             retained_records(original.run.outcome["cleanup"]["evidence"]),
             &(&1["record_type"] == "native_clock_wait_retirement")
           )

    refute_receive {:clock_provider, "unrelated-clock", _, _}, 30
  end

  test "cancel queued during admission prevents a later owned-executor release" do
    host = Host.new()

    context =
      start_root(host, "queued-stop",
        startup_gate: :before_backend,
        store: AckStore,
        context: %{table: host.store, test: self()}
      )

    provider = prompt(context, "stop before backend release")
    send(provider, {:events, [call("clock::sleep", %{"duration_ms" => 60_000}), done()]})
    assert_receive {:clock_ack_pending, :tool_invoked, intent_writer}, 1_000
    registry = context.binding.resource_registry
    conversation = context.conversation
    :ok = :sys.suspend(registry)

    try do
      send(intent_writer, :ack)
      eventually(fn -> queued_clock_start(registry) != nil end)
      {executor, _value} = queued_clock_start(registry)
      assert 1 == :erlang.trace(conversation, true, [:send, {:tracer, self()}])
      cancellation = Task.async(fn -> Conversation.cancel(conversation) end)
      eventually(fn -> queued_call?(conversation, :cancel) end)
      :ok = :sys.resume(registry)
      assert :ok = Task.await(cancellation, 3_000)
      eventually(fn -> Conversation.status(conversation).phase == :terminal end)
      assert 1 == :erlang.trace(conversation, false, [:send])
      delivered = :erlang.trace_delivered(conversation)
      assert_receive {:trace_delivered, ^conversation, ^delivered}, 1_000
      status = Conversation.status(conversation)
      assert status.run.state == :cancelled
      {operation, nil} = await_startup_boundary(context, :immediate)
      assert_proofs(status, operation, :direct)
      refute Process.alive?(executor)
      refute_receive {:clock_startup_pending, _, ^executor}, 30

      refute_receive {:trace, ^conversation, :send, {:run_owned_effect, ^conversation, _},
                      ^executor},
                     30

      refute_receive {:trace, ^conversation, :send_to_non_existing_process,
                      {:run_owned_effect, ^conversation, _}, ^executor},
                     30
    after
      if Process.alive?(registry), do: :sys.resume(registry)
      if Process.alive?(conversation), do: :erlang.trace(conversation, false, [:send])
    end
  end

  test "startup admission is reused by Backend and exact repeated registration ACK" do
    host = Host.new()

    context =
      start_root(host, "single-startup",
        startup_gate: :before_backend,
        store: AckStore,
        context: %{table: host.store, test: self()}
      )

    provider = prompt(context, "complete one admitted clock")
    send(provider, {:events, [call("clock::sleep", %{"duration_ms" => 10}), done()]})
    assert_receive {:clock_ack_pending, :tool_invoked, intent_writer}, 1_000
    send(intent_writer, :ack)
    {operation, executor} = await_startup_boundary(context, :before_backend)
    admission = operation.clock_wait_admission

    assert {:ok, before} =
             ResourceRegistry.owner_status(admission.registry, admission.handle.owner_id)

    assert Enum.count(before, &(&1.kind == :resource)) == 1

    send(executor, :continue_clock_startup)
    assert_receive {:clock_registered, consumed, registration, ^executor}, 1_000
    assert consumed.clock_wait_admission == admission
    assert registration == admission.registration

    assert_receive {:clock_registration_repeated, ^consumed, ^registration, {:ok, coordinator}},
                   1_000

    assert coordinator == context.conversation
    assert_receive {:clock_ack_pending, :tool_completed, result_writer}, 1_000

    assert {:ok, after_completion} =
             ResourceRegistry.owner_status(admission.registry, admission.handle.owner_id)

    assert Enum.count(after_completion, &(&1.kind == :resource)) == 1

    assert {:ok, value} =
             ResourceRegistry.fetch(
               admission.registry,
               admission.handle,
               admission.handle.owner_id
             )

    assert value.waiter == admission.waiter
    refute Process.alive?(admission.waiter)
    send(result_writer, :ack)
    assert_receive {:clock_provider, "single-startup", _, next}, 1_000

    assert :ok =
             ResourceRegistry.owner_transfer_ready(admission.registry, admission.handle.owner_id)

    finish(context, next)
  end

  for {mode, gate} <-
        for(
          mode <- [:direct, :deno],
          gate <- [:after_ack, :before_backend, :before_ack],
          do: {mode, gate}
        ) ++ [{:direct, :immediate}] do
    @tag mode: mode, startup_gate: gate
    test "#{mode} #{gate} clock cancellation survives cold reconciliation and admits a real fresh prompt",
         %{mode: mode, startup_gate: gate} do
      host = Host.new()
      context = start_root(host, "old-#{mode}", startup_gate: gate)
      provider = prompt(context, "wait")
      {name, arguments} = clock_call(mode)
      send(provider, {:events, [call(name, arguments), done()]})
      {operation, executor} = await_startup_boundary(context, gate)
      executor_ref = if executor, do: Process.monitor(executor)
      assert :ok = Conversation.cancel(context.conversation)
      eventually(fn -> Conversation.status(context.conversation).phase == :terminal end)

      if executor_ref do
        assert_receive {:DOWN, ^executor_ref, :process, ^executor, _}, 2_000
        assert_clock_waiter_retired(operation)
        send(executor, :continue_clock_startup)
        send(executor, :continue_clock_registration)
        refute Process.alive?(executor)
      end

      status = Conversation.status(context.conversation)
      assert status.run.state == :cancelled
      proofs = assert_proofs(status, operation, mode)
      assert {:ok, original} = EphemeralStore.load(host.store, context.run)
      assert original.run == status.run

      assert Enum.all?(
               proofs,
               &(&1 in retained_records(original.run.outcome["cleanup"]["evidence"]))
             )

      monitor = Process.monitor(context.conversation)
      stop_supervised!({:conversation, context.run})
      assert_receive {:DOWN, ^monitor, :process, _, _}, 1_000
      refute Process.alive?(provider)
      assert Session.status(context.session).phase == :closed

      assert {:ok, registry_manifest} =
               ResourceRegistry.recovery_manifest(
                 context.binding.resource_registry,
                 context.binding.owner_id
               )

      assert {:ok, registry_receipt} =
               reconcile_actual(host, registry_manifest, [], "registry-#{mode}")

      assert {:ok, _} =
               ResourceRegistry.reconcile_owner(
                 context.binding.resource_registry,
                 context.binding.owner_id,
                 registry_receipt["receipt_id"]
               )

      assert {:ok, manifest} = Session.recovery_manifest(context.session)
      assert {:ok, receipt} = reconcile_actual(host, manifest, proofs, "session-#{mode}")

      assert {:ok, %{status: :confirmed}} =
               Session.reconcile_close(context.session, receipt["receipt_id"])

      assert_rejects_substitution(host, manifest, proofs, mode)
      :ok = Host.put(host, {:store, context.run}, {MissingEvidenceStore, host.store})

      assert {:error, %Error{class: :unknown_outcome}} =
               reconcile_actual(host, manifest, proofs, "absent-source-#{mode}")

      :ok = Host.put(host, {:store, context.run}, {EphemeralStore, host.store})
      assert_independent_wait_remains(host, manifest, proofs, mode)
      assert {:ok, ^original} = EphemeralStore.load(host.store, context.run)

      session_ref = Process.monitor(context.session)
      stop_supervised!({:session, context.run})
      assert_receive {:DOWN, ^session_ref, :process, _, _}, 1_000
      fresh = start_root(host, "fresh-#{mode}")
      refute fresh.binding.owner_id == context.binding.owner_id
      refute fresh.binding.resource_registry == context.binding.resource_registry
      next = prompt(fresh, "continue after the retired wait")
      send(next, {:events, [call("clock::curr_time", %{}), done()]})
      assert_receive {:clock_returned, _, {:ok, %{current_time: current_time}}}, 1_000
      assert is_binary(current_time)
      assert_receive {:clock_provider, run, request, final}, 1_000
      assert run == fresh.run
      assert List.last(request.messages).result.current_time == current_time
      finish(fresh, final)
      assert {:ok, ^original} = EphemeralStore.load(host.store, context.run)
    end
  end

  for mode <- [:direct, :deno], gate <- [:after_ack, :before_backend, :before_ack] do
    @tag mode: mode, startup_gate: gate
    test "#{mode} #{gate} managed child retains exact clock proof through manager reconciliation",
         %{
           mode: mode,
           startup_gate: gate
         } do
      host = Host.new()
      test = self()
      names = @names ++ @collaboration
      root_auth = authority("parent", names)

      child_session =
        start_supervised!(
          {Session, owner_pid: test, recovery: Host.config(host), recovery_scope_id: "scope"},
          id: :child_session
        )

      contracts_table = :ets.new(:clock_contracts, [:public])

      manager =
        start_supervised!(
          {MultiAgent,
           root_agent_id: "root-agent",
           parent_run_id: "parent",
           parent_name: "/root",
           parent_authority: root_auth,
           min_wait_timeout_ms: 0,
           recovery: Host.config(host),
           recovery_scope_id: "scope",
           child_options: fn request, run, parent ->
             options =
               options(
                 child_session,
                 host,
                 run,
                 parent.child.incarnation,
                 names,
                 :ets.lookup_element(contracts_table, :contracts, 2),
                 test,
                 gate
               )

             {:ok, recovery_admission(host, request, parent, options)}
           end},
          id: :clock_manager
        )

      contracts = MultiAgent.contracts(:v2, manager)
      :ets.insert(contracts_table, {:contracts, contracts})
      root = start_root(host, "parent", names: names, contracts: contracts)
      provider = prompt(root, "spawn a clock worker")

      {parent, _} =
        tool(provider, "parent", "spawn_agent", %{"task_name" => "worker", "message" => "wait"})

      assert_receive {:clock_provider, child_run, _, child_provider}, 2_000
      {name, arguments} = clock_call(mode)
      send(child_provider, {:events, [call(name, arguments), done()]})
      {operation, executor} = await_startup_boundary(%{run: child_run}, gate)
      ref = Process.monitor(executor)
      {parent, result} = tool(parent, "parent", "interrupt_agent", %{"target" => "/root/worker"})
      refute result[:is_error], inspect(result)
      assert_receive {:DOWN, ^ref, :process, ^executor, _}, 1_000
      assert_clock_waiter_retired(operation)
      send(executor, :continue_clock_startup)
      send(executor, :continue_clock_registration)
      refute Process.alive?(executor)
      assert {:ok, snapshot} = MultiAgent.snapshot(manager)
      [child] = snapshot.agents
      assert child.run_id == child_run
      assert child.cleanup == :confirmed
      child_pid = :sys.get_state(manager).agents[child.name].pid
      status = Conversation.status(child_pid)
      proofs = assert_proofs(status, operation, mode)
      assert {:ok, original} = EphemeralStore.load(host.store, child_run)
      assert original.run == status.run
      finish(root, parent)
      child_ref = Process.monitor(child_pid)
      assert :ok = MultiAgent.close_session(manager)
      assert_receive {:DOWN, ^child_ref, :process, ^child_pid, _}, 2_000
      assert {:ok, ^original} = EphemeralStore.load(host.store, child_run)
      refute Process.alive?(child_provider)
      assert Session.status(child_session).phase == :closed
      seal_child_inventory(host, child, status.run)
      assert {:ok, child_manifest} = MultiAgent.recovery_manifest(manager, child.name)
      assert {:ok, receipt} = reconcile_actual(host, child_manifest, proofs, "child-#{mode}")

      assert {:ok, %{status: :confirmed}} =
               MultiAgent.reconcile_child(manager, receipt["receipt_id"])

      assert {:ok, manifest} = MultiAgent.recovery_manifest(manager, :manager)
      assert {:ok, receipt} = reconcile_actual(host, manifest, proofs, "manager-#{mode}")

      assert {:ok, %{status: :confirmed}} =
               MultiAgent.reconcile_close(manager, receipt["receipt_id"])

      assert_rejects_substitution(host, child_manifest, proofs, mode)
      assert {:ok, ^original} = EphemeralStore.load(host.store, child_run)
      child_session_ref = Process.monitor(child_session)
      stop_supervised!(:child_session)
      assert_receive {:DOWN, ^child_session_ref, :process, ^child_session, _}, 1_000
      fresh = start_root(host, "fresh-child-#{mode}-#{gate}")
      refute fresh.binding.owner_id == operation.session_binding_identity.owner_id
      refute fresh.binding.resource_registry == operation.clock_wait_admission.registry
      next = prompt(fresh, "continue after the retired child wait")
      finish(fresh, next)
      assert {:ok, ^original} = EphemeralStore.load(host.store, child_run)
    end
  end

  defp queued_clock_start(registry) do
    {:messages, messages} = Process.info(registry, :messages)

    Enum.find_value(messages, fn
      {:"$gen_call", _, {:start_clock_wait, _, value, _}} -> {value.executor, value}
      _ -> nil
    end)
  end

  defp queued_call?(process, request) do
    {:messages, messages} = Process.info(process, :messages)
    Enum.any?(messages, &match?({:"$gen_call", _, ^request}, &1))
  end

  defp await_startup_boundary(%{run: run, binding: binding}, :immediate) do
    assert_receive {:agent_runtime, ^run, %{type: :tool_started, invocation: invocation}}, 3_000

    operation =
      Map.put(
        invocation,
        :session_binding_identity,
        Map.take(binding, [:run_id, :owner_id, :incarnation, :run_incarnation])
      )

    {operation, nil}
  end

  defp await_startup_boundary(_context, :before_backend) do
    assert_receive {:clock_startup_pending, operation, executor}, 3_000
    admission = operation.backend_context[:clock_wait_admission]
    assert is_map(admission), "clock must have an exact admission before backend execution"
    binding = operation.backend_context.session_binding

    operation =
      operation
      |> Map.put(:clock_wait_admission, admission)
      |> Map.put(
        :test_late_registration_callback,
        operation.backend_context.register_cancellation
      )
      |> Map.put(
        :session_binding_identity,
        Map.take(binding, [:run_id, :owner_id, :incarnation, :run_incarnation])
      )

    assert_unarmed_clock(operation)
    {operation, executor}
  end

  defp await_startup_boundary(_context, :before_ack) do
    assert_receive {:clock_registration_pending, operation, _registration, executor}, 3_000
    invocation = operation.invocation_id
    assert_receive {:clock_registration_callback, ^invocation, callback}, 1_000
    operation = Map.put(operation, :test_late_registration_callback, callback)
    assert_unarmed_clock(operation)
    {operation, executor}
  end

  defp await_startup_boundary(_context, :after_ack) do
    assert_receive {:clock_registered, operation, _, executor}, 3_000
    {operation, executor}
  end

  defp assert_unarmed_clock(operation) do
    admission = operation.clock_wait_admission

    assert {:ok, value} =
             ResourceRegistry.fetch(
               admission.registry,
               admission.handle,
               admission.handle.owner_id
             )

    assert value.waiter == admission.waiter
    assert value.executor == admission.executor
    assert :atomics.get(admission.gate, 1) == 0
    assert Process.alive?(admission.waiter)
  end

  defp assert_clock_waiter_retired(operation) do
    admission = operation.clock_wait_admission
    refute Process.alive?(admission.waiter)
    assert :atomics.get(admission.gate, 1) in [2, 3]
    assert :atomics.get(admission.gate, 7) == 1
    assert :atomics.get(admission.gate, 8) == 1

    if callback = operation[:test_late_registration_callback] do
      phase = :atomics.get(admission.gate, 1)

      assert {:error, %Error{class: :resource_conflict}} =
               callback.(operation, admission.registration)

      assert :atomics.get(admission.gate, 1) == phase
      refute Process.alive?(admission.waiter)
    end
  end

  defp assert_proofs(status, operation, mode) do
    proofs = status.retirement_evidence
    clock = Enum.find(proofs, &(&1["record_type"] == "native_clock_wait_retirement"))
    assert is_map(clock)
    assert clock["identity"]["invocation_id"] == operation.invocation_id
    assert clock["executor_down"] == true
    assert clock["resources"] == "confirmed"
    assert clock["local_cleanup"] == "confirmed"
    assert clock["outcome"] == "unknown"
    assert clock["cancellation"]["record_type"] == "native_clock_cancellation"
    assert clock["cancellation"]["completion_gate"] == "closed"
    assert clock["cancellation"]["timer_retired"] == true
    assert clock["cancellation"]["waiter_down"] == true
    assert {:ok, ^clock} = ToolEffects.validate_retirement_record(clock, operation)

    if mode == :deno do
      outer = Enum.find(proofs, &(&1["record_type"] == "code_mode_retirement"))
      assert is_map(outer)
      assert clock["identity"]["enclosing_invocation_id"] == outer["identity"]["invocation_id"]
      assert clock["stop_generation"] == outer["stop_generation"]

      assert Enum.find(outer["nested"], &(&1["kind"] == "native_clock_wait_retirement")) == %{
               "kind" => "native_clock_wait_retirement",
               "identity" => clock["identity"],
               "evidence_digest" => clock["retirement_digest"]
             }
    end

    proofs
  end

  defp assert_rejects_substitution(host, manifest, proofs, mode) do
    clock = Enum.find(proofs, &(&1["record_type"] == "native_clock_wait_retirement"))

    changes = [
      put_in(clock, ["cancellation", "registration_id"], "another-registration"),
      put_in(clock, ["cancellation", "wait_generation"], "another-wait"),
      put_in(clock, ["identity", "invocation_id"], "another-invocation"),
      put_in(clock, ["provenance", "session_binding_identity", "owner_id"], "another-session"),
      Map.put(clock, "stop_generation", "another-stop"),
      put_in(clock, ["cancellation", "waiter_down"], false)
    ]

    for {changed, index} <- Enum.with_index(changes) do
      changed = Evidence.seal(changed, "retirement_digest")
      replaced = Enum.map(proofs, fn proof -> if proof == clock, do: changed, else: proof end)

      assert {:error, %Error{class: :unknown_outcome}} =
               reconcile_actual(host, manifest, replaced, "substitution-#{mode}-#{index}")
    end

    assert {:error, %Error{class: :unknown_outcome}} =
             reconcile_actual(host, manifest, [], "missing-#{mode}")

    if mode == :deno do
      outer = Enum.find(proofs, &(&1["record_type"] == "code_mode_retirement"))

      for {change, label} <- [
            {Map.put(outer, "nested", []), "missing-nested"},
            {Map.update!(outer, "nested", fn [entry | rest] ->
               [put_in(entry, ["identity", "enclosing_invocation_id"], "different-outer") | rest]
             end), "different-enclosing"}
          ] do
        changed = Evidence.seal(change, "retirement_digest")
        replaced = Enum.map(proofs, fn proof -> if proof == outer, do: changed, else: proof end)

        assert {:error, %Error{class: :unknown_outcome}} =
                 reconcile_actual(host, manifest, replaced, "nested-#{label}")
      end
    end
  end

  defp assert_independent_wait_remains(host, manifest, proofs, mode) do
    survivor = start_root(host, "survivor-#{mode}")
    provider = prompt(survivor, "independent wait")
    send(provider, {:events, [call("clock::sleep", %{"duration_ms" => 60_000}), done()]})
    assert_receive {:clock_registered, operation, _, executor}, 1_000
    assert {:ok, stored} = EphemeralStore.load(host.store, survivor.run)
    assert {:ok, obligations} = Reconciliation.run_obligations(stored.run, 1, "survivor-owner")

    combined =
      Host.manifest(
        manifest["subject"],
        manifest["run_refs"] ++
          [
            %{"store_ref" => survivor.run, "run_id" => survivor.run, "original_incarnation" => 1}
          ],
        manifest["obligations"] ++ obligations
      )

    assert {:error, %Error{}} = reconcile_actual(host, combined, proofs, "independent-#{mode}")
    assert Process.alive?(executor)

    assert Enum.any?(
             obligations,
             &(get_in(&1, ["identity", "invocation_id"]) == operation.invocation_id)
           )

    assert {:ok, ^stored} = EphemeralStore.load(host.store, survivor.run)
    survivor_run = survivor.run
    refute_receive {:clock_provider, ^survivor_run, _, _}, 30
    assert :ok = Conversation.cancel(survivor.conversation)
    eventually(fn -> Conversation.status(survivor.conversation).phase == :terminal end)
  end

  defp reconcile_actual(host, manifest, proofs, id) do
    observations =
      Enum.map(manifest["obligations"], fn obligation ->
        fact = Host.observe(obligation, "closed")

        if obligation["kind"] == "tool" do
          invocation = obligation["identity"]["invocation_id"]
          reference = id <> ":effect:" <> invocation
          proof = Enum.find(proofs, &(&1["identity"]["invocation_id"] == invocation))
          if proof, do: Host.put(host, {:evidence, reference}, proof)
          Map.put(fact, "effect_retirement_ref", reference)
        else
          fact
        end
      end)

    :ok = Host.put(host, {:evidence, id}, Host.bundle(manifest, observations))
    Reconciliation.reconcile(Host.config(host), Host.request(manifest, id, id))
  end

  defp start_root(host, run, overrides \\ []) do
    {names, overrides} = Keyword.pop(overrides, :names, @names)
    {contracts, overrides} = Keyword.pop(overrides, :contracts, [])
    {gate, overrides} = Keyword.pop(overrides, :startup_gate, :after_ack)

    session =
      start_supervised!(
        {Session, owner_pid: self(), recovery: Host.config(host), recovery_scope_id: "scope"},
        id: {:session, run}
      )

    options =
      options(session, host, run, 1, names, contracts, self(), gate) |> Keyword.merge(overrides)

    conversation = start_supervised!({Conversation, options}, id: {:conversation, run})
    %{conversation: conversation, session: session, binding: options[:session_binding], run: run}
  end

  defp options(session, host, run, incarnation, names, extra_contracts, test, gate) do
    bindings =
      Map.new(
        for contract <- extra_contracts,
            Map.has_key?(contract, :collaboration_binding),
            do: {contract.tool_name, contract.collaboration_binding.fingerprint}
      )

    auth = Map.put(authority(run, names), :tool_bindings, bindings)
    {:ok, binding} = Session.bind(session, auth, incarnation: incarnation)

    local =
      Tools.contracts(%{
        resource_registry: binding.resource_registry,
        session_registry: binding.resource_registry
      })
      |> Enum.filter(&(&1.namespace == "clock"))
      |> Enum.map(fn contract ->
        %{
          contract
          | backend:
              case gate do
                :immediate -> Backend
                :unrelated -> UnrelatedBackend
                _ -> ProbeBackend
              end,
            backend_context:
              contract.backend_context
              |> Map.merge(%{test: test, startup_gate: gate})
              |> then(fn context ->
                if gate == :unrelated,
                  do: Map.delete(context, :clock_wait_contract),
                  else: context
              end)
        }
      end)

    {:ok, profile} =
      Codex.profile(
        :mixed,
        %{session_binding: binding, code_mode_contracts: local ++ extra_contracts},
        auth,
        tools: names
      )

    [
      run_id: run,
      incarnation: incarnation,
      session_binding: binding,
      registry: profile.registry,
      tools: profile.tools,
      authority: profile.authority,
      store: EphemeralStore,
      context: host.store,
      provider: Provider,
      provider_context: %{test: test},
      subscriber: test,
      run_timeout: 20_000,
      effect_timeout: 10_000,
      cleanup_timeout: 2_000
    ]
  end

  defp recovery_admission(host, request, parent, options) do
    reference = "admission:" <> parent.child.attempt_id
    {:ok, request} = Evidence.public(request)

    {:ok, ceiling} =
      Evidence.public(
        Map.take(options[:authority], [:grants, :tool_revisions, :tool_bindings, :tool_revision])
      )

    config = %{"provider_ref" => "clock-provider", "profile" => "native-clock"}

    admission = %{
      "schema_version" => 1,
      "record_type" => "child_admission",
      "child_identity" => parent.child.recovery_identity,
      "store_ref" => "source",
      "config_ref" => reference <> ":config",
      "authority_ceiling_ref" => reference <> ":ceiling",
      "tool_profile" => request["profile"],
      "admission_receipt_ref" => reference,
      "child_request" => request,
      "configuration" => config,
      "authority_ceiling" => ceiling,
      "artifact_refs" => [],
      "inventory_ref" => reference <> ":inventory"
    }

    :ok = Host.put(host, {:evidence, reference}, admission)
    :ok = Host.put(host, {:evidence, admission["config_ref"]}, config)
    :ok = Host.put(host, {:evidence, admission["authority_ceiling_ref"]}, ceiling)
    :ok = Host.put(host, {:store, "source"}, {EphemeralStore, host.store})

    Keyword.merge(options,
      recovery_admission_ref: reference,
      recovery_store_ref: "source",
      recovery_config_ref: admission["config_ref"],
      recovery_authority_ref: admission["authority_ceiling_ref"],
      recovery_tool_profile: String.to_existing_atom(request["profile"])
    )
  end

  defp seal_child_inventory(host, child, run) do
    {:ok, admission} = Host.load_evidence(host, "admission:" <> child.attempt_id)

    {:ok, obligations} =
      Reconciliation.run_obligations(run, run.incarnation, "actual-clock-runtime")

    :ok =
      Host.put(host, {:evidence, admission["inventory_ref"]}, %{
        "schema_version" => 1,
        "record_type" => "child_inventory",
        "child_identity" => admission["child_identity"],
        "complete" => true,
        "producer_ref" => "actual-managed-child-owner-ledger",
        "obligations" => obligations
      })
  end

  defp retained_records(%{"record_type" => type} = record)
       when type in ["native_clock_wait_retirement", "code_mode_retirement"],
       do: [record]

  defp retained_records(value) when is_map(value),
    do: value |> Map.values() |> Enum.flat_map(&retained_records/1)

  defp retained_records(value) when is_list(value), do: Enum.flat_map(value, &retained_records/1)
  defp retained_records(_), do: []
  defp clock_call(:direct), do: {"clock::sleep", %{"duration_ms" => 60_000}}
  defp clock_call(:deno), do: {"exec", "return await tools.clock__sleep({duration_ms: 60000});"}
  defp authority(run, names), do: %{caller: "host", run_id: run, grants: names, tool_revision: 1}

  defp call(name, arguments),
    do: %{
      type: :tool_call_completed,
      tool_call: %{
        id: "clock-#{System.unique_integer([:positive])}",
        name: name,
        arguments: arguments
      }
    }

  defp done, do: %{type: :response_completed, message: %{role: :assistant, content: "done"}}

  defp prompt(context, text) do
    assert {:ok, _} = Conversation.prompt(context.conversation, text)
    assert_receive {:clock_provider, run, _, provider}, 1_000
    assert run == context.run
    provider
  end

  defp tool(provider, run, name, arguments) do
    send(provider, {:events, [call(name, arguments), done()]})
    assert_receive {:clock_provider, ^run, request, next}, 6_000
    {next, Enum.find(Enum.reverse(request.messages), &(&1[:role] == :tool)).result}
  end

  defp finish(context, provider) do
    send(provider, {:events, [done()]})
    eventually(fn -> Conversation.status(context.conversation).phase == :terminal end)
    assert Conversation.status(context.conversation).run.state == :completed
  end

  defp eventually(fun, attempts \\ 300)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          eventually(fun, attempts - 1)
        )
  end
end

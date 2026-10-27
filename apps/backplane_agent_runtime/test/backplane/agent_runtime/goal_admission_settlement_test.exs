Code.require_file("../../fixtures/goal_file_store.exs", __DIR__)

defmodule Backplane.AgentRuntime.GoalAdmissionSettlementTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{
    Conversation,
    EphemeralStore,
    Error,
    Execution,
    Goal,
    GoalFileStore
  }

  alias Backplane.AgentRuntime.Goal.State

  @moduletag :tmp_dir

  defmodule Host do
    @behaviour Backplane.AgentRuntime.Goal.Host
    def record_user_instruction(_, _, _), do: :ok

    def start_turn_if_idle(host, _, request) do
      Agent.get_and_update(host, fn state ->
        admission = %{
          run_id: "reserved-run",
          incarnation: 1,
          turn_id: "logical-turn",
          host_generation: request.host_generation,
          reservation_token: request.reservation_token
        }

        {{:ok, {:started, admission}}, %{state | admission: admission}}
      end)
    end

    def seal(host, admission) do
      Agent.update(host, &%{&1 | sealed: MapSet.put(&1.sealed, admission.reservation_token)})
    end

    def admit(host, admission) do
      Agent.get(host, fn state ->
        if state.admission == admission and
             not MapSet.member?(state.sealed, admission.reservation_token),
           do: :admitted,
           else: :fenced
      end)
    end
  end

  defmodule Store do
    def load(ctx, thread), do: GoalFileStore.load(ctx.store, thread)

    def compare_and_swap(ctx, thread, revision, goal_id, next) do
      case Agent.get_and_update(ctx.gate, &{&1, :normal}) do
        :reject ->
          {:error, Error.new(:execution_failure, "injected persistence failure")}

        mode when mode in [:lost_ack, :malformed_ack] ->
          with {:ok, committed} <-
                 GoalFileStore.compare_and_swap(ctx.store, thread, revision, goal_id, next) do
            if mode == :lost_ack,
              do: {:error, Error.new(:transient_transport, "injected lost acknowledgement")},
              else: {:ok, %{committed | revision: 0}}
          end

        :coerced_identity_ack ->
          with {:ok, committed} <-
                 GoalFileStore.compare_and_swap(ctx.store, thread, revision, goal_id, next) do
            receipts =
              Map.new(committed.admission_settlements, fn {token, receipt} ->
                admission = %{receipt.admission | host_generation: 1.0}

                {token,
                 %{
                   receipt
                   | admission: admission,
                     attestation: %{receipt.attestation | admission: admission}
                 }}
              end)

            {:ok, %{committed | admission_settlements: receipts}}
          end

        :normal ->
          GoalFileStore.compare_and_swap(ctx.store, thread, revision, goal_id, next)
      end
    end
  end

  defmodule Provider do
    def stream(_, %{test: test}) do
      send(test, {:executed, :provider})
      [%{type: :response_completed, message: %{role: :assistant, content: "done"}}]
    end
  end

  defmodule WaitingProvider do
    def stream(_, %{test: test}) do
      send(test, {:waiting_provider, self()})

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

  setup %{tmp_dir: root} do
    store = start_supervised!({GoalFileStore, root})
    gate = start_supervised!({Agent, fn -> :normal end}, id: :gate)

    host =
      start_supervised!({Agent, fn -> %{admission: nil, sealed: MapSet.new()} end}, id: :host)

    goal =
      start_supervised!(
        {Goal,
         thread_id: "thread",
         owner_pid: self(),
         store: Store,
         store_context: %{store: store, gate: gate},
         host: Host,
         host_context: host}
      )

    {:ok, _} = Goal.set(goal, %{objective: "finish"}, %{text: "finish"})
    %{goal: goal, host: host, gate: gate, store: store}
  end

  test "released executor preparation failure settles without Runtime receipts and permits later work",
       ctx do
    {:ok, {:started, admission}} = Goal.idle(ctx.goal, 1)
    {:ok, runtime_store} = EphemeralStore.new(1)
    supervisor = start_supervised!(Task.Supervisor)
    owner = self()

    {:ok, executor} =
      Task.Supervisor.start_child(supervisor, fn ->
        assert :admitted = Host.admit(ctx.host, admission)
        send(owner, {:preparation_failed, Execution.validate_limits(cleanup_timeout: 0)})
      end)

    monitor = Process.monitor(executor)
    assert_receive {:preparation_failed, {:error, %Error{class: :validation}}}
    assert_receive {:DOWN, ^monitor, :process, ^executor, :normal}

    assert {:error, %Error{class: :not_found}} =
             EphemeralStore.load(runtime_store, admission.run_id, [])

    Host.seal(ctx.host, admission)
    assert :fenced = Host.admit(ctx.host, admission)
    assert {:ok, {:not_submitted, :already_reserved}} = Goal.idle(ctx.goal, 1)

    assert {:ok, {:settled, :preparation_failed}} = settle(ctx.goal, admission)
    {:ok, snapshot} = Goal.snapshot(ctx.goal)
    assert snapshot.goal.status == :active
    assert snapshot.receipts == %{}
    assert snapshot.deliveries == %{}
    assert snapshot.continuation_deferral == nil
    assert map_size(snapshot.admission_settlements) == 1
    refute_receive {:executed, _}, 10

    conversation(ctx, %{run_id: "ordinary-after-failure"}, Provider, :user)
    assert_receive {:executed, :provider}, 1_000
    assert_receive {:agent_runtime, "ordinary-after-failure", %{type: :run_completed}}, 1_000

    {:ok, {:started, fresh}} = Goal.idle(ctx.goal, 2)
    assert fresh.reservation_token != admission.reservation_token
    assert :admitted = Host.admit(ctx.host, fresh)
    conversation(ctx, fresh)
    assert_receive {:executed, :provider}, 1_000
    assert_receive {:agent_runtime, "reserved-run", %{type: :run_completed}}, 1_000
    assert {:ok, {:started, _}} = Goal.idle(ctx.goal, 3)
  end

  test "closed evidence and complete durable identity are owner-only", ctx do
    {:ok, {:started, admission}} = Goal.idle(ctx.goal, 1)

    assert {:error, %Error{class: :forbidden}} =
             Task.async(fn -> settle(ctx.goal, admission) end) |> Task.await()

    for invalid <- [
          Map.delete(admission, :turn_id),
          %{admission | incarnation: 0},
          %{admission | host_generation: make_ref()}
        ] do
      assert {:error, %Error{class: :validation}} = settle(ctx.goal, invalid)
    end

    for evidence <- [
          Map.delete(attestation(admission), :executor),
          Map.put(attestation(admission), :extra, true),
          %{attestation(admission) | effects: :unknown},
          %{attestation(admission) | admission: Map.put(admission, :extra, true)},
          %{attestation(admission) | admission: %{admission | host_generation: 2}}
        ] do
      assert {:error, %Error{class: :validation}} =
               Goal.settle_unstarted_admission(ctx.goal, admission, :preparation_failed, evidence)
    end

    assert {:error, %Error{class: :validation}} = settle(ctx.goal, admission, :paused)
    assert {:ok, {:not_submitted, :already_reserved}} = Goal.idle(ctx.goal, 1)
  end

  test "every stale identity is harmless and extra admission metadata has no authority", ctx do
    {:ok, {:started, admission}} = Goal.idle(ctx.goal, 1)

    for {key, value} <- [
          run_id: "old",
          turn_id: "old",
          incarnation: 2,
          host_generation: 2,
          reservation_token: "old"
        ] do
      assert {:ok, {:not_settled, :stale}} = settle(ctx.goal, Map.put(admission, key, value))
    end

    supplied = Map.put(admission, :untrusted_metadata, self())

    assert {:ok, {:settled, :preparation_failed}} =
             Goal.settle_unstarted_admission(
               ctx.goal,
               supplied,
               :preparation_failed,
               attestation(admission)
             )
  end

  for {generation, coerced} <- [{1, 1.0}, {%{nested: [1]}, %{nested: [1.0]}}] do
    @generation generation
    @coerced coerced

    test "settlement identity compares generation #{inspect(generation)} without numeric coercion",
         ctx do
      {:ok, {:started, admission}} = Goal.idle(ctx.goal, @generation)
      changed = %{admission | host_generation: @coerced}

      assert {:ok, {:not_settled, :stale}} = settle(ctx.goal, changed)
      assert :sys.get_state(ctx.goal).reserved === admission
    end

    test "attestation identity compares generation #{inspect(generation)} without numeric coercion",
         ctx do
      {:ok, {:started, admission}} = Goal.idle(ctx.goal, @generation)
      changed = %{admission | host_generation: @coerced}

      assert {:error, %Error{class: :validation}} =
               Goal.settle_unstarted_admission(
                 ctx.goal,
                 admission,
                 :preparation_failed,
                 attestation(changed)
               )

      assert :sys.get_state(ctx.goal).reserved === admission
    end

    test "saved settlement retry compares generation #{inspect(generation)} without numeric coercion",
         ctx do
      {:ok, {:started, admission}} = Goal.idle(ctx.goal, @generation)
      changed = %{admission | host_generation: @coerced}
      assert {:ok, {:settled, :preparation_failed}} = settle(ctx.goal, admission)
      assert {:error, %Error{class: :resource_conflict}} = settle(ctx.goal, changed)
    end

    test "explicit binding identity compares generation #{inspect(generation)} without numeric coercion",
         ctx do
      {:ok, {:started, admission}} = Goal.idle(ctx.goal, @generation)
      changed = %{admission | host_generation: @coerced}

      assert {:error, %Error{class: :resource_conflict}} =
               Goal.bind(ctx.goal, Map.put(attrs(), :admission, changed))

      assert {:ok, binding} = Goal.bind(ctx.goal, Map.put(attrs(), :admission, admission))
      assert binding.admission === admission
    end
  end

  test "a numerically coerced CAS acknowledgement cannot confirm settlement", ctx do
    {:ok, {:started, admission}} = Goal.idle(ctx.goal, 1)
    Agent.update(ctx.gate, fn _ -> :coerced_identity_ack end)

    assert {:error, %Error{class: :malformed_result}} = settle(ctx.goal, admission)
    assert :sys.get_state(ctx.goal).reserved === admission
    assert {:error, %Error{class: :resource_conflict}} = Goal.bind(ctx.goal, attrs())
    assert {:ok, {:settled, :preparation_failed}} = settle(ctx.goal, admission)
  end

  test "settlement fences delayed binding and delegation while explicit fresh token permits reuse",
       ctx do
    {:ok, parent} = Goal.bind(ctx.goal, attrs("unrelated"))
    {:ok, {:started, admission}} = Goal.idle(ctx.goal, 1)
    assert {:ok, {:settled, :preparation_failed}} = settle(ctx.goal, admission)
    assert {:error, %Error{class: :resource_conflict}} = Goal.bind(ctx.goal, attrs())
    assert {:error, %Error{class: :resource_conflict}} = Goal.delegate(ctx.goal, parent, attrs())
    assert {:ok, _} = Goal.attribution(ctx.goal, parent)
    {:ok, {:started, fresh}} = Goal.idle(ctx.goal, 2)

    assert {:error, %Error{class: :resource_conflict}} =
             Goal.bind(ctx.goal, Map.put(attrs(), :admission, admission))

    assert {:error, %Error{class: :validation}} =
             Goal.bind(ctx.goal, Map.put(attrs(), :admission, %{}))

    assert {:ok, binding} = Goal.bind(ctx.goal, Map.put(attrs(), :admission, fresh))
    assert binding.admission == fresh
    assert {:ok, {:not_settled, :bound}} = settle(ctx.goal, fresh)
    assert {:ok, :unbound} = Goal.unbind(ctx.goal, binding)
    assert {:ok, delegated} = Goal.delegate(ctx.goal, parent, Map.put(attrs(), :admission, fresh))
    assert delegated.admission == fresh

    assert {:error, %Error{class: :resource_conflict}} =
             Goal.delegate(
               ctx.goal,
               parent,
               Map.put(%{attrs() | thread_id: "child"}, :admission, fresh)
             )
  end

  test "a sealed host rejects a genuinely delayed admission after settlement", ctx do
    {:ok, {:started, admission}} = Goal.idle(ctx.goal, 1)
    supervisor = start_supervised!(Task.Supervisor)
    owner = self()

    {:ok, delayed} =
      Task.Supervisor.start_child(supervisor, fn ->
        receive do
          :admit -> send(owner, {:delayed_admission, Host.admit(ctx.host, admission)})
        end
      end)

    Host.seal(ctx.host, admission)
    assert {:ok, {:settled, :preparation_failed}} = settle(ctx.goal, admission)
    send(delayed, :admit)
    assert_receive {:delayed_admission, :fenced}
    refute_receive {:executed, _}, 10
  end

  test "explicit cancellation persists once and an old retry never defers newer work", ctx do
    {:ok, {:started, admission}} = Goal.idle(ctx.goal, 1)
    assert {:ok, {:settled, :cancelled}} = settle(ctx.goal, admission, :cancelled)
    assert {:ok, %{goal: %{status: :active}}} = Goal.get(ctx.goal)
    assert {:ok, {:not_submitted, :deferred}} = Goal.idle(ctx.goal, 2)
    {:ok, before} = Goal.snapshot(ctx.goal)
    assert before.continuation_deferral == Map.put(admission, :reason, :cancelled)
    assert {:ok, {:settled, :cancelled}} = settle(ctx.goal, admission, :cancelled)
    {:ok, duplicate} = Goal.snapshot(ctx.goal)
    assert duplicate.revision == before.revision
    assert {:ok, _} = Goal.restore(ctx.goal)
    assert {:ok, {:not_submitted, :deferred}} = Goal.idle(ctx.goal, 2)
    assert {:ok, _} = Goal.set(ctx.goal, %{status: :active}, %{text: "resume"})
    {:ok, {:started, fresh}} = Goal.idle(ctx.goal, 2)
    assert {:ok, {:settled, :cancelled}} = settle(ctx.goal, admission, :cancelled)
    assert :sys.get_state(ctx.goal).reserved == fresh
    {:ok, current} = Goal.snapshot(ctx.goal)
    assert current.continuation_deferral == nil
    assert {:error, %Error{class: :resource_conflict}} = settle(ctx.goal, admission, :superseded)
  end

  test "rejected persistence retains reservation, pending fence and immutable retry payload",
       ctx do
    {:ok, {:started, admission}} = Goal.idle(ctx.goal, 1)
    Agent.update(ctx.gate, fn _ -> :reject end)
    assert {:error, %Error{class: :execution_failure}} = settle(ctx.goal, admission)
    assert :sys.get_state(ctx.goal).reserved == admission
    assert {:error, %Error{class: :resource_conflict}} = Goal.bind(ctx.goal, attrs())
    assert {:error, %Error{class: :resource_conflict}} = settle(ctx.goal, admission, :cancelled)
    {:ok, stored} = GoalFileStore.load(ctx.store, "thread")
    assert stored.admission_settlements == %{}
    assert {:ok, {:settled, :preparation_failed}} = settle(ctx.goal, admission)
  end

  for {mode, class} <- [lost_ack: :transient_transport, malformed_ack: :malformed_result] do
    test "#{mode} is reconciled without duplicate cancellation", ctx do
      {:ok, {:started, admission}} = Goal.idle(ctx.goal, 1)
      Agent.update(ctx.gate, fn _ -> unquote(mode) end)
      assert {:error, %Error{class: unquote(class)}} = settle(ctx.goal, admission, :cancelled)
      assert :sys.get_state(ctx.goal).reserved == admission
      {:ok, persisted} = GoalFileStore.load(ctx.store, "thread")
      assert map_size(persisted.admission_settlements) == 1
      assert {:ok, {:settled, :cancelled}} = settle(ctx.goal, admission, :cancelled)
      {:ok, after_retry} = Goal.snapshot(ctx.goal)
      assert after_retry.revision == persisted.revision
      assert after_retry.continuation_deferral == persisted.continuation_deferral
    end
  end

  test "unknown acknowledgement followed by Goal replacement preserves historical outcome", ctx do
    {:ok, {:started, admission}} = Goal.idle(ctx.goal, 1)
    Agent.update(ctx.gate, fn _ -> :lost_ack end)
    assert {:error, %Error{class: :transient_transport}} = settle(ctx.goal, admission, :cancelled)
    assert {:ok, _} = Goal.clear(ctx.goal, %{text: "replace"})
    assert {:ok, _} = Goal.set(ctx.goal, %{objective: "new objective"}, %{text: "new"})
    assert {:ok, _} = Goal.restore(ctx.goal)
    {:ok, {:started, fresh}} = Goal.idle(ctx.goal, 2)
    assert {:ok, {:settled, :cancelled}} = settle(ctx.goal, admission, :cancelled)
    assert :sys.get_state(ctx.goal).reserved == fresh
    {:ok, record} = Goal.snapshot(ctx.goal)
    assert record.goal.objective == "new objective"
    assert record.continuation_deferral == nil
  end

  test "uncommitted attempt remains fenced through mutation and same-process restore", ctx do
    {:ok, {:started, admission}} = Goal.idle(ctx.goal, 1)
    Agent.update(ctx.gate, fn _ -> :reject end)
    assert {:error, %Error{class: :execution_failure}} = settle(ctx.goal, admission)
    assert {:ok, _} = Goal.set(ctx.goal, %{status: :active}, %{text: "continue"})
    assert {:ok, _} = Goal.restore(ctx.goal)
    assert {:ok, {:not_settled, :stale}} = settle(ctx.goal, admission)
    assert {:error, %Error{class: :resource_conflict}} = Goal.bind(ctx.goal, attrs())
    {:ok, {:started, fresh}} = Goal.idle(ctx.goal, 2)
    assert {:ok, _} = Goal.bind(ctx.goal, Map.put(attrs(), :admission, fresh))
  end

  test "real Conversation start with a distinct turn ID prevents settlement", ctx do
    {:ok, {:started, admission}} = Goal.idle(ctx.goal, 1)
    pid = conversation(ctx, admission, WaitingProvider)
    assert_receive {:waiting_provider, provider}, 1_000
    state = :sys.get_state(pid)
    assert state.conversation.turn_id != admission.turn_id
    assert {:ok, {:not_settled, :started}} = settle(ctx.goal, admission)

    send(
      provider,
      {:events, [%{type: :response_completed, message: %{role: :assistant, content: "done"}}]}
    )

    assert_receive {:agent_runtime, "reserved-run", %{type: :run_completed}}, 1_000
    assert {:ok, {:not_settled, :stale}} = settle(ctx.goal, admission)
  end

  test "real Conversation start accounting failure remains started without Provider dispatch",
       ctx do
    {:ok, {:started, admission}} = Goal.idle(ctx.goal, 1)
    Agent.update(ctx.gate, fn _ -> :reject end)
    pid = conversation(ctx, admission, WaitingProvider)
    assert_receive {:agent_runtime, "reserved-run", %{type: :storage_failed}}, 1_000
    state = :sys.get_state(pid)
    assert state.conversation.turn_id != admission.turn_id
    assert Enum.any?(state.conversation.goal_outbox, &(&1.type == :turn_started))
    refute_receive {:waiting_provider, _}, 10
    assert {:ok, :unbound} = Goal.unbind(ctx.goal, state.opts[:goal_binding])
    assert {:ok, {:not_settled, :started}} = settle(ctx.goal, admission)
  end

  test "start observation survives a failed accounting ACK and unbind", ctx do
    {:ok, {:started, admission}} = Goal.idle(ctx.goal, 1)
    {:ok, binding} = Goal.bind(ctx.goal, attrs())
    Agent.update(ctx.gate, fn _ -> :reject end)

    assert {:error, %Error{class: :execution_failure}} =
             Goal.committed(ctx.goal, event(binding, :turn_started, 1))

    assert {:ok, :unbound} = Goal.unbind(ctx.goal, binding)
    assert {:ok, {:not_settled, :started}} = settle(ctx.goal, admission)
  end

  test "fresh equal-revision evidence blocks no-start while old exact replay does not", ctx do
    {:ok, binding} = Goal.bind(ctx.goal, attrs())
    start = event(binding, :turn_started, 1)
    stop = event(binding, :turn_stopped, 2)
    assert {:ok, _} = Goal.committed(ctx.goal, start)
    assert {:ok, _} = Goal.committed(ctx.goal, stop)
    {:ok, {:started, admission}} = Goal.idle(ctx.goal, 1)
    assert {:ok, _} = Goal.committed(ctx.goal, start)
    assert {:ok, _} = Goal.committed(ctx.goal, stop)
    assert {:ok, :unbound} = Goal.unbind(ctx.goal, binding)
    assert {:ok, {:settled, :preparation_failed}} = settle(ctx.goal, admission)
    {:ok, record} = Goal.snapshot(ctx.goal)
    assert record.runtime_receipt_counts[{"reserved-run", 1}] == 2

    {:ok, {:started, fresh}} = Goal.idle(ctx.goal, 2)
    external = event(binding, :item_completed, 2, %{kind: :assistant, text: "new"})
    {:ok, next} = State.account(record, external)
    assert next.event_revisions == record.event_revisions
    assert next.runtime_receipt_counts[{"reserved-run", 1}] == 3
    GoalFileStore.replace_on_next_cas(ctx.store, "thread", next)
    assert {:ok, {:not_settled, :execution_observed}} = settle(ctx.goal, fresh)
    assert :sys.get_state(ctx.goal).reserved == fresh
  end

  test "failed fresh non-start receipt remains execution evidence after unbind", ctx do
    {:ok, {:started, admission}} = Goal.idle(ctx.goal, 1)
    {:ok, binding} = Goal.bind(ctx.goal, attrs())
    Agent.update(ctx.gate, fn _ -> :reject end)

    assert {:error, %Error{class: :execution_failure}} =
             Goal.committed(
               ctx.goal,
               event(binding, :item_completed, 1, %{kind: :reasoning, text: "x"})
             )

    assert {:ok, :unbound} = Goal.unbind(ctx.goal, binding)
    assert {:ok, {:not_settled, :execution_observed}} = settle(ctx.goal, admission)
  end

  test "invalid receipt cannot claim execution, but a live Plan binding refuses settlement",
       ctx do
    {:ok, {:started, admission}} = Goal.idle(ctx.goal, 1)
    {:ok, binding} = Goal.bind(ctx.goal, Map.put(attrs(), :mode, :plan))
    assert {:ok, {:not_settled, :bound}} = settle(ctx.goal, admission)
    invalid = %{event(binding, :turn_started, 1) | expected_goal_id: "old"}
    assert {:error, %Error{class: :resource_conflict}} = Goal.committed(ctx.goal, invalid)
    assert {:ok, :unbound} = Goal.unbind(ctx.goal, binding)
    assert {:ok, {:settled, :superseded}} = settle(ctx.goal, admission, :superseded)
  end

  test "unrelated binding, pending receipt, usage, audits and elapsed time survive settlement",
       ctx do
    {:ok, binding} = Goal.bind(ctx.goal, attrs("other"))
    assert {:ok, _} = Goal.committed(ctx.goal, event(binding, :turn_started, 1))

    usage = %{
      identity: "usage",
      attempt_id: "a",
      input_tokens: 7,
      cached_tokens: 2,
      output_tokens: 3
    }

    assert {:ok, _} = Goal.committed(ctx.goal, event(binding, :usage, 2, usage))
    {:ok, {:started, admission}} = Goal.idle(ctx.goal, 1)
    Agent.update(ctx.gate, fn _ -> :reject end)

    assert {:error, %Error{class: :execution_failure}} =
             Goal.committed(
               ctx.goal,
               event(binding, :item_completed, 3, %{kind: :reasoning, text: "x"})
             )

    before = :sys.get_state(ctx.goal)
    assert {:ok, {:settled, :superseded}} = settle(ctx.goal, admission, :superseded)
    after_settlement = :sys.get_state(ctx.goal)
    assert before.bindings == after_settlement.bindings
    assert before.pending_receipts == after_settlement.pending_receipts
    assert after_settlement.record.goal.tokens_used == 8

    for key <- [
          :receipts,
          :usage,
          :turns,
          :baselines,
          :usage_baselines,
          :failure_turns,
          :empty_turns
        ] do
      assert before.record[key] == after_settlement.record[key]
    end

    assert after_settlement.elapsed_ms >= before.elapsed_ms
    assert {:ok, _} = Goal.attribution(ctx.goal, binding)
  end

  test "CAS reload retains whole and fractional active elapsed time", ctx do
    {:ok, {:started, admission}} = Goal.idle(ctx.goal, 1)
    {:ok, stored} = GoalFileStore.load(ctx.store, "thread")

    :sys.replace_state(ctx.goal, fn state ->
      %{state | monotonic: System.monotonic_time(:millisecond) - 2_375, elapsed_ms: 250}
    end)

    GoalFileStore.replace_on_next_cas(ctx.store, "thread", stored)
    assert {:ok, {:settled, :preparation_failed}} = settle(ctx.goal, admission)
    current = :sys.get_state(ctx.goal)
    assert current.record.goal.time_used_seconds >= 2
    assert current.elapsed_ms >= 625
  end

  test "legacy stored defaults load and malformed present extension data is rejected", ctx do
    {:ok, stored} = GoalFileStore.load(ctx.store, "thread")
    legacy = Map.drop(stored, [:runtime_receipt_counts, :admission_settlements])

    assert {:ok, _} =
             GoalFileStore.compare_and_swap(
               ctx.store,
               "thread",
               stored.revision,
               stored.goal.goal_id,
               legacy
             )

    assert {:ok, _} = Goal.restore(ctx.goal)
    {:ok, {:started, admission}} = Goal.idle(ctx.goal, 1)
    assert {:ok, {:settled, :preparation_failed}} = settle(ctx.goal, admission)
    {:ok, record} = Goal.snapshot(ctx.goal)

    for bad <- [
          Map.put(record, :runtime_receipt_counts, nil),
          Map.put(record, :runtime_receipt_counts, %{{"run", 1} => -1}),
          Map.put(record, :admission_settlements, %{"bad" => %{}})
        ] do
      assert {:error, %Error{class: :malformed_result}} =
               Backplane.AgentRuntime.Goal.Store.compare_and_swap(
                 Store,
                 %{store: ctx.store, gate: ctx.gate},
                 "thread",
                 record.revision,
                 record.goal.goal_id,
                 bad
               )
    end
  end

  test "fork starts without source settlement tombstones or receipt counts", ctx do
    {:ok, {:started, admission}} = Goal.idle(ctx.goal, 1)
    assert {:ok, {:settled, :preparation_failed}} = settle(ctx.goal, admission)
    assert {:ok, copied} = Goal.fork_snapshot(ctx.goal, "fork")
    assert copied.admission_settlements == %{}
    assert copied.runtime_receipt_counts == %{}
  end

  defp event(binding, type, revision, payload \\ %{}) do
    %{
      binding: binding,
      receipt_id: "#{binding.run_id}:#{type}:#{revision}",
      revision: revision,
      thread_id: "thread",
      run_id: binding.run_id,
      incarnation: binding.incarnation,
      turn_id: "runtime-turn",
      expected_goal_id: binding.expected_goal_id,
      type: type,
      payload: payload
    }
  end

  defp attestation(admission) do
    %{
      admission: admission,
      executor: :confirmed_down,
      runtime_admission: :never_started,
      future_start: :fenced,
      effects: :none_dispatched
    }
  end

  defp settle(goal, admission, reason \\ :preparation_failed),
    do: Goal.settle_unstarted_admission(goal, admission, reason, attestation(admission))

  defp attrs(run \\ "reserved-run"),
    do: %{
      thread_id: "thread",
      run_id: run,
      incarnation: 1,
      authority: %{run_id: run},
      usage_authoritative: true
    }

  defp conversation(ctx, admission, provider \\ Provider, trigger \\ :goal) do
    binding_attrs = attrs(admission.run_id)

    binding_attrs =
      if trigger == :goal, do: Map.put(binding_attrs, :admission, admission), else: binding_attrs

    {:ok, binding} = Goal.bind(ctx.goal, binding_attrs)
    {:ok, runtime_store} = EphemeralStore.new(1)

    pid =
      start_supervised!(
        {Conversation,
         run_id: admission.run_id,
         thread_id: "thread",
         store: EphemeralStore,
         context: runtime_store,
         provider: provider,
         provider_context: %{test: self()},
         authority: %{caller: "host", run_id: admission.run_id, grants: [], tool_revision: 1},
         subscriber: self(),
         goal: ctx.goal,
         goal_binding: binding,
         goal_trigger: trigger}
      )

    assert {:ok, _} = Conversation.prompt(pid, "continue")
    pid
  end
end

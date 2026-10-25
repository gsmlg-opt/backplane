Code.require_file("../../fixtures/goal_file_store.exs", __DIR__)

defmodule Backplane.AgentRuntime.GoalAdmissionWithdrawalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{
    Conversation,
    EphemeralStore,
    Error,
    Goal,
    GoalFileStore,
    ToolRegistry
  }

  @moduletag :tmp_dir

  defmodule Host do
    @behaviour Backplane.AgentRuntime.Goal.Host
    def record_user_instruction(_, _, _), do: :ok

    def start_turn_if_idle(host, _thread, request) do
      Agent.get_and_update(host, fn state ->
        if state.reserved != nil or state.generation != request.host_generation do
          {{:ok, {:not_submitted, :busy}}, state}
        else
          admission =
            Map.merge(Map.take(request, [:host_generation, :reservation_token]), %{
              run_id: "reserved-run",
              turn_id: "logical-turn",
              incarnation: 1
            })

          {{:ok, {:started, admission}}, %{state | reserved: admission, phase: :reserved}}
        end
      end)
    end

    def fence(host, admission) do
      Agent.get_and_update(host, fn state ->
        if state.reserved == admission and state.phase == :reserved,
          do: {:fenced, %{state | generation: state.generation + 1, reserved: nil}},
          else: {:release_won, state}
      end)
    end

    def release(host, admission) do
      Agent.get_and_update(host, fn state ->
        if state.reserved == admission and state.phase == :reserved,
          do: {:released, %{state | phase: :released}},
          else: {:not_released, state}
      end)
    end
  end

  defmodule Store do
    def load(ctx, thread), do: GoalFileStore.load(ctx.store, thread)

    def compare_and_swap(ctx, thread, revision, goal_id, next) do
      if Agent.get(ctx.gate, & &1),
        do: {:error, Error.new(:execution_failure, "injected Goal storage outage")},
        else: GoalFileStore.compare_and_swap(ctx.store, thread, revision, goal_id, next)
    end
  end

  defmodule Provider do
    def stream(request, %{test: test}) do
      send(test, {:executed, :provider})
      final = %{type: :response_completed, message: %{role: :assistant, content: "done"}}

      if Enum.any?(request.messages, &(&1.role == :tool)),
        do: [final],
        else: [
          %{type: :tool_call_completed, tool_call: %{id: "call", name: "effect", arguments: %{}}},
          final
        ]
    end
  end

  defmodule Hooks do
    def prompt(message, %{test: test}) do
      send(test, {:executed, :hook})
      {:ok, message}
    end
  end

  defmodule Backend do
    def execute(operation) do
      send(operation.backend_context.test, {:executed, :tool})
      {:ok, %{text: "done"}}
    end
  end

  setup %{tmp_dir: root} do
    store = start_supervised!({GoalFileStore, root})

    host =
      start_supervised!({Agent, fn -> %{generation: 1, reserved: nil, phase: nil} end}, id: :host)

    gate = start_supervised!({Agent, fn -> false end}, id: :gate)
    context = %{store: store, gate: gate}

    goal =
      start_supervised!(
        {Goal,
         thread_id: "thread",
         owner_pid: self(),
         store: Store,
         store_context: context,
         host: Host,
         host_context: host}
      )

    {:ok, _} = Goal.set(goal, %{objective: "finish"}, %{text: "finish"})
    %{goal: goal, host: host, gate: gate, store: store}
  end

  test "fenced supersession executes nothing and a later generation can release real work", ctx do
    assert {:ok, {:started, admission}} = Goal.idle(ctx.goal, 1)
    assert admission.host_generation == 1
    assert is_binary(admission.reservation_token)
    before = :sys.get_state(ctx.goal)
    assert :fenced = Host.fence(ctx.host, admission)

    assert {:ok, {:withdrawn, :superseded}} =
             Goal.withdraw_admission(ctx.goal, admission, :superseded)

    assert :not_released = Host.release(ctx.host, admission)
    refute_receive {:executed, _}, 10
    after_withdrawal = :sys.get_state(ctx.goal)
    assert after_withdrawal.monotonic == before.monotonic
    assert after_withdrawal.elapsed_ms == before.elapsed_ms

    assert {:ok, {:started, next}} = Goal.idle(ctx.goal, 2)
    assert next.reservation_token != admission.reservation_token

    assert {:ok, {:not_withdrawn, :stale}} =
             Goal.withdraw_admission(ctx.goal, admission, :cancelled)

    assert {:ok, {:not_submitted, :already_reserved}} = Goal.idle(ctx.goal, 2)
    assert :released = Host.release(ctx.host, next)
    start_released_conversation(ctx, next)
    assert_receive {:executed, :hook}, 1_000
    assert_receive {:executed, :provider}, 1_000
    assert_receive {:executed, :tool}, 1_000
    assert_receive {:agent_runtime, "reserved-run", %{type: :run_completed}}, 1_000
    assert :sys.get_state(ctx.goal).reserved == nil
  end

  test "explicit pre-release cancellation durably defers without pausing or executing", ctx do
    {:ok, {:started, admission}} = Goal.idle(ctx.goal, 1)
    assert :fenced = Host.fence(ctx.host, admission)

    assert {:ok, {:withdrawn, :cancelled}} =
             Goal.withdraw_admission(ctx.goal, admission, :cancelled)

    assert :not_released = Host.release(ctx.host, admission)
    refute_receive {:executed, _}, 10
    assert {:ok, %{goal: %{status: :active}}} = Goal.get(ctx.goal)
    assert {:ok, record} = GoalFileStore.load(ctx.store, "thread")
    assert record.continuation_deferral == Map.put(admission, :reason, :cancelled)
    assert record.receipts == %{}
    assert {:ok, _} = Goal.restore(ctx.goal)
    assert {:ok, {:not_submitted, :deferred}} = Goal.idle(ctx.goal, 2)
    assert {:ok, _} = Goal.set(ctx.goal, %{status: :active}, %{text: "continue"})
    assert {:ok, {:started, _}} = Goal.idle(ctx.goal, 2)
  end

  test "owner, complete identity, generation and unique token fence withdrawal", ctx do
    {:ok, {:started, admission}} = Goal.idle(ctx.goal, 1)

    assert {:error, %Error{class: :forbidden}} =
             Task.async(fn ->
               Goal.withdraw_admission(ctx.goal, admission, :superseded)
             end)
             |> Task.await()

    assert {:error, %Error{class: :validation}} =
             Goal.withdraw_admission(ctx.goal, %{}, :superseded)

    assert {:error, %Error{class: :validation}} =
             Goal.withdraw_admission(ctx.goal, admission, :paused)

    for {key, value} <- [
          run_id: "other",
          turn_id: "other",
          incarnation: 2,
          host_generation: 2,
          reservation_token: "other"
        ] do
      assert {:ok, {:not_withdrawn, :stale}} =
               Goal.withdraw_admission(ctx.goal, Map.put(admission, key, value), :superseded)
    end

    assert {:ok, {:not_submitted, :already_reserved}} = Goal.idle(ctx.goal, 1)
    assert :fenced = Host.fence(ctx.host, admission)

    assert {:ok, {:withdrawn, :superseded}} =
             Goal.withdraw_admission(ctx.goal, admission, :superseded)

    assert {:ok, {:not_withdrawn, :stale}} =
             Goal.withdraw_admission(ctx.goal, admission, :cancelled)

    {:ok, snapshot} = Goal.snapshot(ctx.goal)
    assert snapshot.continuation_deferral == nil
  end

  test "start receipt wins even when its Store acknowledgement fails; release hands off to cancellation",
       ctx do
    {:ok, {:started, admission}} = Goal.idle(ctx.goal, 1)
    binding = bind(ctx.goal, admission.run_id)
    start = event(binding, :turn_started, "runtime-turn", 1)
    assert :released = Host.release(ctx.host, admission)
    Agent.update(ctx.gate, fn _ -> true end)
    assert {:error, %Error{class: :execution_failure}} = Goal.committed(ctx.goal, start)

    assert {:ok, {:not_withdrawn, :started}} =
             Goal.withdraw_admission(ctx.goal, admission, :cancelled)

    Agent.update(ctx.gate, fn _ -> false end)
    assert {:ok, _} = Goal.committed(ctx.goal, start)

    assert {:ok, _} =
             Goal.committed(
               ctx.goal,
               event(binding, :turn_aborted, "runtime-turn", 2, %{reason: :interrupted})
             )

    assert :sys.get_state(ctx.goal).reserved == nil
    assert {:ok, {:not_submitted, :deferred}} = Goal.idle(ctx.goal, 2)
  end

  test "old start and terminal receipts cannot release a new token with reused run identity",
       ctx do
    {:ok, {:started, _admission}} = Goal.idle(ctx.goal, 1)
    binding = bind(ctx.goal, "reserved-run")
    start = event(binding, :turn_started, "old-runtime-turn", 1)
    terminal = event(binding, :turn_stopped, "old-runtime-turn", 2)
    assert {:ok, _} = Goal.committed(ctx.goal, start)
    assert {:ok, _} = Goal.committed(ctx.goal, terminal)
    Agent.update(ctx.host, &%{&1 | reserved: nil, phase: nil})
    {:ok, {:started, next}} = Goal.idle(ctx.goal, 1)
    assert {:ok, _} = Goal.committed(ctx.goal, start)
    assert {:ok, _} = Goal.committed(ctx.goal, terminal)
    assert {:ok, {:not_submitted, :already_reserved}} = Goal.idle(ctx.goal, 1)
    assert :fenced = Host.fence(ctx.host, next)
    assert {:ok, {:withdrawn, :superseded}} = Goal.withdraw_admission(ctx.goal, next, :superseded)
  end

  test "cancellation retains unrelated bindings, accounting, pending receipts and active clock",
       ctx do
    binding = bind(ctx.goal, "unrelated")
    assert {:ok, _} = Goal.committed(ctx.goal, event(binding, :turn_started, "unrelated-turn", 1))

    usage = %{
      identity: "usage-1",
      attempt_id: "attempt",
      input_tokens: 7,
      cached_tokens: 2,
      output_tokens: 3
    }

    assert {:ok, _} = Goal.committed(ctx.goal, event(binding, :usage, "unrelated-turn", 2, usage))
    {:ok, {:started, admission}} = Goal.idle(ctx.goal, 1)
    Agent.update(ctx.gate, fn _ -> true end)
    pending = event(binding, :usage, "unrelated-turn", 3, %{usage | identity: "usage-2"})
    assert {:error, %Error{class: :execution_failure}} = Goal.committed(ctx.goal, pending)
    before = :sys.get_state(ctx.goal)
    assert :fenced = Host.fence(ctx.host, admission)

    assert {:error, %Error{class: :execution_failure}} =
             Goal.withdraw_admission(ctx.goal, admission, :cancelled)

    assert :sys.get_state(ctx.goal).reserved == admission
    Agent.update(ctx.gate, fn _ -> false end)

    assert {:ok, {:withdrawn, :cancelled}} =
             Goal.withdraw_admission(ctx.goal, admission, :cancelled)

    after_withdrawal = :sys.get_state(ctx.goal)
    assert after_withdrawal.bindings == before.bindings
    assert after_withdrawal.pending_receipts == before.pending_receipts
    assert after_withdrawal.record.receipts == before.record.receipts
    assert after_withdrawal.record.goal.tokens_used == 8

    for key <- [:turns, :usage, :baselines, :usage_baselines, :failure_turns, :empty_turns] do
      assert after_withdrawal.record[key] == before.record[key]
    end

    assert after_withdrawal.record.goal.time_used_seconds >= before.record.goal.time_used_seconds
    assert {:ok, _} = Goal.attribution(ctx.goal, binding)
    assert {:ok, _} = Goal.committed(ctx.goal, pending)
    assert :sys.get_state(ctx.goal).pending_receipts == MapSet.new()
  end

  test "rejected stale Goal start receipt cannot claim that a reservation was released", ctx do
    {:ok, {:started, admission}} = Goal.idle(ctx.goal, 1)
    binding = bind(ctx.goal, admission.run_id)

    stale = %{
      event(binding, :turn_started, "stale-runtime-turn", 1)
      | expected_goal_id: "old-goal"
    }

    assert {:error, %Error{class: :resource_conflict}} = Goal.committed(ctx.goal, stale)
    assert :fenced = Host.fence(ctx.host, admission)

    assert {:ok, {:withdrawn, :superseded}} =
             Goal.withdraw_admission(ctx.goal, admission, :superseded)
  end

  defp bind(goal, run_id) do
    {:ok, binding} =
      Goal.bind(goal, %{
        thread_id: "thread",
        run_id: run_id,
        incarnation: 1,
        authority: %{run_id: run_id},
        usage_authoritative: true
      })

    binding
  end

  defp event(binding, type, turn, revision, payload \\ %{}) do
    %{
      binding: binding,
      receipt_id: "#{binding.run_id}:#{type}:#{revision}",
      revision: revision,
      thread_id: "thread",
      run_id: binding.run_id,
      incarnation: binding.incarnation,
      turn_id: turn,
      expected_goal_id: binding.expected_goal_id,
      type: type,
      payload: payload
    }
  end

  defp start_released_conversation(ctx, admission) do
    binding = bind(ctx.goal, admission.run_id)

    {:ok, registry} =
      ToolRegistry.register(%ToolRegistry{}, %{
        tool_name: "effect",
        tool_revision: 1,
        policy_revision: 1,
        schema: %{type: "object"},
        scope: %{},
        policy: %{},
        safety: %{
          read_only: false,
          retry_safe: false,
          parallel_safe: false,
          requires_approval: false
        },
        backend: Backend,
        backend_context: %{test: self()}
      })

    {:ok, store} = EphemeralStore.new(1)

    pid =
      start_supervised!(
        {Conversation,
         run_id: admission.run_id,
         store: EphemeralStore,
         context: store,
         provider: Provider,
         provider_context: %{test: self()},
         hooks: Hooks,
         hook_context: %{test: self()},
         registry: registry,
         authority: %{
           caller: "host",
           run_id: admission.run_id,
           grants: ["effect"],
           tool_revision: 1
         },
         subscriber: self(),
         goal: ctx.goal,
         goal_binding: binding,
         thread_id: "thread",
         goal_trigger: :goal}
      )

    assert {:ok, _} = Conversation.prompt(pid, "continue")
    pid
  end
end

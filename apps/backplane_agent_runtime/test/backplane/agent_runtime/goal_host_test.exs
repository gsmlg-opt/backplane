Code.require_file("../../fixtures/goal_file_store.exs", __DIR__)

defmodule Backplane.AgentRuntime.GoalHostTest do
  use ExUnit.Case, async: false
  alias Backplane.AgentRuntime.{Goal, Error, GoalFileStore}

  defmodule Host do
    @behaviour Backplane.AgentRuntime.Goal.Host
    def record_user_instruction(%{agent: pid}, thread, instruction),
      do: record_user_instruction(pid, thread, instruction)

    def record_user_instruction(pid, thread, instruction) do
      Agent.get(pid, fn state ->
        if state[:fail_provenance],
          do: {:error, Error.new(:execution_failure, "provenance failed")},
          else: send(state.owner, {:instruction, thread, instruction}) && :ok
      end)
    end

    def start_turn_if_idle(%{ack: admission}, _, _), do: {:ok, {:started, admission}}

    def start_turn_if_idle(%{agent: pid, latch: {observer, token}}, thread, request) do
      send(observer, {:goal_admission_waiting, self(), token})

      receive do
        {:release_goal_admission, ^token} -> start_turn_if_idle(pid, thread, request)
      after
        4_000 -> raise "goal fixture admission latch not released"
      end
    end

    def start_turn_if_idle(pid, thread, request) do
      Agent.get_and_update(pid, fn state ->
        if state.busy or request.host_generation != state.generation do
          {{:ok, {:not_submitted, :busy}}, state}
        else
          send(state.owner, {:admission, thread, request})

          {{:ok, {:started, %{run_id: "auto-run", turn_id: "auto-turn", incarnation: 1}}},
           %{state | busy: true}}
        end
      end)
    end
  end

  defp owner_loop(goal) do
    receive do
      {:call, caller, ref, operation, args} ->
        result = apply(Goal, operation, [goal | args])
        send(caller, {ref, result})
        owner_loop(goal)

      :stop ->
        GenServer.stop(goal)
    end
  end

  defp request(owner, operation, args) do
    ref = make_ref()
    send(owner, {:call, self(), ref, operation, args})
    ref
  end

  defp start_owner(opts) do
    observer = self()

    owner =
      spawn_link(fn ->
        {:ok, goal} = Goal.start_link(Keyword.put(opts, :owner_pid, self()))
        send(observer, {:goal_owner_ready, self(), goal})
        owner_loop(goal)
      end)

    receive do
      {:goal_owner_ready, ^owner, goal} -> {owner, goal}
    end
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "goal-owner-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, store} = GoalFileStore.start_link(dir)
    {:ok, host} = Agent.start_link(fn -> %{owner: self(), busy: false, generation: 1} end)
    owner = self()
    Agent.update(host, &%{&1 | owner: owner})

    opts = [
      thread_id: "thread",
      owner_pid: self(),
      store: GoalFileStore,
      store_context: store,
      host: Host,
      host_context: host
    ]

    {:ok, goal} = Goal.start_link(opts)

    on_exit(fn ->
      for pid <- [goal, host, store], Process.alive?(pid), do: GenServer.stop(pid)
    end)

    %{goal: goal, host: host, store: store, dir: dir, opts: opts}
  end

  test "provenance precedes mutation and failed provenance leaves state unchanged", ctx do
    assert {:ok, %{goal: %{objective: "ship"}}} =
             Goal.set(ctx.goal, %{objective: "ship"}, %{text: "please ship"})

    assert_receive {:instruction, "thread", %{text: "please ship"}}
    Agent.update(ctx.host, &Map.put(&1, :fail_provenance, true))
    assert {:error, _} = Goal.clear(ctx.goal, %{text: "clear"})
    assert {:ok, %{goal: %{objective: "ship"}}} = Goal.get(ctx.goal)
  end

  test "binding authorizes committed tools and cached mutation survives goal owner restart",
       ctx do
    attrs = %{
      thread_id: "thread",
      run_id: "run",
      incarnation: 1,
      authority: %{run_id: "run"},
      mode: :execution
    }

    assert {:ok, binding} = Goal.bind(ctx.goal, attrs)

    operation = %{
      tool_name: "create_goal",
      arguments: %{objective: "ship"},
      invocation_id: "run:1:tool:1",
      backend_context: %{goal_binding: binding},
      run_id: "run",
      incarnation: 1
    }

    assert {:ok, first} = Goal.tool(ctx.goal, operation)
    assert {:ok, ^first} = Goal.tool(ctx.goal, operation)

    assert {:error, %{class: :resource_conflict}} =
             Goal.tool(ctx.goal, %{operation | arguments: %{objective: "changed"}})

    GenServer.stop(ctx.goal)
    {:ok, goal} = Goal.start_link(ctx.opts)
    {:ok, binding} = Goal.bind(goal, attrs)

    assert {:ok, ^first} =
             Goal.tool(goal, put_in(operation.backend_context.goal_binding, binding))

    assert {:ok, snapshot} = Goal.snapshot(goal)
    assert snapshot.goal.goal_id
    GenServer.stop(goal)
  end

  test "idle admission is serialized and interruption defers durable continuation", ctx do
    {:ok, _} = Goal.set(ctx.goal, %{objective: "ship"}, %{text: "ship"})
    assert {:ok, {:started, _}} = Goal.idle(ctx.goal, 1)
    assert_receive {:admission, "thread", %{expected_goal_id: id, trigger: :goal}}
    assert {:ok, {:not_submitted, _}} = Goal.idle(ctx.goal, 1)

    {:ok, binding} =
      Goal.bind(ctx.goal, %{
        thread_id: "thread",
        run_id: "auto-run",
        incarnation: 1,
        authority: %{run_id: "auto-run"}
      })

    event = %{
      receipt_id: "abort",
      revision: 1,
      thread_id: "thread",
      run_id: "auto-run",
      incarnation: 1,
      turn_id: "auto-turn",
      expected_goal_id: id,
      type: :turn_aborted,
      payload: %{reason: :interrupt_turn},
      binding: binding
    }

    assert {:ok, _} = Goal.committed(ctx.goal, event)
    Agent.update(ctx.host, &%{&1 | busy: false})
    assert {:ok, {:not_submitted, :deferred}} = Goal.idle(ctx.goal, 1)
    assert {:ok, _} = Goal.restore(ctx.goal)
    assert {:ok, {:not_submitted, :deferred}} = Goal.idle(ctx.goal, 1)
  end

  test "foreign binding and stale revision are refused; unbind revokes authority", ctx do
    {:ok, _} = Goal.set(ctx.goal, %{objective: "ship"}, %{text: "ship"})

    assert {:error, %{class: :forbidden}} =
             Task.async(fn ->
               Goal.bind(ctx.goal, %{
                 thread_id: "thread",
                 run_id: "r",
                 incarnation: 1,
                 authority: %{run_id: "r"}
               })
             end)
             |> Task.await()

    {:ok, binding} =
      Goal.bind(ctx.goal, %{
        thread_id: "thread",
        run_id: "r",
        incarnation: 1,
        authority: %{run_id: "r"}
      })

    assert {:ok, _} = Goal.unbind(ctx.goal, binding)

    assert {:error, %{class: :forbidden}} =
             Goal.tool(ctx.goal, %{binding: binding, name: :get_goal})
  end

  test "descendant authority is delegated from captured goal identity and fork copies only snapshot",
       ctx do
    {:ok, _} = Goal.set(ctx.goal, %{objective: "ship"}, %{text: "ship"})

    {:ok, root} =
      Goal.bind(ctx.goal, %{
        thread_id: "thread",
        run_id: "root",
        incarnation: 1,
        authority: %{run_id: "root"}
      })

    assert {:error, %{class: :forbidden}} =
             Goal.bind(ctx.goal, %{
               thread_id: "thread",
               run_id: "bad",
               incarnation: 1,
               authority: %{run_id: "other"}
             })

    assert {:ok, child} =
             Goal.delegate(ctx.goal, root, %{
               thread_id: "child",
               run_id: "child-run",
               incarnation: 2,
               authority: %{run_id: "child-run"}
             })

    event = %{
      receipt_id: "child-usage",
      revision: 1,
      thread_id: "child",
      run_id: "child-run",
      incarnation: 2,
      turn_id: "child-turn",
      expected_goal_id: root.expected_goal_id,
      type: :usage,
      payload: %{
        attempt_id: "a",
        identity: "u",
        input_tokens: 8,
        cached_tokens: 2,
        output_tokens: 1
      },
      binding: child
    }

    assert {:ok, %{response: %{goal: %{tokens_used: 7}}}} = Goal.committed(ctx.goal, event)
    assert {:ok, %{response: %{goal: %{tokens_used: 7}}}} = Goal.committed(ctx.goal, event)
    assert {:ok, fork} = Goal.fork_snapshot(ctx.goal, "fork")
    assert fork.goal.goal_id == root.expected_goal_id
    assert fork.goal.tokens_used == 7
    assert fork.receipts == %{}
    assert fork.turns == %{}
    assert {:ok, _} = Goal.unbind(ctx.goal, root)

    assert {:error, %{class: :forbidden}} =
             Goal.delegate(ctx.goal, root, %{
               thread_id: "child2",
               run_id: "child2",
               incarnation: 1,
               authority: %{run_id: "child2"}
             })
  end

  test "late old receipts and tools never mutate replacement; budget steering is once", ctx do
    {:ok, _} =
      Goal.set(ctx.goal, %{objective: "ship", token_budget: 10}, %{text: "ship within 10 tokens"})

    attrs = %{
      thread_id: "thread",
      run_id: "run",
      incarnation: 1,
      authority: %{run_id: "run"},
      usage_authoritative: true
    }

    {:ok, binding} = Goal.bind(ctx.goal, attrs)

    event = %{
      receipt_id: "usage",
      revision: 2,
      thread_id: "thread",
      run_id: "run",
      incarnation: 1,
      turn_id: "turn",
      expected_goal_id: binding.expected_goal_id,
      type: :usage,
      payload: %{
        identity: "u",
        attempt_id: "a",
        input_tokens: 10,
        cached_tokens: 0,
        output_tokens: 1
      },
      binding: binding
    }

    assert {:ok, %{steering: %{source: :goal}} = delivered} = Goal.committed(ctx.goal, event)
    assert {:ok, ^delivered} = Goal.committed(ctx.goal, event)

    assert {:error, %{class: :resource_conflict}} =
             Goal.committed(ctx.goal, %{event | receipt_id: "stale", revision: 1})

    assert {:ok, _} =
             Goal.tool(ctx.goal, %{
               binding: binding,
               name: :update_goal,
               invocation_id: "complete",
               arguments: %{status: :complete}
             })

    assert {:ok, _} =
             Goal.tool(ctx.goal, %{
               binding: binding,
               name: :create_goal,
               invocation_id: "new",
               arguments: %{objective: "new"}
             })

    assert {:error, %{class: :resource_conflict}} =
             Goal.tool(ctx.goal, %{
               binding: binding,
               name: :update_goal,
               invocation_id: "old-status",
               arguments: %{status: :complete}
             })

    assert {:error, %{class: :resource_conflict}} =
             Goal.committed(ctx.goal, %{event | receipt_id: "late"})

    assert {:ok, refreshed} = Goal.attribution(ctx.goal, binding)
    refute refreshed.expected_goal_id == binding.expected_goal_id
  end

  test "committed goal, receipts and deferral survive both owners restarting", ctx do
    {:ok, _} = Goal.set(ctx.goal, %{objective: "ship"}, %{text: "ship"})

    {:ok, binding} =
      Goal.bind(ctx.goal, %{
        thread_id: "thread",
        run_id: "run",
        incarnation: 1,
        authority: %{run_id: "run"}
      })

    event = %{
      receipt_id: "persisted-abort",
      revision: 1,
      thread_id: "thread",
      run_id: "run",
      incarnation: 1,
      turn_id: "turn",
      expected_goal_id: binding.expected_goal_id,
      type: :turn_aborted,
      payload: %{reason: :interrupt_turn},
      binding: binding
    }

    assert {:ok, result} = Goal.committed(ctx.goal, event)
    {:ok, before} = Goal.snapshot(ctx.goal)
    GenServer.stop(ctx.goal)
    GenServer.stop(ctx.store)
    {:ok, store} = GoalFileStore.start_link(ctx.dir)
    {:ok, goal} = Goal.start_link(Keyword.put(ctx.opts, :store_context, store))
    assert {:ok, ^before} = Goal.snapshot(goal)

    {:ok, binding} =
      Goal.bind(goal, %{
        thread_id: "thread",
        run_id: "run",
        incarnation: 1,
        authority: %{run_id: "run"}
      })

    assert {:ok, ^result} = Goal.committed(goal, %{event | binding: binding})
    assert {:ok, {:not_submitted, :deferred}} = Goal.idle(goal, 1)
    GenServer.stop(goal)
    GenServer.stop(store)
  end

  test "owner death closes live admission capabilities", ctx do
    {:ok, owner} = Agent.start(fn -> nil end)
    {:ok, goal} = Goal.start_link(Keyword.put(ctx.opts, :owner_pid, owner))
    ref = Process.monitor(goal)
    GenServer.stop(owner)
    assert_receive {:DOWN, ^ref, :process, ^goal, :normal}
  end

  test "host budget maximum survives loading an empty durable record", ctx do
    {:ok, goal} = Goal.start_link(Keyword.put(ctx.opts, :max_goal_token_budget, 20))

    assert {:error, %{class: :validation}} =
             Goal.set(goal, %{objective: "ship", token_budget: 21}, %{text: "ship"})

    assert {:ok, _} = Goal.set(goal, %{objective: "ship", token_budget: 20}, %{text: "ship"})
    GenServer.stop(goal)
  end

  test "elapsed accounting uses fresh clocks and stops after pause", ctx do
    {:ok, _} = Goal.set(ctx.goal, %{objective: "ship"}, %{text: "ship"})

    {:ok, binding} =
      Goal.bind(ctx.goal, %{
        thread_id: "thread",
        run_id: "run",
        incarnation: 1,
        authority: %{run_id: "run"}
      })

    :sys.replace_state(ctx.goal, fn state ->
      %{state | monotonic: System.monotonic_time(:millisecond) - 1250}
    end)

    {:ok, response} =
      Goal.tool(ctx.goal, %{
        binding: binding,
        name: :update_goal,
        invocation_id: "pause",
        arguments: %{status: :paused}
      })

    assert response.goal.time_used_seconds == 1

    :sys.replace_state(ctx.goal, fn state ->
      %{state | monotonic: System.monotonic_time(:millisecond) - 2250}
    end)

    {:ok, response} = Goal.set(ctx.goal, %{objective: "still ship"}, %{text: "rename objective"})
    assert response.goal.time_used_seconds == 1
    {:ok, snapshot} = Goal.snapshot(ctx.goal)
    refute Map.has_key?(snapshot, :monotonic)
    assert {:ok, _} = Goal.restore(ctx.goal)
    {:ok, snapshot} = Goal.snapshot(ctx.goal)
    assert snapshot.goal.time_used_seconds == 1
  end

  test "active idle elapsed persists and pause plus restore starts fresh", ctx do
    {:ok, _} = Goal.set(ctx.goal, %{objective: "ship"}, %{text: "ship"})
    :sys.replace_state(ctx.goal, &%{&1 | monotonic: System.monotonic_time(:millisecond) - 1250})

    assert {:ok, %{goal: %{time_used_seconds: 1}}} =
             Goal.set(ctx.goal, %{status: :paused}, %{text: "pause"})

    :sys.replace_state(ctx.goal, &%{&1 | monotonic: System.monotonic_time(:millisecond) - 2250})

    assert {:ok, %{goal: %{time_used_seconds: 1}}} =
             Goal.set(ctx.goal, %{status: :active}, %{text: "resume"})

    assert {:ok, _} = Goal.restore(ctx.goal)
    :sys.replace_state(ctx.goal, &%{&1 | monotonic: System.monotonic_time(:millisecond) - 1800})

    assert {:ok, %{goal: %{time_used_seconds: 2}}} =
             Goal.set(ctx.goal, %{status: :paused}, %{text: "pause again"})

    {:ok, snapshot} = Goal.snapshot(ctx.goal)
    refute Map.has_key?(snapshot, :monotonic)
  end

  test "plan binding excludes elapsed and descendants inherit immutable plan mode", ctx do
    {:ok, _} = Goal.set(ctx.goal, %{objective: "ship"}, %{text: "ship"})

    {:ok, plan} =
      Goal.bind(ctx.goal, %{
        thread_id: "thread",
        run_id: "plan",
        incarnation: 1,
        authority: %{run_id: "plan"},
        mode: :plan
      })

    {:ok, child} =
      Goal.delegate(ctx.goal, plan, %{
        thread_id: "child",
        run_id: "child",
        incarnation: 1,
        authority: %{run_id: "child"},
        mode: :execution
      })

    assert child.mode == :plan
    :sys.replace_state(ctx.goal, &%{&1 | monotonic: System.monotonic_time(:millisecond) - 2250})

    assert {:ok, %{goal: %{time_used_seconds: 0}}} =
             Goal.set(ctx.goal, %{objective: "ship after planning"}, %{text: "rename"})

    assert {:ok, _} = Goal.unbind(ctx.goal, plan)
    assert {:ok, _} = Goal.unbind(ctx.goal, child)
    :sys.replace_state(ctx.goal, &%{&1 | monotonic: System.monotonic_time(:millisecond) - 1250})

    assert {:ok, %{goal: %{time_used_seconds: 1}}} =
             Goal.set(ctx.goal, %{status: :paused}, %{text: "pause"})
  end

  test "plan entry and exit discard the plan interval without losing persisted idle time", ctx do
    {:ok, _} = Goal.set(ctx.goal, %{objective: "ship"}, %{text: "ship"})
    :sys.replace_state(ctx.goal, &%{&1 | monotonic: System.monotonic_time(:millisecond) - 1250})

    assert {:ok, %{goal: %{time_used_seconds: 1}}} =
             Goal.set(ctx.goal, %{objective: "ship soon"}, %{text: "ship soon"})

    {:ok, plan} =
      Goal.bind(ctx.goal, %{
        thread_id: "thread",
        run_id: "plan",
        incarnation: 1,
        authority: %{run_id: "plan"},
        mode: :plan
      })

    assert {:ok, %{goal: %{time_used_seconds: 1}}} =
             Goal.set(ctx.goal, %{objective: "planning"}, %{text: "planning"})

    :sys.replace_state(ctx.goal, &%{&1 | monotonic: System.monotonic_time(:millisecond) - 2250})
    assert {:ok, _} = Goal.unbind(ctx.goal, plan)

    assert {:ok, %{goal: %{time_used_seconds: 1}}} =
             Goal.set(ctx.goal, %{status: :paused}, %{text: "pause"})
  end

  test "model budget creation requires authoritative usage before mutation", ctx do
    {:ok, binding} =
      Goal.bind(ctx.goal, %{
        thread_id: "thread",
        run_id: "run",
        incarnation: 1,
        authority: %{run_id: "run"}
      })

    operation = %{
      binding: binding,
      name: :create_goal,
      invocation_id: "budget",
      arguments: %{objective: "ship", token_budget: 20}
    }

    assert {:error, %{class: :unsupported_capability}} = Goal.tool(ctx.goal, operation)
    assert {:ok, %{goal: nil}} = Goal.get(ctx.goal)
  end

  test "host set and clear never target a replacement after CAS conflict reload", ctx do
    {:ok, _} = Goal.set(ctx.goal, %{objective: "old"}, %{text: "old"})
    {:ok, snapshot} = Goal.snapshot(ctx.goal)

    {:ok, complete} =
      Backplane.AgentRuntime.Goal.State.update(snapshot, :host, %{status: :complete})

    {:ok, replacement} = Backplane.AgentRuntime.Goal.State.create(complete, %{objective: "new"})
    :ok = GoalFileStore.replace_on_next_cas(ctx.store, "thread", replacement)

    assert {:error, %{class: :resource_conflict}} =
             Goal.set(ctx.goal, %{status: :paused}, %{text: "pause old"})

    assert {:ok, %{goal: %{objective: "new", status: :active}}} = Goal.get(ctx.goal)
    {:ok, snapshot} = Goal.snapshot(ctx.goal)

    {:ok, complete} =
      Backplane.AgentRuntime.Goal.State.update(snapshot, :host, %{status: :complete})

    {:ok, replacement} = Backplane.AgentRuntime.Goal.State.create(complete, %{objective: "newer"})
    :ok = GoalFileStore.replace_on_next_cas(ctx.store, "thread", replacement)
    assert {:error, %{class: :resource_conflict}} = Goal.clear(ctx.goal, %{text: "clear new"})
    assert {:ok, %{goal: %{objective: "newer"}}} = Goal.get(ctx.goal)
  end

  test "model create never replaces a different completed goal after CAS reload", ctx do
    {:ok, _} = Goal.set(ctx.goal, %{objective: "old", status: :complete}, %{text: "old"})
    {:ok, _} = Goal.set(ctx.goal, %{status: :complete}, %{text: "completed"})

    {:ok, binding} =
      Goal.bind(ctx.goal, %{
        thread_id: "thread",
        run_id: "run",
        incarnation: 1,
        authority: %{run_id: "run"}
      })

    {:ok, snapshot} = Goal.snapshot(ctx.goal)
    {:ok, replacement} = Backplane.AgentRuntime.Goal.State.create(snapshot, %{objective: "other"})

    {:ok, replacement} =
      Backplane.AgentRuntime.Goal.State.update(replacement, :host, %{status: :complete})

    :ok = GoalFileStore.replace_on_next_cas(ctx.store, "thread", replacement)

    assert {:error, %{class: :resource_conflict}} =
             Goal.tool(ctx.goal, %{
               binding: binding,
               name: :create_goal,
               invocation_id: "create",
               arguments: %{objective: "planned"}
             })

    assert {:ok, %{goal: %{objective: "other", status: :complete}}} = Goal.get(ctx.goal)
  end

  test "delayed store acknowledgement prevents admission before committed mutation", ctx do
    {owner, goal} = start_owner(ctx.opts)
    token = GoalFileStore.delay_next_cas(ctx.store, self())
    set_ref = request(owner, :set, [%{objective: "ship"}, %{text: "ship"}])
    assert_receive {:goal_cas_waiting, store, ^token}
    idle_ref = request(owner, :idle, [1])
    refute_receive {^set_ref, _}, 10
    refute_receive {:admission, _, _}, 10
    send(store, {:release_goal_cas, token})
    assert_receive {^set_ref, {:ok, %{goal: %{objective: "ship"}}}}
    assert_receive {^idle_ref, {:ok, {:started, _}}}
    assert_receive {:admission, "thread", %{expected_goal_id: goal_id, goal_revision: 1}}
    assert {:ok, record} = GoalFileStore.load(ctx.store, "thread")
    assert record.goal.goal_id == goal_id
    ref = Process.monitor(goal)
    send(owner, :stop)
    assert_receive {:DOWN, ^ref, :process, ^goal, :normal}
  end

  test "queued user input invalidates generation while admission reservation is delayed", ctx do
    token = make_ref()
    opts = Keyword.put(ctx.opts, :host_context, %{agent: ctx.host, latch: {self(), token}})
    {owner, goal} = start_owner(opts)
    ref = request(owner, :set, [%{objective: "ship"}, %{text: "ship"}])
    assert_receive {^ref, {:ok, _}}
    idle_ref = request(owner, :idle, [1])
    assert_receive {:goal_admission_waiting, admission_owner, ^token}
    Agent.update(ctx.host, &%{&1 | generation: 2})
    clear_ref = request(owner, :clear, [%{text: "stop"}])
    send(admission_owner, {:release_goal_admission, token})
    assert_receive {^idle_ref, {:ok, {:not_submitted, :busy}}}
    assert_receive {^clear_ref, {:ok, %{goal: nil}}}
    refute_receive {:admission, _, _}, 10
    ref = Process.monitor(goal)
    send(owner, :stop)
    assert_receive {:DOWN, ^ref, :process, ^goal, :normal}
  end

  test "abort delivered before reservation acknowledgement defers the reserved turn", ctx do
    token = make_ref()
    opts = Keyword.put(ctx.opts, :host_context, %{agent: ctx.host, latch: {self(), token}})
    {owner, goal} = start_owner(opts)
    ref = request(owner, :set, [%{objective: "ship"}, %{text: "ship"}])
    assert_receive {^ref, {:ok, _}}

    ref =
      request(owner, :bind, [
        %{
          thread_id: "thread",
          run_id: "auto-run",
          incarnation: 1,
          authority: %{run_id: "auto-run"}
        }
      ])

    assert_receive {^ref, {:ok, binding}}
    idle_ref = request(owner, :idle, [1])
    assert_receive {:goal_admission_waiting, admission_owner, ^token}

    event = %{
      receipt_id: "early-abort",
      revision: 1,
      thread_id: "thread",
      run_id: "auto-run",
      incarnation: 1,
      turn_id: "auto-turn",
      expected_goal_id: binding.expected_goal_id,
      type: :turn_aborted,
      payload: %{reason: :interrupt_turn},
      binding: binding
    }

    event = %{event | revision: 2}

    started = %{
      event
      | receipt_id: "early-start",
        revision: 1,
        type: :turn_started,
        payload: %{trigger: :user}
    }

    abort =
      Task.async(fn ->
        {:ok, _} = Goal.committed(goal, started)
        Goal.committed(goal, event)
      end)

    send(admission_owner, {:release_goal_admission, token})
    assert_receive {^idle_ref, {:ok, {:started, _}}}
    assert {:ok, _} = Task.await(abort)
    ref = request(owner, :idle, [1])
    assert_receive {^ref, {:ok, {:not_submitted, :deferred}}}
    snapshot_ref = request(owner, :snapshot, [])
    assert_receive {^snapshot_ref, {:ok, %{empty_turns: 1}}}
    ref = Process.monitor(goal)
    send(owner, :stop)
    assert_receive {:DOWN, ^ref, :process, ^goal, :normal}
  end

  test "foreign idle cannot consume interrupted accounting", ctx do
    {:ok, _} = Goal.set(ctx.goal, %{objective: "ship"}, %{text: "ship"})

    {:ok, binding} =
      Goal.bind(ctx.goal, %{
        thread_id: "thread",
        run_id: "run",
        incarnation: 1,
        authority: %{run_id: "run"}
      })

    event = %{
      receipt_id: "foreign-abort",
      revision: 1,
      thread_id: "thread",
      run_id: "run",
      incarnation: 1,
      turn_id: "turn",
      expected_goal_id: binding.expected_goal_id,
      type: :turn_aborted,
      payload: %{reason: :interrupt_turn},
      binding: binding
    }

    {:ok, _} = Goal.committed(ctx.goal, event)
    {:ok, before} = Goal.snapshot(ctx.goal)

    assert {:error, %{class: :forbidden}} =
             Task.async(fn -> Goal.idle(ctx.goal, 1) end) |> Task.await()

    assert {:ok, ^before} = Goal.snapshot(ctx.goal)
  end

  test "fork omits source-run interruption deferral and runtime audit counters", ctx do
    {:ok, _} = Goal.set(ctx.goal, %{objective: "ship"}, %{text: "ship"})

    {:ok, binding} =
      Goal.bind(ctx.goal, %{
        thread_id: "thread",
        run_id: "run",
        incarnation: 1,
        authority: %{run_id: "run"}
      })

    event = %{
      receipt_id: "fork-abort",
      revision: 1,
      thread_id: "thread",
      run_id: "run",
      incarnation: 1,
      turn_id: "turn",
      expected_goal_id: binding.expected_goal_id,
      type: :turn_aborted,
      payload: %{reason: :interrupt_turn},
      binding: binding
    }

    {:ok, _} = Goal.committed(ctx.goal, event)
    {:ok, fork} = Goal.fork_snapshot(ctx.goal, "fork-interrupted")
    assert fork.goal.goal_id == binding.expected_goal_id
    assert fork.continuation_deferral == nil
    assert fork.interrupted_turn == nil
    assert fork.failure_turns == 0
    assert fork.empty_turns == 0
  end

  test "unavailable store refuses accounting without changing status or debiting usage", ctx do
    {:ok, _} = Goal.set(ctx.goal, %{objective: "ship"}, %{text: "ship"})

    {:ok, binding} =
      Goal.bind(ctx.goal, %{
        thread_id: "thread",
        run_id: "run",
        incarnation: 1,
        authority: %{run_id: "run"}
      })

    event = %{
      receipt_id: "no-store",
      revision: 1,
      thread_id: "thread",
      run_id: "run",
      incarnation: 1,
      turn_id: "turn",
      expected_goal_id: binding.expected_goal_id,
      type: :usage,
      payload: %{
        identity: "u",
        attempt_id: "a",
        input_tokens: 2,
        cached_tokens: 0,
        output_tokens: 1
      },
      binding: binding
    }

    GenServer.stop(ctx.store)
    assert {:error, %{class: :execution_failure}} = Goal.committed(ctx.goal, event)
    assert {:ok, {:not_submitted, :accounting_pending}} = Goal.idle(ctx.goal, 1)
    assert {:ok, %{goal: %{tokens_used: 0, status: :active}}} = Goal.get(ctx.goal)
  end

  test "unavailable host refuses continuation without changing goal status", ctx do
    {:ok, _} = Goal.set(ctx.goal, %{objective: "ship"}, %{text: "ship"})
    GenServer.stop(ctx.host)
    assert {:error, %{class: :execution_failure}} = Goal.idle(ctx.goal, 1)
    assert {:ok, %{goal: %{status: :active}}} = Goal.get(ctx.goal)
  end

  test "immutable binding excludes plan usage even when a late report has no turn start", ctx do
    {:ok, _} = Goal.set(ctx.goal, %{objective: "ship"}, %{text: "ship"})

    {:ok, binding} =
      Goal.bind(ctx.goal, %{
        thread_id: "thread",
        run_id: "plan",
        incarnation: 1,
        authority: %{run_id: "plan"},
        mode: :plan
      })

    event = %{
      receipt_id: "plan-late-usage",
      revision: 1,
      thread_id: "thread",
      run_id: "plan",
      incarnation: 1,
      turn_id: "turn",
      expected_goal_id: binding.expected_goal_id,
      type: :usage,
      payload: %{
        identity: "u",
        attempt_id: "a",
        input_tokens: 2,
        cached_tokens: 0,
        output_tokens: 1,
        mode: :execution
      },
      binding: binding
    }

    assert {:ok, %{response: %{goal: %{tokens_used: 0}}}} = Goal.committed(ctx.goal, event)
  end

  test "plan lifecycle cannot block defer or audit an active goal", ctx do
    {:ok, _} = Goal.set(ctx.goal, %{objective: "ship"}, %{text: "ship"})

    {:ok, binding} =
      Goal.bind(ctx.goal, %{
        thread_id: "thread",
        run_id: "plan",
        incarnation: 1,
        authority: %{run_id: "plan"},
        mode: :plan
      })

    events = [
      {:turn_started, %{trigger: :goal}},
      {:tool_finished, %{tool: "exec", success: false, handler_executed: true}},
      {:item_completed, %{kind: :assistant, text: "", phase: :final}},
      {:turn_stopped, %{outcome: :failed}},
      {:turn_error, %{class: :usage_limit}},
      {:turn_aborted, %{reason: :interrupted}}
    ]

    Enum.with_index(events, 1)
    |> Enum.each(fn {{type, payload}, revision} ->
      assert {:ok, _} =
               Goal.committed(ctx.goal, %{
                 receipt_id: "plan-#{revision}",
                 revision: revision,
                 thread_id: "thread",
                 run_id: "plan",
                 incarnation: 1,
                 turn_id: "turn",
                 expected_goal_id: binding.expected_goal_id,
                 type: type,
                 payload: Map.put(payload, :mode, :execution),
                 binding: binding
               })
    end)

    assert {:ok, %{goal: %{status: :active, tokens_used: 0}}} = Goal.get(ctx.goal)
    assert {:ok, snapshot} = Goal.snapshot(ctx.goal)
    assert snapshot.continuation_deferral == nil
    assert snapshot.empty_turns == 0
    assert snapshot.failure_turns == 0
    assert snapshot.turns == %{}
  end

  test "host maximum remains authoritative after restore and CAS reload", ctx do
    {:ok, goal} = Goal.start_link(Keyword.put(ctx.opts, :max_goal_token_budget, 20))
    {:ok, _} = Goal.set(goal, %{objective: "ship", token_budget: 10}, %{text: "ship"})
    {:ok, persisted} = GoalFileStore.load(ctx.store, "thread")

    {:ok, _} =
      GoalFileStore.compare_and_swap(
        ctx.store,
        "thread",
        persisted.revision,
        persisted.goal.goal_id,
        %{persisted | max_goal_token_budget: nil}
      )

    {:ok, _} = Goal.restore(goal)

    assert {:error, %{class: :validation}} =
             Goal.set(goal, %{token_budget: 21}, %{text: "adjust"})

    {:ok, persisted} = Goal.snapshot(goal)

    :ok =
      GoalFileStore.replace_on_next_cas(ctx.store, "thread", %{
        persisted
        | max_goal_token_budget: 10
      })

    assert {:ok, %{goal: %{token_budget: 15}}} =
             Goal.set(goal, %{token_budget: 15}, %{text: "adjust"})

    GenServer.stop(goal)
  end

  test "malformed admission acknowledgements cannot reserve a goal turn", ctx do
    for admission <- [
          %{},
          %{run_id: "", turn_id: "t", incarnation: 1},
          %{run_id: "r", turn_id: "", incarnation: 1},
          %{run_id: "r", turn_id: "t", incarnation: 0}
        ] do
      opts = Keyword.put(ctx.opts, :host_context, %{agent: ctx.host, ack: admission})
      {:ok, goal} = Goal.start_link(opts)
      {:ok, _} = Goal.set(goal, %{objective: "ship"}, %{text: "ship"})
      assert {:error, %{class: :malformed_result}} = Goal.idle(goal, 1)
      GenServer.stop(goal)
    end
  end
end

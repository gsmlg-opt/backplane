Code.require_file("../../fixtures/goal_file_store.exs", __DIR__)

defmodule Backplane.AgentRuntime.TerminalGoalAckTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{
    Conversation,
    Error,
    Goal,
    GoalBridge,
    GoalFileStore,
    Kernel,
    Store,
    ToolRegistry
  }

  @terminal_states [:completed, :failed, :cancelled, :timed_out, :unknown_outcome]

  defmodule FileStore do
    @behaviour Store
    def mode, do: :durable

    def capabilities do
      Map.new(
        [
          :expected_revision,
          :transition_events,
          :outbox_intents,
          :recovery_records,
          :artifact_references,
          :atomic_transition_outbox,
          :incarnation_fencing
        ],
        &{&1, true}
      )
    end

    def new(_), do: {:error, Error.new(:validation, "fixture requires open/1")}
    def open(root), do: Agent.start_link(fn -> %{root: root, fault: nil} end)
    def fault(context, fault), do: Agent.update(context, &%{&1 | fault: fault})

    def load(context, run_id, _opts) do
      root = Agent.get(context, & &1.root)

      case File.read(path(root, run_id)) do
        {:ok, bytes} -> {:ok, :erlang.binary_to_term(bytes, [:safe])}
        {:error, :enoent} -> {:error, Error.new(:not_found, "run not found")}
      end
    end

    def store(context, run, meta) do
      with {:ok, staged} <- Store.stage(__MODULE__, context, run, meta),
           {:ok, result} <- acknowledge_commit(context, staged.stage, meta) do
        {:ok, Map.put(result, :outbox, staged.outbox)}
      end
    end

    def acknowledge_commit(context, stage, _meta) do
      Agent.get_and_update(context, fn state ->
        path = path(state.root, stage.run.run_id)

        current =
          case File.read(path) do
            {:ok, bytes} -> :erlang.binary_to_term(bytes, [:safe]).revision
            {:error, :enoent} -> 0
          end

        result =
          cond do
            state.fault == :reject ->
              {:error, Error.new(:execution_failure, "injected write rejection")}

            current != stage.revision - 1 ->
              {:error, Error.new(:resource_conflict, "revision conflict")}

            true ->
              snapshot =
                Map.take(stage, [:run, :revision, :transition, :effects, :outbox, :incarnation])

              :ok = File.write(path <> ".tmp", :erlang.term_to_binary(snapshot), [:binary, :sync])
              :ok = File.rename(path <> ".tmp", path)

              if state.fault == :lost_reply,
                do: {:error, Error.new(:execution_failure, "injected lost acknowledgement")},
                else: {:ok, %{revision: stage.revision}}
          end

        {result, %{state | fault: nil}}
      end)
    end

    def fence(context, run_id, expected_revision, current_incarnation, next_incarnation) do
      Agent.get(context, fn state ->
        path = path(state.root, run_id)
        snapshot = path |> File.read!() |> :erlang.binary_to_term([:safe])

        if snapshot.revision == expected_revision and
             snapshot.run.incarnation == current_incarnation do
          run = %{
            snapshot.run
            | expected_revision: expected_revision + 1,
              incarnation: next_incarnation
          }

          snapshot = %{
            snapshot
            | run: run,
              revision: run.expected_revision,
              incarnation: next_incarnation
          }

          :ok = File.write(path <> ".tmp", :erlang.term_to_binary(snapshot), [:binary, :sync])
          :ok = File.rename(path <> ".tmp", path)
          {:ok, %{revision: run.expected_revision, run: run}}
        else
          {:error, Error.new(:resource_conflict, "incarnation conflict")}
        end
      end)
    end

    defp path(root, run_id), do: Path.join(root, Base.url_encode64(run_id) <> ".term")
  end

  defmodule Host do
    @behaviour Backplane.AgentRuntime.Goal.Host
    def record_user_instruction(_, _, _), do: :ok
    def start_turn_if_idle(_, _, _), do: {:ok, {:not_submitted, :busy}}
  end

  defmodule UnexpectedProvider do
    def stream(_, owner) do
      send(owner, :provider_replayed)
      []
    end
  end

  defmodule UnexpectedTools do
    def execute(operation) do
      send(operation.backend_context.test, :tool_replayed)
      {:error, Error.new(:execution_failure, "unexpected tool execution")}
    end
  end

  defp receipt(id, attrs \\ %{}) do
    Map.merge(
      %{
        receipt_id: id,
        revision: 2,
        thread_id: "thread",
        run_id: "run",
        incarnation: 1,
        turn_id: "turn",
        expected_goal_id: "goal",
        type: :usage,
        payload: %{
          identity: id,
          attempt_id: "attempt",
          cumulative: true,
          input_tokens: 7,
          cached_tokens: 0,
          output_tokens: 3,
          reasoning_tokens: 0
        }
      },
      attrs
    )
  end

  defp run(state \\ :completed) do
    %{
      run_id: "run",
      incarnation: 2,
      expected_revision: 10,
      state: state,
      outcome: %{reason: state},
      deadline: :infinity,
      budget: %{remaining: 3},
      execution_budget: %{remaining: 2},
      tool_results: %{done: "kept"},
      active_tools: %{uncertain: %{invocation_id: "uncertain"}},
      execution_intents: %{done: %{status: :consumed}, uncertain: %{status: :unknown_outcome}},
      context: %{
        host: %{data: "kept"},
        conversation: %{
          messages: ["kept"],
          goal_outbox: [receipt("one"), receipt("two"), receipt("three")]
        }
      }
    }
  end

  defp command(run, receipts),
    do:
      {:goal_outbox_acknowledged, 20,
       %{run_id: run.run_id, incarnation: run.incarnation, receipts: receipts}}

  for state <- @terminal_states do
    test "acknowledges an exact subset in #{state} without changing other evidence" do
      run = run(unquote(state))
      [one, two, three] = run.context.conversation.goal_outbox
      assert {:ok, next, transition, []} = Kernel.execute(run, command(run, [three, one]))

      assert next ==
               put_in(run, [:context, :conversation, :goal_outbox], [two])
               |> Map.put(:expected_revision, 11)

      assert transition.expected_revision == 11
      assert transition.state == run.state
      assert [%{type: "run.goal_outbox_acknowledged", occurred_at: 20}] = transition.events
    end
  end

  test "acknowledges the full outbox" do
    run = run()

    assert {:ok, next, _, []} =
             Kernel.execute(run, command(run, run.context.conversation.goal_outbox))

    assert next.context.conversation.goal_outbox == []

    assert {:error, %Error{class: :resource_conflict}} =
             Kernel.execute(next, command(next, [receipt("one")]))
  end

  test "rejects nonterminal commands and stale current identity" do
    for state <- [:queued, :running, :waiting_approval, :waiting_result, :cancelling] do
      run = run(state)

      assert {:error, %Error{class: :validation}} =
               Kernel.execute(run, command(run, [receipt("one")]))
    end

    run = run()

    for stale <- [%{run | incarnation: 1}, %{run | run_id: "other"}] do
      assert {:error, %Error{class: :resource_conflict}} =
               Kernel.execute(run, command(stale, [receipt("one")]))
    end
  end

  test "rejects malformed command envelopes without a transition" do
    run = run()

    for malformed <- [
          {:goal_outbox_acknowledged, 20},
          {:goal_outbox_acknowledged, 20, nil},
          {:goal_outbox_acknowledged, -1,
           %{run_id: "run", incarnation: 2, receipts: [receipt("one")]}},
          {:goal_outbox_acknowledged, 20, %{incarnation: 2, receipts: [receipt("one")]}},
          {:goal_outbox_acknowledged, 20, %{run_id: "run", receipts: [receipt("one")]}}
        ] do
      assert {:error, %Error{class: :validation}} = Kernel.execute(run, malformed)
    end
  end

  test "rejects malformed, duplicate, changed and unknown receipts" do
    run = run()

    for receipts <- [
          nil,
          [],
          %{},
          [nil],
          ["one"],
          [%{}],
          [%{receipt_id: ""}],
          [%{receipt_id: nil}],
          [%{receipt_id: 1}],
          [receipt("one"), receipt("one")],
          [receipt("one", %{payload: %{input_tokens: 999}})],
          [receipt("one", %{revision: 2.0})],
          [receipt("missing")],
          [receipt("one") | :invalid_tail],
          [%{receipt_id: "one"}]
        ] do
      assert {:error, %Error{}} = Kernel.execute(run, command(run, receipts))
    end
  end

  test "rejects ambiguous retained receipt IDs and malformed outboxes" do
    run = run()

    for outbox <- [
          [receipt("one"), receipt("one")],
          [receipt("one"), receipt("one", %{payload: %{changed: true}})],
          nil,
          %{},
          [receipt("one") | :invalid_tail]
        ] do
      malformed = put_in(run, [:context, :conversation, :goal_outbox], outbox)
      assert {:error, %Error{}} = Kernel.execute(malformed, command(run, [receipt("one")]))
    end
  end

  test "caller context cannot overwrite the saved conversation" do
    run = run()
    {:goal_outbox_acknowledged, at, input} = command(run, [receipt("one")])
    input = Map.merge(input, %{context: %{}, conversation: %{goal_outbox: []}})
    assert {:ok, next, _, []} = Kernel.execute(run, {:goal_outbox_acknowledged, at, input})
    assert next.context.host == run.context.host
    assert next.context.conversation.messages == run.context.conversation.messages
    assert Enum.map(next.context.conversation.goal_outbox, & &1.receipt_id) == ["two", "three"]
  end

  @tag :tmp_dir
  test "existing staged and direct Store CAS reject stale writes and retain receipts on rejection",
       %{tmp_dir: dir} do
    context = open_store(dir)
    run = seed(context)
    meta = %{command: command(run, [receipt("one")])}
    assert {:ok, staged} = Store.stage(FileStore, context, run, meta)
    FileStore.fault(context, :reject)

    assert {:error, %Error{class: :execution_failure}} =
             Store.acknowledge_commit(FileStore, context, staged.stage, %{})

    assert {:ok, %{run: ^run}} = FileStore.load(context, run.run_id, [])
    assert {:ok, %{revision: 2}} = FileStore.store(context, run, meta)

    assert {:error, %Error{class: :resource_conflict}} =
             Store.acknowledge_commit(FileStore, context, staged.stage, %{})

    assert {:error, %Error{class: :resource_conflict}} = FileStore.store(context, run, meta)
    assert {:ok, %{run: stored, effects: []}} = FileStore.load(context, run.run_id, [])
    assert stored.context.conversation.goal_outbox == [receipt("two"), receipt("three")]
  end

  @tag :tmp_dir
  test "a Store incarnation fence preserves old receipts but rejects the old ACK writer", %{
    tmp_dir: dir
  } do
    context = open_store(dir)
    original = seed(context, %{run() | incarnation: 1})

    assert {:ok, %{revision: 2, run: fenced}} =
             Store.fence(FileStore, context, original.run_id, 1, 1, 2)

    assert {:error, %Error{class: :resource_conflict}} =
             FileStore.store(context, original, %{command: command(original, [receipt("one")])})

    assert {:error, %Error{class: :resource_conflict}} =
             Kernel.execute(fenced, command(original, [receipt("one")]))

    assert {:ok, %{revision: 3}} =
             FileStore.store(context, fenced, %{command: command(fenced, [receipt("one")])})

    assert {:ok, %{run: loaded}} = FileStore.load(context, original.run_id, [])
    assert loaded.incarnation == 2
    assert Enum.map(loaded.context.conversation.goal_outbox, & &1.incarnation) == [1, 1]
  end

  @tag :tmp_dir
  test "lost ACK reply requires reload and an already removed receipt is rejected", %{
    tmp_dir: dir
  } do
    context = open_store(dir)
    run = seed(context)
    FileStore.fault(context, :lost_reply)

    assert {:error, %Error{class: :execution_failure}} =
             FileStore.store(context, run, %{command: command(run, [receipt("one")])})

    assert {:ok, %{run: loaded}} = FileStore.load(context, run.run_id, [])
    assert loaded.expected_revision == 2
    assert loaded.context.conversation.goal_outbox == [receipt("two"), receipt("three")]

    assert {:error, %Error{class: :resource_conflict}} =
             FileStore.store(context, loaded, %{command: command(loaded, [receipt("one")])})
  end

  @tag :tmp_dir
  test "cold reopen redelivers Goal receipts twice, ACKs durably and never replays execution", %{
    tmp_dir: dir
  } do
    run_dir = Path.join(dir, "runs")
    goal_dir = Path.join(dir, "goals")
    File.mkdir_p!(run_dir)
    context = open_store(run_dir)
    {goal_store, goal} = open_goal(goal_dir)
    {:ok, _} = Goal.set(goal, %{objective: "finish", token_budget: 100}, %{text: "finish"})
    binding = bind(goal)
    delivered = receipt("usage", %{expected_goal_id: binding.expected_goal_id})
    terminal = put_in(run(:unknown_outcome), [:context, :conversation, :goal_outbox], [delivered])
    saved = seed(context, terminal)
    GenServer.stop(context)
    GenServer.stop(goal)
    GenServer.stop(goal_store)

    # Reopen both file-backed records, then repeat after both owners stop again.
    for _ <- 1..2 do
      context = open_store(run_dir)
      {goal_store, goal} = open_goal(goal_dir)
      assert {:ok, %{run: ^saved}} = FileStore.load(context, saved.run_id, [])

      assert {:ok, [%{response: %{goal: %{tokens_used: 10}}}]} =
               GoalBridge.redeliver(goal, bind(goal), saved)

      assert {:ok, snapshot} = Goal.snapshot(goal)
      assert map_size(snapshot.receipts) == 1
      assert_terminal_without_execution(saved, context)
      GenServer.stop(context)
      GenServer.stop(goal)
      GenServer.stop(goal_store)
    end

    context = open_store(run_dir)

    assert {:ok, %{revision: 2}} =
             FileStore.store(context, saved, %{command: command(saved, [delivered])})

    GenServer.stop(context)
    context = open_store(run_dir)
    {_goal_store, goal} = open_goal(goal_dir)
    assert {:ok, %{run: loaded, effects: []}} = FileStore.load(context, saved.run_id, [])

    assert loaded ==
             put_in(saved, [:context, :conversation, :goal_outbox], [])
             |> Map.put(:expected_revision, 2)

    assert {:ok, []} = GoalBridge.redeliver(goal, bind(goal), loaded)
    assert {:ok, %{goal: %{tokens_used: 10}}} = Goal.get(goal)
    assert_terminal_without_execution(loaded, context)
  end

  defp assert_terminal_without_execution(run, context) do
    {:ok, registry} =
      ToolRegistry.register(%ToolRegistry{}, %{
        tool_name: "saved-tool",
        tool_revision: 1,
        schema: %{"type" => "object"},
        safety: %{read_only: false, retry_safe: false, parallel_safe: false},
        backend: UnexpectedTools,
        backend_context: %{test: self()}
      })

    {:ok, conversation} =
      Conversation.start_link(
        run_id: run.run_id,
        run: run,
        store: FileStore,
        context: context,
        provider: UnexpectedProvider,
        provider_context: self(),
        registry: registry
      )

    assert %{phase: :terminal, run: ^run} = Conversation.status(conversation)
    assert {:error, _} = Conversation.prompt(conversation, "do not reopen")
    refute_receive :provider_replayed, 20
    refute_receive :tool_replayed, 20
    GenServer.stop(conversation)
  end

  defp open_store(dir) do
    {:ok, context} = FileStore.open(dir)
    on_exit(fn -> if Process.alive?(context), do: GenServer.stop(context) end)
    context
  end

  defp open_goal(dir) do
    {:ok, store} = GoalFileStore.start_link(dir)

    {:ok, goal} =
      Goal.start_link(
        thread_id: "thread",
        owner_pid: self(),
        store: GoalFileStore,
        store_context: store,
        host: Host,
        host_context: nil
      )

    on_exit(fn ->
      for pid <- [goal, store], Process.alive?(pid), do: GenServer.stop(pid)
    end)

    {store, goal}
  end

  defp bind(goal) do
    {:ok, binding} =
      Goal.bind(goal, %{
        thread_id: "thread",
        run_id: "run",
        incarnation: 1,
        authority: %{run_id: "run"},
        usage_authoritative: true
      })

    binding
  end

  defp seed(context, run \\ run()) do
    run = %{run | expected_revision: 0}

    stage = %{
      run: %{run | expected_revision: 1},
      revision: 1,
      transition: %{},
      effects: [],
      outbox: [],
      incarnation: run.incarnation
    }

    {:ok, _} = FileStore.acknowledge_commit(context, stage, %{})
    stage.run
  end
end

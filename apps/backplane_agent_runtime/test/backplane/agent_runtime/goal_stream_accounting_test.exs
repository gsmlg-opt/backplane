Code.require_file("../../fixtures/goal_file_store.exs", __DIR__)

defmodule Backplane.AgentRuntime.GoalStreamAccountingTest do
  use ExUnit.Case, async: false
  alias Backplane.AgentRuntime.{Conversation, EphemeralStore, Goal, GoalFileStore, ToolRegistry}
  alias Backplane.AgentRuntime.Codex.Session
  @moduletag :tmp_dir

  defmodule Host do
    def record_user_instruction(_, _, _), do: :ok

    def start_turn_if_idle(host, _thread, request) do
      Agent.get_and_update(host, fn state ->
        if request.host_generation != 1 or Session.status(state.session).phase != :idle do
          {{:ok, {:not_submitted, :busy}}, state}
        else
          run_id = "auto-#{state.count + 1}"
          authority = %{caller: "host", run_id: run_id, grants: []}
          {:ok, session_binding} = Session.bind(state.session, authority)
          send(state.test, {:admitted, authority, session_binding})

          {{:ok, {:started, %{run_id: run_id, incarnation: 1, turn_id: run_id}}},
           %{state | count: state.count + 1}}
        end
      end)
    end
  end

  defmodule Provider do
    def stream(request, context) do
      send(context.test, {:provider, request, self()})

      Stream.resource(
        fn -> 0 end,
        fn batch ->
          send(context.test, {:provider_waiting, self(), batch})

          receive do
            {:events, events} -> {events, batch + 1}
          end
        end,
        fn _ -> :ok end
      )
    end
  end

  setup ctx do
    store = start_supervised!({GoalFileStore, ctx.tmp_dir})
    session = start_supervised!({Session, owner_pid: self()})
    test = self()
    host = start_supervised!({Agent, fn -> %{test: test, session: session, count: 0} end})

    goal =
      start_supervised!(
        {Goal,
         thread_id: "stream-thread",
         owner_pid: self(),
         store: GoalFileStore,
         store_context: store,
         host: Host,
         host_context: host}
      )

    {:ok, _} = Goal.set(goal, %{objective: "ship", token_budget: 1_000}, %{text: "ship"})
    %{goal: goal, store: store, session: session}
  end

  defp start_run(ctx, run_id, opts \\ []) do
    authority = Keyword.get(opts, :authority, %{caller: "host", run_id: run_id, grants: []})

    {:ok, session_binding} =
      case Keyword.get(opts, :session_binding) do
        nil -> Session.bind(ctx.session, authority)
        binding -> {:ok, binding}
      end

    {:ok, binding} =
      Goal.bind(ctx.goal, %{
        thread_id: "stream-thread",
        run_id: run_id,
        incarnation: 1,
        authority: authority,
        usage_authoritative: true
      })

    {:ok, table} = EphemeralStore.new(1)

    pid =
      start_supervised!(
        {Conversation,
         [
           run_id: run_id,
           store: EphemeralStore,
           context: table,
           provider: Provider,
           provider_context: %{test: self()},
           subscriber: self(),
           registry: %ToolRegistry{},
           tools: [],
           authority: authority,
           goal: ctx.goal,
           goal_binding: binding,
           thread_id: "stream-thread",
           session_binding: session_binding,
           goal_trigger: Keyword.get(opts, :goal_trigger, :user),
           provider_idle_timeout: Keyword.get(opts, :provider_idle_timeout),
           run_timeout: :infinity
         ]},
        id: make_ref()
      )

    {:ok, _} = Conversation.prompt(pid, "work")
    assert_receive {:provider, %{run_id: ^run_id}, worker}, 1_000
    assert_receive {:provider_waiting, ^worker, 0}
    {pid, table, worker}
  end

  defp usage(output), do: %{input_tokens: 50, cached_tokens: 40, output_tokens: output}

  defp done(text, output),
    do: %{
      type: :response_completed,
      message: %{role: :assistant, content: text},
      usage: usage(output)
    }

  defp accept_usage(worker, output) do
    send(worker, {:events, [%{type: :usage_updated, usage: usage(output)}]})
    # Enumeration advances only after the owner's provider callback acknowledges.
    assert_receive {:provider_waiting, ^worker, 1}, 1_000
  end

  test "accepted streaming usage is durable before terminal and terminal repeats do not double debit",
       ctx do
    {pid, _, worker} = start_run(ctx, "stream")
    accept_usage(worker, 2)
    assert {:ok, snapshot} = GoalFileStore.load(ctx.store, "stream-thread")
    assert snapshot.goal.tokens_used == 12
    assert Conversation.status(pid).run.active_provider != nil
    send(worker, {:events, [done("done", 2)]})
    assert_receive {:agent_runtime, "stream", %{type: :run_completed}}, 2_000
    assert {:ok, %{goal: %{tokens_used: 12}}} = Goal.get(ctx.goal)
  end

  test "cancellation retains previously acknowledged streaming usage", ctx do
    {pid, _, worker} = start_run(ctx, "cancel-stream")
    accept_usage(worker, 2)
    :ok = Conversation.cancel(pid)
    assert_receive {:agent_runtime, "cancel-stream", %{type: :run_cancelled}}, 2_000
    assert {:ok, snapshot} = GoalFileStore.load(ctx.store, "stream-thread")
    assert snapshot.goal.tokens_used == 12
    assert snapshot.continuation_deferral != nil
  end

  test "decreasing cumulative provider usage fails before another debit", ctx do
    {_, _, worker} = start_run(ctx, "decreasing")
    accept_usage(worker, 7)
    send(worker, {:events, [%{type: :usage_updated, usage: usage(2)}]})
    assert_receive {:agent_runtime, "decreasing", %{type: :run_failed}}, 1_000
    assert {:ok, %{goal: %{tokens_used: 17, status: :blocked}}} = Goal.get(ctx.goal)
    refute_receive {:provider_waiting, ^worker, 2}, 10
  end

  test "provider failure retains previously acknowledged streaming usage", ctx do
    {_, _, worker} = start_run(ctx, "failed-stream")
    accept_usage(worker, 2)
    send(worker, {:events, [%{type: :response_failed, error: "provider unavailable"}]})
    assert_receive {:agent_runtime, "failed-stream", %{type: :run_failed}}, 2_000
    assert {:ok, snapshot} = GoalFileStore.load(ctx.store, "stream-thread")
    assert snapshot.goal.tokens_used == 12
    assert snapshot.goal.status == :blocked
  end

  test "provider idle observation excludes bounded local accounting acknowledgement", ctx do
    {pid, _, worker} = start_run(ctx, "slow-accounting", provider_idle_timeout: 50)
    token = GoalFileStore.delay_next_cas(ctx.store, self())
    send(worker, {:events, [%{type: :usage_updated, usage: usage(2)}]})
    assert_receive {:goal_cas_waiting, store, ^token}, 1_000
    on_exit(fn -> send(store, {:release_goal_cas, token}) end)
    Process.sleep(80)
    assert Process.alive?(worker)
    assert Conversation.status(pid).run.state == :running
    send(store, {:release_goal_cas, token})
    assert_receive {:provider_waiting, ^worker, 1}, 1_000
    send(worker, {:events, [done("done", 2)]})
    assert_receive {:agent_runtime, "slow-accounting", %{type: :run_completed}}, 2_000
  end

  test "host creation during an active provider starts from the last acknowledged usage baseline",
       ctx do
    {:ok, _} = Goal.clear(ctx.goal, %{text: "clear before starting"})
    {_, _, worker} = start_run(ctx, "mid-provider")
    accept_usage(worker, 2)

    {:ok, _} =
      Goal.set(ctx.goal, %{objective: "new work", token_budget: 100}, %{text: "pursue new work"})

    send(worker, {:events, [%{type: :usage_updated, usage: usage(7)}]})
    assert_receive {:provider_waiting, ^worker, 2}, 1_000
    send(worker, {:events, [%{type: :usage_updated, usage: usage(10)}]})
    assert_receive {:provider_waiting, ^worker, 3}, 1_000
    assert {:ok, snapshot} = GoalFileStore.load(ctx.store, "stream-thread")
    assert snapshot.goal.tokens_used == 8
    send(worker, {:events, [done("done", 10)]})
    assert_receive {:agent_runtime, "mid-provider", %{type: :run_completed}}, 2_000
    assert {:ok, %{goal: %{tokens_used: 8}}} = Goal.get(ctx.goal)
  end

  test "empty commentary messages do not count as empty final automatic turns", ctx do
    for _ <- 1..3 do
      assert {:ok, {:started, _}} = Goal.idle(ctx.goal, 1)
      assert_receive {:admitted, authority, session_binding}

      {_, _, worker} =
        start_run(ctx, authority.run_id,
          authority: authority,
          session_binding: session_binding,
          goal_trigger: :goal
        )

      event = done("", 2)
      send(worker, {:events, [%{event | message: Map.put(event.message, :phase, :commentary)}]})
      assert_receive {:agent_runtime, run_id, %{type: :run_completed}}, 2_000
      assert run_id == authority.run_id
    end

    assert {:ok, %{goal: %{status: :active}}} = Goal.get(ctx.goal)
    assert {:ok, snapshot} = Goal.snapshot(ctx.goal)
    assert snapshot.empty_turns == 0
  end

  test "absent assistant phase retains empty final automatic-turn stopping", ctx do
    for _ <- 1..3 do
      assert {:ok, {:started, _}} = Goal.idle(ctx.goal, 1)
      assert_receive {:admitted, authority, session_binding}

      {_, _, worker} =
        start_run(ctx, authority.run_id,
          authority: authority,
          session_binding: session_binding,
          goal_trigger: :goal
        )

      send(worker, {:events, [done("", 2)]})
      assert_receive {:agent_runtime, run_id, %{type: :run_completed}}, 2_000
      assert run_id == authority.run_id
    end

    assert {:ok, %{goal: %{status: :blocked}}} = Goal.get(ctx.goal)
    assert {:ok, snapshot} = Goal.snapshot(ctx.goal)
    assert snapshot.empty_turns == 3
  end

  test "reasoning activity prevents three automatic turns being classified empty", ctx do
    for _ <- 1..3 do
      assert {:ok, {:started, _}} = Goal.idle(ctx.goal, 1)
      assert_receive {:admitted, authority, session_binding}

      {_, _, worker} =
        start_run(ctx, authority.run_id,
          authority: authority,
          session_binding: session_binding,
          goal_trigger: :goal
        )

      send(
        worker,
        {:events, [%{type: :content_thinking_delta, delta: "inspect evidence"}, done("", 2)]}
      )

      assert_receive {:agent_runtime, run_id, %{type: :run_completed}}, 2_000
      assert run_id == authority.run_id
    end

    assert {:ok, %{goal: %{status: :active}}} = Goal.get(ctx.goal)
    assert {:ok, snapshot} = Goal.snapshot(ctx.goal)
    assert snapshot.empty_turns == 0
  end
end

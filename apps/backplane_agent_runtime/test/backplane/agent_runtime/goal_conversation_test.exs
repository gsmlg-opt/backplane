Code.require_file("../../fixtures/goal_file_store.exs", __DIR__)

defmodule Backplane.AgentRuntime.GoalConversationTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{
    Codex,
    Conversation,
    EphemeralStore,
    Error,
    Goal,
    GoalBridge,
    GoalFileStore,
    ToolRegistry
  }

  alias Backplane.AgentRuntime.Codex.{Session, ExtensionRuntime}
  @moduletag :tmp_dir

  defmodule Host do
    def record_user_instruction(_, _, _), do: :ok

    def start_turn_if_idle(host, _thread, request) do
      Agent.get_and_update(host, fn state ->
        if request.host_generation != state.generation or
             Session.status(state.session).phase != :idle do
          {{:ok, {:not_submitted, :busy}}, state}
        else
          run_id = "automatic-#{state.count + 1}"
          authority = %{caller: "host", run_id: run_id, grants: [], tool_revisions: %{}}
          {:ok, session_binding} = Session.bind(state.session, authority)
          send(state.test, {:reserved, run_id, request})

          {{:ok, {:started, %{run_id: run_id, incarnation: 1, turn_id: run_id}}},
           %{state | count: state.count + 1, reserved: {authority, session_binding}}}
        end
      end)
    end
  end

  defmodule Provider do
    def stream(request, context) do
      send(context.test, {:provider, request, self()})

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

  defmodule GatedGoalStore do
    def load(ctx, thread), do: GoalFileStore.load(ctx.store, thread)

    def compare_and_swap(ctx, thread, revision, goal_id, next) do
      {:ok, previous} = load(ctx, thread)

      if map_size(next.usage.reports) > map_size(previous.usage.reports) and
           Agent.get(ctx.gate, & &1) do
        send(ctx.test, {:goal_store_waiting, self()})

        receive do
          :fail -> {:error, Error.new(:execution_failure, "goal store unavailable")}
          :allow -> GoalFileStore.compare_and_swap(ctx.store, thread, revision, goal_id, next)
        end
      else
        GoalFileStore.compare_and_swap(ctx.store, thread, revision, goal_id, next)
      end
    end
  end

  setup ctx do
    store = start_supervised!({GoalFileStore, ctx.tmp_dir})
    session = start_supervised!({Session, owner_pid: self()})
    test = self()

    host =
      start_supervised!(
        {Agent, fn -> %{session: session, generation: 1, test: test, count: 0, reserved: nil} end}
      )

    gate = start_supervised!({Agent, fn -> true end}, id: :accounting_gate)

    {adapter, context} =
      if ctx[:gated_goal],
        do: {GatedGoalStore, %{store: store, gate: gate, test: test}},
        else: {GoalFileStore, store}

    goal =
      start_supervised!(
        {Goal,
         thread_id: "thread",
         owner_pid: self(),
         store: adapter,
         store_context: context,
         host: Host,
         host_context: host}
      )

    %{goal: goal, store: store, session: session, host: host, gate: gate}
  end

  defp start_run(ctx, run_id, opts \\ []) do
    authority =
      Keyword.get(opts, :authority, %{
        caller: "host",
        run_id: run_id,
        grants: [],
        tool_revisions: %{}
      })

    {:ok, session_binding} = Session.bind(ctx.session, authority)
    start_bound_run(ctx, authority, session_binding, opts)
  end

  defp start_bound_run(ctx, authority, session_binding, opts) do
    {:ok, goal_binding} =
      Goal.bind(ctx.goal, %{
        thread_id: "thread",
        run_id: authority.run_id,
        incarnation: 1,
        authority: authority,
        usage_authoritative: true,
        mode: Keyword.get(opts, :goal_mode, :execution)
      })

    {:ok, table} = EphemeralStore.new(1)

    pid =
      start_supervised!(
        {Conversation,
         Keyword.merge(
           [
             run_id: authority.run_id,
             store: EphemeralStore,
             context: table,
             provider: Provider,
             provider_context: %{test: self()},
             subscriber: self(),
             registry: %ToolRegistry{},
             tools: [],
             authority: authority,
             session_binding: session_binding,
             goal: ctx.goal,
             goal_binding: goal_binding,
             thread_id: "thread",
             run_timeout: :infinity,
             work: 20
           ],
           opts
         )},
        id: make_ref()
      )

    {pid, table}
  end

  defp done(text, usage),
    do: %{type: :response_completed, message: %{role: :assistant, content: text}, usage: usage}

  defp metrics(output), do: %{input_tokens: 50, cached_tokens: 40, output_tokens: output}

  test "normal turn completion preserves goal and ordinary Session admits a fresh continuation",
       ctx do
    {:ok, _} = Goal.set(ctx.goal, %{objective: "ship", token_budget: 100}, %{text: "ship"})
    {pid, table} = start_run(ctx, "first")
    {:ok, _} = Conversation.prompt(pid, "begin")
    assert_receive {:provider, %{run_id: "first"}, provider}

    send(
      provider,
      {:events, [%{type: :usage_updated, usage: metrics(2)}, done("progress", metrics(7))]}
    )

    assert_receive {:agent_runtime, "first", %{type: :run_completed}}, 2_000

    assert {:ok, %{goal: %{status: :active, tokens_used: 17}, remaining_tokens: 83}} =
             Goal.get(ctx.goal)

    assert Session.status(ctx.session).phase == :idle
    assert {:ok, record} = EphemeralStore.load(table, "first")
    assert record.run.context.conversation.goal_outbox == []
    assert {:ok, {:started, _}} = Goal.idle(ctx.goal, 1)
    assert_receive {:reserved, "automatic-1", %{trigger: :goal}}
    {authority, binding} = Agent.get(ctx.host, & &1.reserved)
    {next, _} = start_bound_run(ctx, authority, binding, goal_trigger: :goal)
    {:ok, _} = Conversation.prompt(next, "continue")
    assert_receive {:provider, %{run_id: "automatic-1"}, provider}
    send(provider, {:events, [done("more progress", metrics(3))]})
    assert_receive {:agent_runtime, "automatic-1", %{type: :run_completed}}, 2_000
    assert {:ok, %{goal: %{tokens_used: 30}, remaining_tokens: 70}} = Goal.get(ctx.goal)
  end

  test "budget boundary steers wrap-up and prevents automatic continuation", ctx do
    {:ok, _} = Goal.set(ctx.goal, %{objective: "ship", token_budget: 10}, %{text: "ship"})
    {pid, _} = start_run(ctx, "budget")
    {:ok, _} = Conversation.prompt(pid, "begin")
    assert_receive {:provider, _, provider}
    send(provider, {:events, [done("progress", metrics(7))]})
    assert_receive {:provider, %{messages: messages}, wrapup}, 2_000
    assert Enum.any?(messages, &String.contains?(Map.get(&1, :content, ""), "budget"))
    assert {:ok, %{goal: %{status: :budget_limited, tokens_used: 17}}} = Goal.get(ctx.goal)
    send(wrapup, {:events, [done("final wrap-up", metrics(2))]})
    assert_receive {:agent_runtime, "budget", %{type: :run_completed}}, 2_000
    assert {:ok, {:not_submitted, _}} = Goal.idle(ctx.goal, 1)
  end

  test "plan usage is excluded and unknown usage suspends budgeted admission", ctx do
    {:ok, _} = Goal.set(ctx.goal, %{objective: "ship", token_budget: 100}, %{text: "ship"})
    {pid, _} = start_run(ctx, "plan", goal_mode: :plan)
    {:ok, _} = Conversation.prompt(pid, "plan")
    assert_receive {:provider, _, provider}
    send(provider, {:events, [done("plan", metrics(7))]})
    assert_receive {:agent_runtime, "plan", %{type: :run_completed}}, 2_000
    assert {:ok, %{goal: %{tokens_used: 0}}} = Goal.get(ctx.goal)
    {pid, _} = start_run(ctx, "unknown")
    {:ok, _} = Conversation.prompt(pid, "begin")
    assert_receive {:provider, _, provider}
    send(provider, {:events, [done("progress", %{input_tokens: 10, output_tokens: 2})]})
    assert_receive {:agent_runtime, "unknown", %{type: :run_completed}}, 2_000
    assert {:ok, snapshot} = Goal.snapshot(ctx.goal)
    assert snapshot.accounting_uncertain
    assert {:ok, {:not_submitted, _}} = Goal.idle(ctx.goal, 1)
  end

  @tag gated_goal: true
  test "failed goal acknowledgement retains committed receipt and never repeats provider work",
       ctx do
    {:ok, _} = Goal.set(ctx.goal, %{objective: "ship", token_budget: 100}, %{text: "ship"})
    {pid, table} = start_run(ctx, "failed-accounting")
    {:ok, _} = Conversation.prompt(pid, "begin")
    assert_receive {:provider, _, provider}
    send(provider, {:events, [done("progress", metrics(7))]})
    assert_receive {:goal_store_waiting, waiter}, 2_000
    assert is_map(Conversation.status(pid).run.active_provider)
    refute_receive {:provider, _, _}, 20
    send(waiter, :fail)

    assert_receive {:agent_runtime, "failed-accounting",
                    %{type: :storage_failed, recovery_required: true}},
                   2_000

    assert {:ok, record} = EphemeralStore.load(table, "failed-accounting")
    receipts = record.run.context.conversation.goal_outbox
    assert Enum.any?(receipts, &(&1.type == :usage))
    assert {:ok, %{goal: %{tokens_used: 0}}} = Goal.get(ctx.goal)
    Agent.update(ctx.gate, fn _ -> false end)
    :ok = stop_supervised(Goal)

    restored_goal =
      start_supervised!(
        {Goal,
         thread_id: "thread",
         owner_pid: self(),
         store: GoalFileStore,
         store_context: ctx.store,
         host: Host,
         host_context: ctx.host}
      )

    authority = %{run_id: "failed-accounting", caller: "host", grants: []}

    {:ok, binding} =
      Goal.bind(restored_goal, %{
        thread_id: "thread",
        run_id: "failed-accounting",
        incarnation: 1,
        authority: authority,
        usage_authoritative: true
      })

    assert {:ok, _} = GoalBridge.redeliver(restored_goal, binding, record.run)
    assert {:ok, _} = GoalBridge.redeliver(restored_goal, binding, record.run)
    assert {:ok, %{goal: %{tokens_used: 17}}} = Goal.get(restored_goal)

    restored =
      start_supervised!(
        {Conversation,
         run_id: "failed-accounting",
         run: record.run,
         store: EphemeralStore,
         context: table,
         provider: Provider,
         provider_context: %{test: self()},
         registry: %ToolRegistry{},
         authority: authority},
        id: :restored
      )

    assert Conversation.status(restored).phase == :recovery_required
    refute_receive {:provider, _, _}, 20
  end

  test "committed Goal tools create midturn without charging earlier usage and flush before completion",
       ctx do
    names = ["create_goal", "get_goal", "update_goal"]

    authority = %{
      caller: "host",
      run_id: "goal-tools",
      grants: names,
      tool_revisions: Map.new(names, &{&1, 1})
    }

    runtime =
      start_supervised!(
        {ExtensionRuntime,
         goal: ctx.goal,
         scope: %{host_id: "h", caller_id: "host", run_id: "goal-tools", project_id: "p"}}
      )

    {:ok, profile} =
      Codex.profile(:extensions, %{extension_runtime: runtime}, authority, tools: names)

    {pid, _} =
      start_run(ctx, "goal-tools",
        authority: profile.authority,
        registry: profile.registry,
        tools: profile.tools
      )

    {:ok, _} = Conversation.prompt(pid, "create the goal")
    assert_receive {:provider, _, provider}

    send(
      provider,
      {:events,
       [
         call("create", "create_goal", %{"objective" => "ship", "token_budget" => 100}),
         done("working", metrics(7))
       ]}
    )

    assert_receive {:provider, %{messages: messages}, provider}, 2_000
    assert List.last(messages).result.goal.tokens_used == 0
    send(provider, {:events, [call("read", "get_goal", %{}), done("progress", metrics(3))]})
    assert_receive {:provider, %{messages: messages}, provider}, 2_000
    assert List.last(messages).result.remaining_tokens == 87

    send(
      provider,
      {:events,
       [call("complete", "update_goal", %{"status" => "complete"}), done("achieved", metrics(2))]}
    )

    assert_receive {:provider, %{messages: messages}, provider}, 2_000
    result = List.last(messages).result
    assert result.goal.status == :complete
    assert result.goal.tokens_used == 25
    assert is_binary(result.completion_budget_report)
    send(provider, {:events, [done("finished", metrics(1))]})
    assert_receive {:agent_runtime, "goal-tools", %{type: :run_completed}}, 2_000
    assert {:ok, %{goal: %{status: :complete, tokens_used: 36}}} = Goal.get(ctx.goal)
    assert {:ok, {:not_submitted, _}} = Goal.idle(ctx.goal, 1)
  end

  defp call(id, name, arguments),
    do: %{type: :tool_call_completed, tool_call: %{id: id, name: name, arguments: arguments}}

  test "cancellation persists continuation deferral without marking goal complete", ctx do
    {:ok, _} = Goal.set(ctx.goal, %{objective: "ship"}, %{text: "ship"})
    {pid, _} = start_run(ctx, "cancel")
    {:ok, _} = Conversation.prompt(pid, "begin")
    assert_receive {:provider, _, _}
    :ok = Conversation.cancel(pid)
    assert_receive {:agent_runtime, "cancel", %{type: :run_cancelled}}, 2_000
    assert {:ok, snapshot} = Goal.snapshot(ctx.goal)
    assert snapshot.goal.status == :active
    assert snapshot.continuation_deferral
    assert snapshot.continuation_deferral.reason == :interrupted
    assert snapshot.interrupted_turn != nil
    assert {:ok, {:not_submitted, _}} = Goal.idle(ctx.goal, 1)
  end

  test "normalized provider usage-limit failure stops automatic Goal continuation", ctx do
    {:ok, _} = Goal.set(ctx.goal, %{objective: "ship", token_budget: 100}, %{text: "ship"})
    {pid, _} = start_run(ctx, "usage-limit")
    {:ok, _} = Conversation.prompt(pid, "begin")
    assert_receive {:provider, _, worker}

    send(
      worker,
      {:events,
       [
         %{type: :usage_updated, usage: metrics(2)},
         %{
           type: :response_failed,
           error: %{class: :usage_limit, message: "provider quota reached"}
         }
       ]}
    )

    assert_receive {:agent_runtime, "usage-limit", %{type: :run_failed}}, 2_000
    assert {:ok, %{goal: %{status: :usage_limited, tokens_used: 12}}} = Goal.get(ctx.goal)
    assert {:ok, {:not_submitted, _}} = Goal.idle(ctx.goal, 1)
  end
end

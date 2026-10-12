Code.require_file("../../fixtures/goal_file_store.exs", __DIR__)

defmodule Backplane.AgentRuntime.GoalDescendantUsageTest do
  use ExUnit.Case, async: false
  alias Backplane.AgentRuntime.{Goal, GoalBridge, GoalFileStore, Usage}
  @moduletag :tmp_dir

  defmodule Host do
    @behaviour Backplane.AgentRuntime.Goal.Host
    def record_user_instruction(_, _, _), do: :ok
    def start_turn_if_idle(_, _, _), do: {:ok, {:not_submitted, :busy}}
  end

  setup ctx do
    store = start_supervised!({GoalFileStore, ctx.tmp_dir})

    goal =
      start_supervised!(
        {Goal,
         thread_id: "root",
         owner_pid: self(),
         store: GoalFileStore,
         store_context: store,
         host: Host,
         host_context: nil}
      )

    {:ok, _} =
      Goal.set(goal, %{objective: "finish whole task", token_budget: 100}, %{text: "finish"})

    {:ok, root} =
      Goal.bind(goal, %{
        thread_id: "root",
        run_id: "root-run",
        incarnation: 1,
        authority: %{run_id: "root-run"},
        usage_authoritative: true
      })

    {:ok, child} =
      Goal.delegate(goal, root, %{
        thread_id: "child",
        run_id: "child-run",
        incarnation: 1,
        authority: %{run_id: "child-run"}
      })

    %{goal: goal, root: root, child: child}
  end

  defp state(binding),
    do: %{
      goal_binding: binding,
      run: %{run_id: binding.run_id, incarnation: binding.incarnation, expected_revision: 5}
    }

  defp conversation, do: %{turn_id: "turn", goal_outbox: []}

  defp metrics(identity),
    do: %{
      identity: identity,
      attempt_id: "attempt",
      cumulative: true,
      input_tokens: 50,
      cached_tokens: 40,
      output_tokens: 7
    }

  defp receipt(binding, type, payload) do
    %{
      receipt_id: "#{binding.run_id}:6:#{type}",
      revision: 6,
      thread_id: binding.thread_id,
      run_id: binding.run_id,
      incarnation: binding.incarnation,
      turn_id: "turn",
      expected_goal_id: binding.expected_goal_id,
      type: type,
      payload: payload
    }
  end

  test "child queues only root usage while ordinary root lifecycle remains intact", ctx do
    events = [
      {:turn_started, %{trigger: :goal}},
      {:usage, metrics("u")},
      {:tool_finished, %{tool: "exec", success: false, handler_executed: true}},
      {:item_completed, %{kind: :assistant, text: "", phase: :final}},
      {:turn_error, %{class: :usage_limit}},
      {:turn_stopped, %{outcome: :failed}},
      {:turn_aborted, %{reason: :interrupt_turn}}
    ]

    child = GoalBridge.queue(state(ctx.child), conversation(), events)
    assert Enum.map(child.goal_outbox, & &1.type) == [:usage]
    root = GoalBridge.queue(state(ctx.root), conversation(), events)
    assert Enum.map(root.goal_outbox, & &1.type) == Enum.map(events, &elem(&1, 0))

    assert {:ok, [%{response: %{goal: %{tokens_used: 17, status: :active}}}]} =
             GoalBridge.deliver(ctx.goal, ctx.child, child.goal_outbox)
  end

  test "restored child outbox cannot apply child errors or interruption to root", ctx do
    old_receipts = [
      receipt(ctx.child, :turn_error, %{class: :usage_limit}),
      receipt(ctx.child, :turn_aborted, %{reason: :interrupt_turn}),
      receipt(ctx.child, :usage, metrics("u"))
    ]

    assert {:ok, [_usage]} = GoalBridge.deliver(ctx.goal, ctx.child, old_receipts)
    assert {:ok, %{goal: %{status: :active, tokens_used: 17}}} = Goal.get(ctx.goal)
    assert {:ok, snapshot} = Goal.snapshot(ctx.goal)
    assert snapshot.continuation_deferral == nil
    assert snapshot.failure_turns == 0
    assert snapshot.empty_turns == 0
  end

  test "child local usage and root charge are separate views; descendant reports settle once while root idle",
       ctx do
    {:ok, local} = Usage.new()
    {:ok, local, _} = Usage.report(local, metrics("u"))

    {:ok, grandchild} =
      Goal.delegate(ctx.goal, ctx.child, %{
        thread_id: "grandchild",
        run_id: "grandchild-run",
        incarnation: 2,
        authority: %{run_id: "grandchild-run"}
      })

    child_receipt = receipt(ctx.child, :usage, metrics("u"))
    grandchild_receipt = receipt(grandchild, :usage, metrics("u"))
    {:ok, _} = Goal.unbind(ctx.goal, ctx.root)
    assert {:ok, [_]} = GoalBridge.deliver(ctx.goal, ctx.child, [child_receipt])
    assert {:ok, [_]} = GoalBridge.deliver(ctx.goal, ctx.child, [child_receipt])
    assert {:ok, [_]} = GoalBridge.deliver(ctx.goal, grandchild, [grandchild_receipt])
    assert Usage.totals(local).input_tokens == 50
    assert {:ok, %{goal: %{tokens_used: 34}}} = Goal.get(ctx.goal)
  end

  test "old descendants cannot debit a recreated root goal", ctx do
    old = receipt(ctx.child, :usage, metrics("u"))
    {:ok, _} = Goal.clear(ctx.goal, %{text: "clear"})

    {:ok, _} =
      Goal.set(ctx.goal, %{objective: "new task", token_budget: 100}, %{text: "new task"})

    assert {:error, %{class: :resource_conflict}} = GoalBridge.deliver(ctx.goal, ctx.child, [old])
    assert {:ok, %{goal: %{objective: "new task", tokens_used: 0}}} = Goal.get(ctx.goal)
  end

  test "descendant attribution retains the captured root identity after replacement", ctx do
    {:ok, _} = Goal.clear(ctx.goal, %{text: "clear"})
    {:ok, _} = Goal.set(ctx.goal, %{objective: "replacement"}, %{text: "replacement"})
    assert {:ok, child} = Goal.attribution(ctx.goal, ctx.child)
    assert child.expected_goal_id == ctx.child.root_goal_id
    queued = GoalBridge.queue(state(child), conversation(), [{:usage, metrics("late")}])

    assert {:error, %{class: :resource_conflict}} =
             GoalBridge.deliver(ctx.goal, child, queued.goal_outbox)

    assert {:error, %{class: :forbidden}} =
             Goal.tool(ctx.goal, %{
               binding: child,
               name: :update_goal,
               invocation_id: "late-update",
               arguments: %{status: :complete}
             })

    assert {:ok, %{goal: %{status: :active, tokens_used: 0}}} = Goal.get(ctx.goal)
  end

  test "delegated bindings authorize only root usage and cannot run root Goal tools", ctx do
    Enum.each([:get_goal, :create_goal, :update_goal], fn name ->
      assert {:error, %{class: :forbidden}} =
               Goal.tool(ctx.goal, %{
                 binding: ctx.child,
                 name: name,
                 invocation_id: "child-#{name}",
                 arguments: %{objective: "child objective", status: :complete}
               })
    end)

    assert {:error, %{class: :forbidden}} =
             Goal.committed(
               ctx.goal,
               receipt(ctx.child, :turn_error, %{class: :usage_limit})
               |> Map.put(:binding, ctx.child)
             )

    assert {:ok, %{goal: %{status: :active, tokens_used: 0}}} = Goal.get(ctx.goal)
  end
end

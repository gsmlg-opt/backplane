defmodule Backplane.AgentRuntime.PlanTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.Error
  alias Backplane.AgentRuntime.Plan

  test "reads the task-scoped plan and accepts the current revision" do
    {:ok, plan} = Plan.start_link("task_1", %{"step" => "one"})

    assert {:ok, %{content: %{"step" => "one"}, revision: 1}} = Plan.read(plan)

    assert {:ok, %{revision: 2}} = Plan.update(plan, 1, %{"step" => "done"})
  end

  test "conflicts stale updates against the authoritative plan" do
    {:ok, plan} = Plan.start_link("task_1")

    assert {:ok, %{revision: 2}} = Plan.update(plan, 1, %{"attempt" => "first"})

    stale_plan = plan

    assert {:error, %Error{class: :resource_conflict}} =
             Plan.update(stale_plan, 1, %{"attempt" => "second"})

    assert {:ok, %{revision: 3}} = Plan.update(plan, 2, %{"attempt" => "third"})
  end
end

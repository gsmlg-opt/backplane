defmodule Backplane.AgentRuntime.RunTreeTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.RunTree

  describe "run-owned children" do
    test "adds bounded run-owned children and reports depth" do
      {:ok, tree} = RunTree.new("root", %{max_depth: 2})

      assert {:ok, tree, %{run_id: "child_1", depth: 1}} =
               RunTree.add_child(tree, "root", %{run_id: "child_1", owner: :run})

      assert {:ok, _tree, %{run_id: "grandchild_1", depth: 2}} =
               RunTree.add_child(tree, "child_1", %{run_id: "grandchild_1", owner: :run})
    end

    test "rejects depth expansion and duplicate child identity" do
      {:ok, tree} = RunTree.new("root", %{max_depth: 1})
      {:ok, tree, _} = RunTree.add_child(tree, "root", %{run_id: "child_1", owner: :run})

      assert {:error, %Backplane.AgentRuntime.Error{}} =
               RunTree.add_child(tree, "child_1", %{run_id: "grandchild_1", owner: :run})

      assert {:error, %Backplane.AgentRuntime.Error{}} =
               RunTree.add_child(tree, "root", %{run_id: "child_1", owner: :run})
    end

    test "computes child and grandchild depth from an opaque root identity" do
      {:ok, tree} = RunTree.new("run-7f31", %{max_depth: 2})

      assert {:ok, tree, %{run_id: "child", depth: 1}} =
               RunTree.add_child(tree, "run-7f31", %{run_id: "child", owner: :run})

      assert {:ok, tree, %{run_id: "grandchild", depth: 2}} =
               RunTree.add_child(tree, "child", %{run_id: "grandchild", owner: :run})

      assert {:error, %Backplane.AgentRuntime.Error{class: :budget_exceeded}} =
               RunTree.add_child(tree, "grandchild", %{run_id: "too-deep", owner: :run})
    end

    test "cancels owned descendants without touching unrelated peer work" do
      {:ok, tree} = RunTree.new("root", %{max_depth: 3})
      {:ok, tree, _} = RunTree.add_child(tree, "root", %{run_id: "child_1", owner: :run})
      {:ok, tree, _} = RunTree.add_child(tree, "child_1", %{run_id: "grandchild_1", owner: :run})
      {:ok, tree, _} = RunTree.add_child(tree, "root", %{run_id: "peer", owner: nil})

      assert {:ok, tree, %{cancelled: ["child_1", "grandchild_1"], untouched: untouched}} =
               RunTree.cancel(tree, "child_1")

      assert MapSet.new(untouched) == MapSet.new(["root", "peer"])

      assert tree.nodes["grandchild_1"].state == :cancelled
      assert tree.nodes["peer"].state == :running
    end

    test "does not cancel an unowned causal subtree beneath the requested run" do
      {:ok, tree} = RunTree.new("opaque-root", %{max_depth: 4})

      {:ok, tree, _} =
        RunTree.add_child(tree, "opaque-root", %{run_id: "delegated", owner: :run})

      {:ok, tree, _} =
        RunTree.add_child(tree, "delegated", %{run_id: "owned-child", owner: :run})

      {:ok, tree, _} =
        RunTree.add_child(tree, "delegated", %{run_id: "recipient-work", owner: nil})

      {:ok, tree, _} =
        RunTree.add_child(tree, "recipient-work", %{run_id: "recipient-child", owner: :run})

      assert {:ok, tree, %{cancelled: cancelled, untouched: untouched}} =
               RunTree.cancel(tree, "delegated")

      assert MapSet.new(cancelled) == MapSet.new(["delegated", "owned-child"])

      assert MapSet.new(untouched) ==
               MapSet.new(["opaque-root", "recipient-work", "recipient-child"])

      assert tree.nodes["recipient-work"].state == :running
      assert tree.nodes["recipient-child"].state == :running
    end

    test "root cancellation follows only run-owned child edges" do
      {:ok, tree} = RunTree.new("root-opaque", %{max_depth: 3})
      {:ok, tree, _} = RunTree.add_child(tree, "root-opaque", %{run_id: "child", owner: :run})
      {:ok, tree, _} = RunTree.add_child(tree, "child", %{run_id: "grandchild", owner: :run})
      {:ok, tree, _} = RunTree.add_child(tree, "root-opaque", %{run_id: "hosted", owner: nil})

      assert {:ok, tree, %{cancelled: cancelled, untouched: ["hosted"]}} =
               RunTree.cancel(tree, "root-opaque")

      assert MapSet.new(cancelled) == MapSet.new(["root-opaque", "child", "grandchild"])
      assert tree.nodes["hosted"].state == :running
    end
  end
end

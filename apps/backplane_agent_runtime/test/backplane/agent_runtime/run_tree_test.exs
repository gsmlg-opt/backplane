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
  end
end

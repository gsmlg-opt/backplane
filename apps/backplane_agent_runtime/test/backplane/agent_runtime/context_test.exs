defmodule Backplane.AgentRuntime.ContextTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.Context
  alias Backplane.AgentRuntime.Error

  describe "context ownership" do
    test "creates a versioned context with explicit selected material" do
      {:ok, context} =
        Context.create("agent_1", ["system"], ["public_summary"])

      assert context.revision == 1
      assert context.instructions == ["system"]
      assert context.selected_material == ["public_summary"]
    end

    test "rejects invalid instruction and selected material collections" do
      assert {:error, %Error{class: :validation, message: "instructions must be a list"}} =
               Context.create("agent_1", :invalid)

      assert {:error, %Error{class: :validation, message: "selected material must be a list"}} =
               Context.create("agent_1", ["system"], :invalid)
    end

    test "forks only selected fields and never child instructions" do
      {:ok, parent} = Context.create("parent", ["parent instructions"], [:history, :resources])

      assert {:ok, child} =
               Context.fork(
                 parent,
                 %{agent_id: "child", instructions: ["child instructions"]},
                 [:history]
               )

      assert child.instructions == ["child instructions"]
      assert Map.has_key?(child.selected_material, :history)
      refute Map.has_key?(child.selected_material, :resources)
    end

    test "rejects selection that replaces child instructions" do
      {:ok, parent} = Context.create("parent", ["parent instructions"])

      assert {:error, %Error{class: :forbidden}} =
               Context.fork(parent, %{agent_id: "child", instructions: []}, [:instructions])
    end
  end

  describe "revision coordination" do
    test "admits provenance-tagged results at the expected revision" do
      {:ok, context} = Context.create("agent_1", ["system"])

      assert {:ok, updated} =
               Context.admit_result(
                 context,
                 %{content: "peer result", provenance: %{peer: true}},
                 1
               )

      assert [%{content: "peer result", provenance: %{peer: true}}] = updated.history
      assert updated.revision == 2
    end

    test "rejects stale revisions and instruction rewrites" do
      {:ok, context} = Context.create("agent_1", ["system"])

      assert {:error, %Error{class: :resource_conflict}} =
               Context.admit_result(context, %{content: "late"}, 2)

      assert {:error, %Error{class: :forbidden}} =
               Context.admit_result(context, %{content: "peer", instructions: ["forged"]}, 1)
    end

    test "compaction is a revisioned transition" do
      {:ok, context} = Context.create("agent_1", ["system"])
      {:ok, context} = Context.admit_result(context, %{content: "old"}, 1)

      assert {:ok, compacted} = Context.compaction(context, %{summary: "done"}, %{tokens: 10}, 2)

      assert compacted.revision == 3
      assert compacted.history == []
      assert [%{summary: %{summary: "done"}}] = compacted.summaries

      assert {:error, %Error{class: :resource_conflict}} =
               Context.compaction(compacted, %{summary: "stale"}, %{}, 2)
    end
  end
end

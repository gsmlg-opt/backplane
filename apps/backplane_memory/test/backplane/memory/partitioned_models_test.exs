defmodule Backplane.Memory.PartitionedModelsTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.Coordination.{Action, Lease, Signal}
  alias Backplane.Memory.Graph
  alias Backplane.Memory.Graph.BFS
  alias Backplane.Memory.Profiles
  alias Backplane.Memory.Profiles.Profile
  alias Backplane.Memory.Slots

  setup do
    %{
      partition_a: canonical_partition("host-a", scope: "project"),
      partition_b: canonical_partition("host-b", scope: "project")
    }
  end

  test "profiles with the same project are isolated by the complete partition", context do
    repo().insert!(
      Profile.changeset(%Profile{}, Map.merge(context.partition_a, %{project: "shared"}))
    )

    repo().insert!(
      Profile.changeset(%Profile{}, Map.merge(context.partition_b, %{project: "shared"}))
    )

    assert Profiles.get("shared", context.partition_a).host_id == "host-a"
    assert Profiles.get("shared", context.partition_b).host_id == "host-b"
  end

  test "graph upsert, traversal, and stats never cross partitions", context do
    {:ok, a} = Graph.upsert_node(%{type: "Concept", name: "same"}, context.partition_a)
    {:ok, b} = Graph.upsert_node(%{type: "Concept", name: "same"}, context.partition_b)
    refute a.id == b.id

    assert {:ok, %{nodes: [%{id: id}]}} = BFS.query("same", 1, nil, context.partition_a)
    assert id == a.id

    assert {:ok, %{nodes: [], edges: []}} =
             BFS.query_from_nodes([b], 1, nil, context.partition_a)

    assert Graph.stats(context.partition_a).node_count_by_type == %{"Concept" => 1}
  end

  test "slots with the same name are isolated and incomplete partitions are denied", context do
    assert {:ok, _} = Slots.write("persona", "a", nil, context.partition_a)
    assert {:ok, _} = Slots.write("persona", "b", nil, context.partition_b)
    assert {:ok, %{content: "a"}} = Slots.read("persona", context.partition_a)
    assert {:ok, %{content: "b"}} = Slots.read("persona", context.partition_b)

    assert {:error, :incomplete_partition} =
             Slots.read("persona", Map.delete(context.partition_a, :memory_space_id))
  end

  test "actions, leases, and signals are isolated by the complete partition", context do
    {:ok, action_a} = Action.create(%{"title" => "same"}, [], context.partition_a)
    {:ok, _action_b} = Action.create(%{"title" => "same"}, [], context.partition_b)

    assert Enum.map(Action.frontier(nil, context.partition_a), & &1.id) == [action_a.id]
    assert {:ok, _lease_id} = Lease.acquire(action_a.id, "agent", 300, context.partition_a)
    assert {:error, :not_found} = Lease.acquire(action_a.id, "agent", 300, context.partition_b)

    assert {:ok, _} =
             Signal.send_signal("a", "receiver", "topic", %{}, context.partition_a)

    assert {:ok, []} = Signal.read_signals("receiver", nil, 20, context.partition_b)
    assert {:ok, [_]} = Signal.read_signals("receiver", nil, 20, context.partition_a)
  end
end

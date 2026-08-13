defmodule Backplane.Memory.PartitionedModelsTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.Coordination.{Action, Lease, Signal}
  alias Backplane.Memory.Graph
  alias Backplane.Memory.Graph.BFS
  alias Backplane.Memory.Profiles
  alias Backplane.Memory.Profiles.Profile
  alias Backplane.Memory.Slots

  @partition_a %{
    host_id: "host-a",
    client_id: "host:host-a",
    scope: "project",
    namespace: "private"
  }
  @partition_b %{
    host_id: "host-b",
    client_id: "host:host-b",
    scope: "project",
    namespace: "private"
  }

  test "profiles with the same project are isolated by the complete partition" do
    repo().insert!(Profile.changeset(%Profile{}, Map.merge(@partition_a, %{project: "shared"})))
    repo().insert!(Profile.changeset(%Profile{}, Map.merge(@partition_b, %{project: "shared"})))

    assert Profiles.get("shared", @partition_a).host_id == "host-a"
    assert Profiles.get("shared", @partition_b).host_id == "host-b"
  end

  test "graph upsert, traversal, and stats never cross partitions" do
    {:ok, a} = Graph.upsert_node(%{type: "Concept", name: "same"}, @partition_a)
    {:ok, b} = Graph.upsert_node(%{type: "Concept", name: "same"}, @partition_b)
    refute a.id == b.id

    assert {:ok, %{nodes: [%{id: id}]}} = BFS.query("same", 1, nil, @partition_a)
    assert id == a.id
    assert {:ok, %{nodes: [], edges: []}} = BFS.query_from_nodes([b], 1, nil, @partition_a)
    assert Graph.stats(@partition_a).node_count_by_type == %{"Concept" => 1}
  end

  test "slots with the same name are isolated and ambiguous legacy rows are denied" do
    assert {:ok, _} = Slots.write("persona", "a", nil, @partition_a)
    assert {:ok, _} = Slots.write("persona", "b", nil, @partition_b)
    assert {:ok, %{content: "a"}} = Slots.read("persona", @partition_a)
    assert {:ok, %{content: "b"}} = Slots.read("persona", @partition_b)

    repo().insert!(%Backplane.Memory.Slots.Slot{
      name: "legacy",
      content: "secret",
      updated_at: DateTime.utc_now()
    })

    assert {:error, :not_found} = Slots.read("legacy", @partition_a)
  end

  test "actions, leases, and signals are isolated by the complete partition" do
    {:ok, action_a} = Action.create(%{"title" => "same"}, [], @partition_a)
    {:ok, _action_b} = Action.create(%{"title" => "same"}, [], @partition_b)

    assert Enum.map(Action.frontier(nil, @partition_a), & &1.id) == [action_a.id]
    assert {:ok, _lease_id} = Lease.acquire(action_a.id, "agent", 300, @partition_a)
    assert {:error, :not_found} = Lease.acquire(action_a.id, "agent", 300, @partition_b)

    assert {:ok, _} = Signal.send_signal("a", "receiver", "topic", %{}, @partition_a)
    assert {:ok, []} = Signal.read_signals("receiver", nil, 20, @partition_b)
    assert {:ok, [_]} = Signal.read_signals("receiver", nil, 20, @partition_a)
  end
end

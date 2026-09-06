defmodule Backplane.Memory.Graph.BFSTest do
  use Backplane.Memory.DataCase, async: true

  alias Backplane.Memory.Graph.{BFS, Edge, Node}

  setup do
    %{partition: canonical_partition("graph-bfs-#{System.unique_integer([:positive])}")}
  end

  # Insert nodes directly to avoid fuzzy-dedup collapsing similar names.
  defp insert_node(type, name, partition) do
    {:ok, node} =
      %Node{}
      |> Node.changeset(Map.merge(partition, %{type: type, name: name}))
      |> repo().insert()

    node
  end

  defp insert_edge(src, tgt, relation, partition) do
    {:ok, edge} =
      %Edge{}
      |> Edge.changeset(
        Map.merge(partition, %{source_id: src.id, target_id: tgt.id, relation: relation})
      )
      |> repo().insert()

    edge
  end

  describe "query/3" do
    test "returns seed node with no edges at depth=1", %{partition: partition} do
      node = insert_node("Concept", "bfs_orphan_concept_#{System.unique_integer()}", partition)

      {:ok, %{nodes: nodes, edges: edges}} = BFS.query(node.name, 1, nil, partition)

      assert Enum.any?(nodes, &(&1.id == node.id))
      assert edges == []
    end

    test "returns directly connected nodes at depth=1", %{partition: partition} do
      suffix = System.unique_integer()
      a = insert_node("Module", "BfsAlpha#{suffix}", partition)
      b = insert_node("Person", "BfsBeta#{suffix}", partition)
      edge = insert_edge(a, b, "depends_on", partition)

      {:ok, %{nodes: nodes, edges: edges}} = BFS.query(a.name, 1, nil, partition)

      node_ids = Enum.map(nodes, & &1.id)
      assert a.id in node_ids
      assert b.id in node_ids
      assert Enum.any?(edges, &(&1.id == edge.id))
    end

    test "returns two-hop neighbours at depth=2", %{partition: partition} do
      suffix = System.unique_integer()
      a = insert_node("Module", "TwoHopA#{suffix}", partition)
      b = insert_node("Library", "TwoHopB#{suffix}", partition)
      c = insert_node("Decision", "TwoHopC#{suffix}", partition)
      _e1 = insert_edge(a, b, "calls", partition)
      _e2 = insert_edge(b, c, "calls", partition)

      {:ok, %{nodes: nodes}} = BFS.query(a.name, 2, nil, partition)

      node_ids = Enum.map(nodes, & &1.id)
      assert a.id in node_ids
      assert b.id in node_ids
      assert c.id in node_ids
    end

    test "does not cross depth boundary", %{partition: partition} do
      suffix = System.unique_integer()
      a = insert_node("File", "DepthSeedNode#{suffix}", partition)
      b = insert_node("Bug", "DepthMidNode#{suffix}", partition)
      c = insert_node("Pattern", "DepthFarNode#{suffix}", partition)
      _e1 = insert_edge(a, b, "imports", partition)
      _e2 = insert_edge(b, c, "imports", partition)

      {:ok, %{nodes: nodes}} = BFS.query(a.name, 1, nil, partition)

      node_ids = Enum.map(nodes, & &1.id)
      assert a.id in node_ids
      assert b.id in node_ids
      refute c.id in node_ids
    end

    test "filters edges by relation_filter", %{partition: partition} do
      suffix = System.unique_integer()
      a = insert_node("Function", "FilterSrc#{suffix}", partition)
      b = insert_node("Concept", "FilterCalls#{suffix}", partition)
      c = insert_node("Concept", "FilterUses#{suffix}", partition)
      _calls_edge = insert_edge(a, b, "calls", partition)
      _uses_edge = insert_edge(a, c, "uses", partition)

      {:ok, %{nodes: nodes, edges: edges}} = BFS.query(a.name, 1, "calls", partition)

      node_ids = Enum.map(nodes, & &1.id)
      assert b.id in node_ids
      refute c.id in node_ids
      assert Enum.all?(edges, &(&1.relation == "calls"))
    end

    test "returns empty result when no node matches", %{partition: partition} do
      {:ok, %{nodes: nodes, edges: edges}} =
        BFS.query("bfs_no_such_node_xyz_#{System.unique_integer()}", 2, nil, partition)

      assert nodes == []
      assert edges == []
    end
  end
end

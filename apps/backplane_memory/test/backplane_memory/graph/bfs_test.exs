defmodule BackplaneMemory.Graph.BFSTest do
  use BackplaneMemory.DataCase, async: true

  alias BackplaneMemory.Graph.{BFS, Edge, Node}

  # Insert nodes directly to avoid fuzzy-dedup collapsing similar names.
  defp insert_node(type, name) do
    {:ok, node} =
      %Node{}
      |> Node.changeset(%{type: type, name: name})
      |> repo().insert()

    node
  end

  defp insert_edge(src, tgt, relation) do
    {:ok, edge} =
      %Edge{}
      |> Edge.changeset(%{source_id: src.id, target_id: tgt.id, relation: relation})
      |> repo().insert()

    edge
  end

  describe "query/3" do
    test "returns seed node with no edges at depth=1" do
      node = insert_node("Concept", "bfs_orphan_concept_#{System.unique_integer()}")

      {:ok, %{nodes: nodes, edges: edges}} = BFS.query(node.name, 1)

      assert Enum.any?(nodes, &(&1.id == node.id))
      assert edges == []
    end

    test "returns directly connected nodes at depth=1" do
      suffix = System.unique_integer()
      a = insert_node("Module", "BfsAlpha#{suffix}")
      b = insert_node("Person", "BfsBeta#{suffix}")
      edge = insert_edge(a, b, "depends_on")

      {:ok, %{nodes: nodes, edges: edges}} = BFS.query(a.name, 1)

      node_ids = Enum.map(nodes, & &1.id)
      assert a.id in node_ids
      assert b.id in node_ids
      assert Enum.any?(edges, &(&1.id == edge.id))
    end

    test "returns two-hop neighbours at depth=2" do
      suffix = System.unique_integer()
      a = insert_node("Module", "TwoHopA#{suffix}")
      b = insert_node("Library", "TwoHopB#{suffix}")
      c = insert_node("Decision", "TwoHopC#{suffix}")
      _e1 = insert_edge(a, b, "calls")
      _e2 = insert_edge(b, c, "calls")

      {:ok, %{nodes: nodes}} = BFS.query(a.name, 2)

      node_ids = Enum.map(nodes, & &1.id)
      assert a.id in node_ids
      assert b.id in node_ids
      assert c.id in node_ids
    end

    test "does not cross depth boundary" do
      suffix = System.unique_integer()
      a = insert_node("File", "DepthSeedNode#{suffix}")
      b = insert_node("Bug", "DepthMidNode#{suffix}")
      c = insert_node("Pattern", "DepthFarNode#{suffix}")
      _e1 = insert_edge(a, b, "imports")
      _e2 = insert_edge(b, c, "imports")

      {:ok, %{nodes: nodes}} = BFS.query(a.name, 1)

      node_ids = Enum.map(nodes, & &1.id)
      assert a.id in node_ids
      assert b.id in node_ids
      refute c.id in node_ids
    end

    test "filters edges by relation_filter" do
      suffix = System.unique_integer()
      a = insert_node("Function", "FilterSrc#{suffix}")
      b = insert_node("Concept", "FilterCalls#{suffix}")
      c = insert_node("Concept", "FilterUses#{suffix}")
      _calls_edge = insert_edge(a, b, "calls")
      _uses_edge = insert_edge(a, c, "uses")

      {:ok, %{nodes: nodes, edges: edges}} = BFS.query(a.name, 1, "calls")

      node_ids = Enum.map(nodes, & &1.id)
      assert b.id in node_ids
      refute c.id in node_ids
      assert Enum.all?(edges, &(&1.relation == "calls"))
    end

    test "returns empty result when no node matches" do
      {:ok, %{nodes: nodes, edges: edges}} =
        BFS.query("bfs_no_such_node_xyz_#{System.unique_integer()}", 2)

      assert nodes == []
      assert edges == []
    end
  end
end

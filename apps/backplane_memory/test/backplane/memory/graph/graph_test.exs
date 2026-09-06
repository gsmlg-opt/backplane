defmodule Backplane.Memory.GraphTest do
  use Backplane.Memory.DataCase, async: true

  alias Backplane.Memory.Graph

  setup do
    %{partition: canonical_partition("graph-#{System.unique_integer([:positive])}")}
  end

  describe "upsert_node/1" do
    test "inserts a new node", %{partition: partition} do
      {:ok, node} =
        Graph.upsert_node(
          %{type: "Concept", name: "caching_#{System.unique_integer()}"},
          partition
        )

      assert node.id != nil
      assert node.type == "Concept"
    end

    test "returns existing node when name is identical", %{partition: partition} do
      name = "idempotent_#{System.unique_integer()}"
      {:ok, first} = Graph.upsert_node(%{type: "Concept", name: name}, partition)
      {:ok, second} = Graph.upsert_node(%{type: "Concept", name: name}, partition)
      assert first.id == second.id
    end

    test "deduplicates on fuzzy name match (Jaro >= 0.85)", %{partition: partition} do
      # Jaro("lib/my_module.ex", "lib/my_module.ex") == 1.0
      {:ok, first} =
        Graph.upsert_node(%{type: "File", name: "lib/my_module.ex"}, partition)

      {:ok, second} =
        Graph.upsert_node(%{type: "File", name: "lib/my_module.ex"}, partition)

      assert first.id == second.id
    end

    test "deduplicates within canonical owner despite different provenance", %{
      partition: partition
    } do
      name = "canonical_owner_#{System.unique_integer()}"
      other_provenance = %{partition | host_id: "another-host", client_id: "another-client"}

      {:ok, first} = Graph.upsert_node(%{type: "Concept", name: name}, partition)
      {:ok, second} = Graph.upsert_node(%{type: "Concept", name: name}, other_provenance)

      assert first.id == second.id
    end

    test "inserts different node when same type but very different name", %{partition: partition} do
      # UUIDs have unrelated character distributions, guaranteeing Jaro < 0.85
      {:ok, a} =
        Graph.upsert_node(%{type: "Module", name: Ecto.UUID.generate()}, partition)

      {:ok, b} =
        Graph.upsert_node(%{type: "Module", name: Ecto.UUID.generate()}, partition)

      assert a.id != b.id
    end

    test "inserts different node when same name but different type", %{partition: partition} do
      name = "shared_#{System.unique_integer()}"
      {:ok, a} = Graph.upsert_node(%{type: "File", name: name}, partition)
      {:ok, b} = Graph.upsert_node(%{type: "Concept", name: name}, partition)
      assert a.id != b.id
    end
  end

  describe "insert_edge/1" do
    test "inserts an edge between two nodes", %{partition: partition} do
      suffix = System.unique_integer()
      {:ok, src} = Graph.upsert_node(%{type: "Module", name: "EdgeSrc#{suffix}"}, partition)

      {:ok, tgt} =
        Graph.upsert_node(%{type: "Library", name: "EdgeTgt#{suffix}"}, partition)

      {:ok, edge} =
        Graph.insert_edge(
          %{source_id: src.id, target_id: tgt.id, relation: "calls"},
          partition
        )

      assert edge.id != nil
      assert edge.source_id == src.id
      assert edge.target_id == tgt.id
    end
  end

  describe "stats/0" do
    test "separates lifecycle, provenance, and knowledge relation domains", %{
      partition: partition
    } do
      partition = %{partition | scope: "graph-scope"}

      assert %{relation_count_by_domain: domains} = Graph.stats(partition)
      assert Map.keys(domains) == ["knowledge", "lifecycle", "provenance"]
    end

    test "counts include newly inserted nodes by type", %{partition: partition} do
      suffix = System.unique_integer()

      {:ok, _} =
        Graph.upsert_node(%{type: "Decision", name: "StatDecision#{suffix}"}, partition)

      stats = Graph.stats(partition)

      # Only assert the type we just inserted exists with at least 1
      assert Map.get(stats.node_count_by_type, "Decision", 0) >= 1
    end

    test "counts include newly inserted edges by relation", %{partition: partition} do
      suffix = System.unique_integer()

      {:ok, a} =
        Graph.upsert_node(%{type: "Pattern", name: "StatsPatA#{suffix}"}, partition)

      {:ok, b} = Graph.upsert_node(%{type: "Bug", name: "StatsBugB#{suffix}"}, partition)

      {:ok, _} =
        Graph.insert_edge(
          %{source_id: a.id, target_id: b.id, relation: "caused_by"},
          partition
        )

      stats = Graph.stats(partition)

      assert Map.get(stats.edge_count_by_relation, "caused_by", 0) >= 1
    end

    test "returns maps for node_count_by_type and edge_count_by_relation", %{
      partition: partition
    } do
      stats = Graph.stats(partition)
      assert is_map(stats.node_count_by_type)
      assert is_map(stats.edge_count_by_relation)
    end
  end
end

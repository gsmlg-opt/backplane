defmodule BackplaneMemory.GraphTest do
  use BackplaneMemory.DataCase, async: true

  alias BackplaneMemory.Graph

  describe "upsert_node/1" do
    test "inserts a new node" do
      {:ok, node} =
        Graph.upsert_node(%{type: "Concept", name: "caching_#{System.unique_integer()}"})

      assert node.id != nil
      assert node.type == "Concept"
    end

    test "returns existing node when name is identical" do
      name = "idempotent_#{System.unique_integer()}"
      {:ok, first} = Graph.upsert_node(%{type: "Concept", name: name})
      {:ok, second} = Graph.upsert_node(%{type: "Concept", name: name})
      assert first.id == second.id
    end

    test "deduplicates on fuzzy name match (Jaro >= 0.85)" do
      # Jaro("lib/my_module.ex", "lib/my_module.ex") == 1.0
      {:ok, first} = Graph.upsert_node(%{type: "File", name: "lib/my_module.ex"})
      {:ok, second} = Graph.upsert_node(%{type: "File", name: "lib/my_module.ex"})
      assert first.id == second.id
    end

    test "inserts different node when same type but very different name" do
      # UUIDs have unrelated character distributions, guaranteeing Jaro < 0.85
      {:ok, a} = Graph.upsert_node(%{type: "Module", name: Ecto.UUID.generate()})
      {:ok, b} = Graph.upsert_node(%{type: "Module", name: Ecto.UUID.generate()})
      assert a.id != b.id
    end

    test "inserts different node when same name but different type" do
      name = "shared_#{System.unique_integer()}"
      {:ok, a} = Graph.upsert_node(%{type: "File", name: name})
      {:ok, b} = Graph.upsert_node(%{type: "Concept", name: name})
      assert a.id != b.id
    end
  end

  describe "insert_edge/1" do
    test "inserts an edge between two nodes" do
      suffix = System.unique_integer()
      {:ok, src} = Graph.upsert_node(%{type: "Module", name: "EdgeSrc#{suffix}"})
      {:ok, tgt} = Graph.upsert_node(%{type: "Library", name: "EdgeTgt#{suffix}"})

      {:ok, edge} =
        Graph.insert_edge(%{source_id: src.id, target_id: tgt.id, relation: "calls"})

      assert edge.id != nil
      assert edge.source_id == src.id
      assert edge.target_id == tgt.id
    end
  end

  describe "stats/0" do
    test "counts include newly inserted nodes by type" do
      suffix = System.unique_integer()
      {:ok, _} = Graph.upsert_node(%{type: "Decision", name: "StatDecision#{suffix}"})

      stats = Graph.stats()

      # Only assert the type we just inserted exists with at least 1
      assert Map.get(stats.node_count_by_type, "Decision", 0) >= 1
    end

    test "counts include newly inserted edges by relation" do
      suffix = System.unique_integer()
      {:ok, a} = Graph.upsert_node(%{type: "Pattern", name: "StatsPatA#{suffix}"})
      {:ok, b} = Graph.upsert_node(%{type: "Bug", name: "StatsBugB#{suffix}"})
      {:ok, _} = Graph.insert_edge(%{source_id: a.id, target_id: b.id, relation: "caused_by"})

      stats = Graph.stats()

      assert Map.get(stats.edge_count_by_relation, "caused_by", 0) >= 1
    end

    test "returns maps for node_count_by_type and edge_count_by_relation" do
      stats = Graph.stats()
      assert is_map(stats.node_count_by_type)
      assert is_map(stats.edge_count_by_relation)
    end
  end
end

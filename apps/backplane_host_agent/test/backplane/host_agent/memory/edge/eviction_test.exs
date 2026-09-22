defmodule Backplane.HostAgent.Memory.Edge.EvictionTest do
  use ExUnit.Case, async: false

  alias Backplane.HostAgent.Memory.Edge.{Eviction, Migrator, Store}
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    name = :"edge_eviction_#{System.unique_integer([:positive])}"
    config = %{enabled: true, development_plaintext: true}
    start_supervised!({Store, database: Path.join(dir, "edge.db"), name: name, config: config})
    :ok = Migrator.migrate(name)
    %{store: name}
  end

  test "expires first, then enforces type, partition, item and byte quotas deterministically", %{
    store: store
  } do
    put(
      store,
      "a",
      "semantic",
      "expired",
      100,
      {"2020-01-01", "2020-01-01"},
      10,
      expires: "2025-01-01T00:00:00Z"
    )

    put(store, "a", "semantic", "type-low", 1, {"2020-01-01", "2020-01-01"}, 10)
    put(store, "a", "semantic", "type-high", 9, {"2020-01-01", "2020-01-01"}, 10)
    put(store, "a", "procedural", "priority-low", 1, {"2024-01-01", "2024-01-01"}, 10)
    put(store, "a", "procedural", "lru-old", 5, {"2020-01-01", "2024-01-01"}, 10)
    put(store, "a", "procedural", "updated-a", 5, {"2024-01-01", "2020-01-01"}, 10)
    put(store, "a", "procedural", "updated-b", 5, {"2024-01-01", "2020-01-01"}, 10)
    put(store, "b", "procedural", "keeper", 10, {"2025-01-01", "2025-01-01"}, 10)

    config = %{
      max_items: 3,
      max_bytes: 30,
      max_items_per_partition: 4,
      type_quotas: %{"semantic" => 1}
    }

    assert {:ok, %{expired: 1, evicted: 4}} =
             Eviction.enforce(store, config, now: ~U[2026-01-01 00:00:00Z])

    assert {:ok, %{rows: rows}} =
             Store.query(store, "SELECT canonical_id FROM edge_memories ORDER BY canonical_id")

    assert Enum.map(rows, & &1["canonical_id"]) == ["keeper", "type-high", "updated-b"]
  end

  test "tombstones count toward storage bounds, evict first, and stay outside type quotas", %{
    store: store
  } do
    put(store, "a", "semantic", "a", 1, {nil, nil}, 10)
    put(store, "a", "semantic", "b", 1, {nil, nil}, 10)
    put(store, "a", "semantic", "deleted", 0, {nil, nil}, 10, state: "deleted")

    assert {:ok, %{evicted: 2}} =
             Eviction.enforce(store, %{
               max_items: 1,
               max_bytes: 10,
               type_quotas: %{"semantic" => 2}
             })

    assert {:ok, %{rows: rows}} =
             Store.query(store, "SELECT canonical_id FROM edge_memories ORDER BY canonical_id")

    assert Enum.map(rows, & &1["canonical_id"]) == ["b"]
  end

  test "maximum age uses the supplied clock and eviction has no upstream command surface", %{
    store: store
  } do
    put(store, "a", "semantic", "age", 1, {nil, "2020-12-31T00:00:00"}, 10)

    assert {:ok, %{expired: 0}} =
             Eviction.enforce(store, %{max_items: 10, max_bytes: 100, max_age_seconds: 172_800},
               now: ~U[2021-01-01 00:00:00Z]
             )

    assert {:ok, %{expired: 1}} =
             Eviction.enforce(store, %{max_items: 10, max_bytes: 100, max_age_seconds: 172_800},
               now: ~U[2021-01-04 00:00:00Z]
             )

    assert {:ok, %{rows: []}} =
             Store.query(store, "SELECT name FROM sqlite_master WHERE name='memory_outbox'")
  end

  defp put(
         store,
         partition,
         type,
         id,
         priority,
         {accessed, updated},
         bytes,
         opts \\ []
       ) do
    expires = Keyword.get(opts, :expires)
    state = Keyword.get(opts, :state, "active")

    assert {:ok, _} =
             Store.execute(
               store,
               "INSERT INTO edge_partitions (memory_space_id,scope,namespace,active_generation) VALUES (?,?,?,'g') ON CONFLICT DO NOTHING",
               [partition, "scope", "private"]
             )

    assert {:ok, _} =
             Store.execute(
               store,
               """
               INSERT INTO edge_memories
                 (memory_space_id,scope,namespace,generation,canonical_id,memory_type,content,content_hash,
                  confidence,lifecycle_state,tags,metadata,source_refs,server_revision,edge_priority,
                  edge_expires_at,updated_at,last_accessed_at,byte_size)
               VALUES (?,?,'private','g',?,?,?, ?,1.0,?,'[]','{}','[]',1,?,?,?,?,?)
               """,
               [
                 partition,
                 "scope",
                 id,
                 type,
                 id,
                 id,
                 state,
                 priority,
                 expires,
                 updated,
                 accessed,
                 bytes
               ]
             )
  end
end

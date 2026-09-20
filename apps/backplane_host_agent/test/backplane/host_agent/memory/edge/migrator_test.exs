defmodule Backplane.HostAgent.Memory.Edge.MigratorTest do
  use ExUnit.Case, async: false
  alias Backplane.HostAgent.Memory.Edge.{Migrator, Store}
  alias Backplane.HostAgent.Memory.Mirror
  alias Backplane.Memory.EdgeSync.SnapshotBuilder
  alias Backplane.HostAgent.Memory.Edge.Migrations.V1
  @moduletag :tmp_dir

  test "does not accept or migrate a foreign database at any user version", %{tmp_dir: dir} do
    for {version, table} <- [
          {0, "facts"},
          {1, "commands"},
          {2, "capture_event_spool"},
          {3, "alien_rows"}
        ] do
      {:ok, store} =
        Store.start_link(
          database: Path.join(dir, "foreign-#{version}.db"),
          config: %{enabled: true, development_plaintext: true}
        )

      {:ok, _} = Store.execute(store, "CREATE TABLE #{table} (content TEXT)")
      {:ok, _} = Store.execute(store, "INSERT INTO #{table} VALUES ('keep')")
      {:ok, _} = Store.execute(store, "PRAGMA user_version = #{version}")
      assert {:error, :invalid_edge_schema} = Migrator.migrate(store)

      assert {:ok, %{rows: [%{"content" => "keep"}]}} =
               Store.query(store, "SELECT * FROM #{table}")

      assert {:ok, ^version} = Migrator.current_version(store)
      GenServer.stop(store)
    end
  end

  test "rejects a partial V1 lookalike without changing its version", %{tmp_dir: dir} do
    {:ok, store} =
      Store.start_link(
        database: Path.join(dir, "partial-v1.db"),
        config: %{enabled: true, development_plaintext: true}
      )

    Enum.each(V1.up() |> Enum.reject(&String.contains?(&1, "edge_snapshot_chunks")), fn sql ->
      assert {:ok, _} = Store.execute(store, sql)
    end)

    assert {:ok, _} = Store.execute(store, "PRAGMA user_version = 1")
    assert {:error, :invalid_edge_schema} = Migrator.migrate(store)
    assert {:ok, 1} = Migrator.current_version(store)

    assert {:ok, %{rows: []}} =
             Store.query(
               store,
               "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'edge_snapshot_chunks'"
             )

    GenServer.stop(store)
  end

  test "rejects V1 through V3 lookalikes with invalid column contracts unchanged", %{tmp_dir: dir} do
    mutations = [
      {:wrong_type, "applied_revision INTEGER NOT NULL DEFAULT 0",
       "applied_revision TEXT NOT NULL DEFAULT 0"},
      {:missing_not_null, "memory_space_id TEXT NOT NULL", "memory_space_id TEXT"},
      {:wrong_default, "applied_revision INTEGER NOT NULL DEFAULT 0",
       "applied_revision INTEGER NOT NULL DEFAULT 1"},
      {:wrong_primary_key, "PRIMARY KEY (memory_space_id, scope, namespace)",
       "PRIMARY KEY (memory_space_id, scope)"}
    ]

    for version <- [1, 2, 3], {name, source, replacement} <- mutations do
      {:ok, store} =
        Store.start_link(
          database: Path.join(dir, "#{version}-#{name}.db"),
          config: %{enabled: true, development_plaintext: true}
        )

      Enum.each(V1.up(), fn sql ->
        assert {:ok, _} = Store.execute(store, String.replace(sql, source, replacement))
      end)

      if version >= 2 do
        Enum.each(Backplane.HostAgent.Memory.Edge.Migrations.V2.up(), fn sql ->
          assert {:ok, _} = Store.execute(store, sql)
        end)
      end

      if version == 3 do
        Enum.each(Backplane.HostAgent.Memory.Edge.Migrations.V3.up(), fn sql ->
          assert {:ok, _} = Store.execute(store, sql)
        end)
      end

      assert {:ok, _} = Store.execute(store, "PRAGMA user_version = #{version}")

      assert {:ok, _} =
               Store.execute(
                 store,
                 "INSERT INTO edge_partitions (memory_space_id, scope, namespace) VALUES ('keep', 'scope', 'ns')"
               )

      assert {:error, :invalid_edge_schema} = Migrator.validate_schema(store)
      assert {:error, :invalid_edge_schema} = Migrator.migrate(store)
      assert {:ok, ^version} = Migrator.current_version(store)

      assert {:ok, %{rows: [%{"memory_space_id" => "keep"}]}} =
               Store.query(store, "SELECT memory_space_id FROM edge_partitions")

      GenServer.stop(store)
    end
  end

  test "fresh edge storage reaches V3 and repeat migration is idempotent", %{tmp_dir: dir} do
    {:ok, store} =
      Store.start_link(
        database: Path.join(dir, "fresh.db"),
        config: %{enabled: true, development_plaintext: true}
      )

    assert :ok = Migrator.migrate(store)
    assert {:ok, 3} = Migrator.current_version(store)
    assert :ok = Migrator.migrate(store)
    assert {:ok, 3} = Migrator.current_version(store)
    GenServer.stop(store)
  end

  test "rejects a V3 received-item counter with a corrupted contract", %{tmp_dir: dir} do
    {:ok, store} =
      Store.start_link(
        database: Path.join(dir, "invalid-v3.db"),
        config: %{enabled: true, development_plaintext: true}
      )

    for migration <- [V1, Backplane.HostAgent.Memory.Edge.Migrations.V2] do
      Enum.each(migration.up(), fn sql -> assert {:ok, _} = Store.execute(store, sql) end)
    end

    [counter | _cleanup] = Backplane.HostAgent.Memory.Edge.Migrations.V3.up()
    assert {:ok, _} = Store.execute(store, String.replace(counter, "DEFAULT 0", "DEFAULT 1"))
    assert {:ok, _} = Store.execute(store, "PRAGMA user_version = 3")

    assert {:error, :invalid_edge_schema} = Migrator.validate_schema(store)
    assert {:error, :invalid_edge_schema} = Migrator.migrate(store)
    assert {:ok, 3} = Migrator.current_version(store)
    GenServer.stop(store)
  end

  test "V3 discards an interrupted V2 snapshot and accepts a complete recovery snapshot", %{
    tmp_dir: dir
  } do
    opts = [
      database: Path.join(dir, "partial-v2.db"),
      config: %{enabled: true, development_plaintext: true}
    ]

    {:ok, store} = Store.start_link(opts)

    for migration <- [V1, Backplane.HostAgent.Memory.Edge.Migrations.V2] do
      Enum.each(migration.up(), fn sql -> assert {:ok, _} = Store.execute(store, sql) end)
    end

    assert {:ok, _} = Store.execute(store, "PRAGMA user_version = 2")

    assert {:ok, _} =
             Store.execute(store, """
             INSERT INTO edge_partitions
               (memory_space_id,scope,namespace,applied_revision,active_generation,last_batch_id,
                snapshot_id,snapshot_revision,next_chunk_index,chunk_count,integrity_hash,
                sync_status,last_delivery_hash)
             VALUES ('space','scope','ns',5,'active','partial-batch','partial',9,1,2,
                     'sha256:partial','ready','sha256:delivery')
             """)

    for {generation, id, revision} <- [{"active", "old", 5}, {"partial", "staged", 9}] do
      assert {:ok, _} =
               Store.execute(
                 store,
                 "INSERT INTO edge_memories (memory_space_id,scope,namespace,generation,canonical_id,lifecycle_state,server_revision) VALUES ('space','scope','ns',?,?, 'active',?)",
                 [generation, id, revision]
               )
    end

    assert {:ok, _} =
             Store.execute(
               store,
               "INSERT INTO edge_snapshot_chunks VALUES ('partial',0,'sha256:chunk','2026-09-20T00:00:00Z')"
             )

    assert :ok = Migrator.migrate(store)

    assert {:ok,
            %{
              rows: [
                %{
                  "snapshot_id" => nil,
                  "sync_status" => "snapshot_required",
                  "snapshot_received_items" => 0,
                  "last_batch_id" => nil,
                  "last_delivery_hash" => nil
                }
              ]
            }} =
             Store.query(
               store,
               "SELECT snapshot_id,sync_status,snapshot_received_items,last_batch_id,last_delivery_hash FROM edge_partitions"
             )

    assert {:ok, %{rows: [%{"canonical_id" => "old"}]}} =
             Store.query(store, "SELECT canonical_id FROM edge_memories")

    assert {:ok, %{rows: []}} = Store.query(store, "SELECT * FROM edge_snapshot_chunks")

    item = %{
      "canonical_id" => "new",
      "memory_type" => "semantic",
      "content" => "recovered",
      "content_hash" => "hash",
      "confidence" => 0.8,
      "edge_priority" => 0.8,
      "lifecycle_state" => "active",
      "tags" => [],
      "metadata" => %{},
      "expires_at" => nil,
      "updated_at" => "2026-09-20T00:00:00Z"
    }

    chunk_hash = SnapshotBuilder.hash(%{"items" => [item]})
    integrity_hash = "sha256:" <> Base.encode16(:crypto.hash(:sha256, [chunk_hash]), case: :lower)

    delivery = %{
      "protocol" => "host_memory.v2",
      "status" => "batch",
      "kind" => "snapshot_chunk",
      "batch_id" => "recovery-batch",
      "partition" => %{"memory_space_id" => "space", "scope" => "scope", "namespace" => "ns"},
      "snapshot_id" => "recovery",
      "chunk_index" => 0,
      "chunk_count" => 1,
      "item_count" => 1,
      "base_revision" => 5,
      "to_revision" => 9,
      "chunk_hash" => chunk_hash,
      "integrity_hash" => integrity_hash,
      "items" => [item]
    }

    assert {:ok, %{"status" => "applied", "applied_revision" => 9}} =
             Mirror.apply_delivery(delivery, store: store, config: opts[:config])

    assert {:ok, %{rows: [%{"canonical_id" => "new"}]}} =
             Store.query(store, "SELECT canonical_id FROM edge_memories")

    GenServer.stop(store)
  end

  test "upgrades a V1 edge database to V3 without losing canonical state", %{tmp_dir: dir} do
    opts = [
      database: Path.join(dir, "edge.db"),
      config: %{enabled: true, development_plaintext: true}
    ]

    {:ok, store} = Store.start_link(opts)
    # Build an actual V1 database so this test proves the upgrade path, rather
    # than only proving fresh creation.
    Enum.each(V1.up(), fn sql -> assert {:ok, _} = Store.execute(store, sql) end)
    assert {:ok, _} = Store.execute(store, "PRAGMA user_version = 1")

    assert {:ok, _} =
             Store.execute(store, """
             INSERT INTO edge_partitions
               (memory_space_id, scope, namespace, applied_revision, active_generation)
               VALUES ('space', 'scope', 'ns', 6, 'old-generation')
             """)

    assert {:ok, _} =
             Store.execute(store, """
             INSERT INTO edge_memories
               (memory_space_id, scope, namespace, generation, canonical_id, lifecycle_state, server_revision)
               VALUES ('space', 'scope', 'ns', 'generation', 'id', 'deleted', 7)
             """)

    assert {:ok, _} =
             Store.execute(
               store,
               "INSERT INTO edge_snapshot_chunks VALUES ('snapshot', 0, 'chunk-hash', '2026-09-20T00:00:00Z')"
             )

    assert :ok = Migrator.migrate(store)
    assert {:ok, 3} = Migrator.current_version(store)

    assert {:ok,
            %{
              rows: [
                %{
                  "sync_status" => nil,
                  "last_delivery_hash" => nil,
                  "snapshot_received_items" => 0,
                  "applied_revision" => 6,
                  "active_generation" => "old-generation"
                }
              ]
            }} =
             Store.query(
               store,
               "SELECT sync_status, last_delivery_hash, snapshot_received_items, applied_revision, active_generation FROM edge_partitions"
             )

    assert {:ok, %{rows: [%{"content" => nil, "server_revision" => 7}]}} =
             Store.query(store, "SELECT content, server_revision FROM edge_memories")

    assert {:ok, %{rows: [%{"chunk_hash" => "chunk-hash"}]}} =
             Store.query(store, "SELECT chunk_hash FROM edge_snapshot_chunks")

    assert {:ok, %{rows: rows}} =
             Store.query(store, "SELECT name FROM sqlite_master WHERE type = 'table'")

    assert Enum.sort(Enum.map(rows, & &1["name"])) ==
             ["edge_memories", "edge_partitions", "edge_snapshot_chunks"]

    GenServer.stop(store)
    {:ok, store} = Store.start_link(opts)
    assert :ok = Migrator.migrate(store)
    assert {:ok, 3} = Migrator.current_version(store)

    assert {:ok, %{rows: [%{"server_revision" => 7}]}} =
             Store.query(store, "SELECT server_revision FROM edge_memories")

    GenServer.stop(store)
  end
end

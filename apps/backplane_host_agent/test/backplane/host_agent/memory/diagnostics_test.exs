defmodule Backplane.HostAgent.Memory.DiagnosticsTest do
  use ExUnit.Case, async: false

  alias Backplane.HostAgent.Memory.{Diagnostics, Migrator, Reducer, Store}
  alias Turso.Result

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    store = start_memory!(tmp_dir)
    {:ok, store: store}
  end

  test "snapshot works before the edge telemetry module is loaded", %{tmp_dir: tmp_dir} do
    script = """
    {:ok, _} = Application.ensure_all_started(:ex_turso)
    {:ok, store} = Backplane.HostAgent.Memory.Store.start_link(
      database: System.fetch_env!("BACKPLANE_DIAGNOSTICS_TEST_DB"), pool_size: 1)
    :ok = Backplane.HostAgent.Memory.Migrator.migrate(store)
    false = :code.is_loaded(Backplane.HostAgent.Memory.Edge.Telemetry)
    {:ok, snapshot} = Backplane.HostAgent.Memory.Diagnostics.snapshot(store: store)
    nil = snapshot["edge"]["lag"]
    "unavailable" = snapshot["edge"]["lag_status"]
    0 = snapshot["edge"]["dead_letter_count"]
    GenServer.stop(store)
    IO.puts("cold diagnostics snapshot ok")
    """

    paths = Enum.flat_map(:code.get_path(), &["-pa", List.to_string(&1)])
    elixir = System.find_executable("elixir") || flunk("elixir is required")

    {output, status} =
      System.cmd(elixir, paths ++ ["-e", script],
        env: [{"BACKPLANE_DIAGNOSTICS_TEST_DB", Path.join(tmp_dir, "cold-diagnostics.db")}],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "cold diagnostics snapshot ok"
  end

  test "snapshot reports store, sync, facts, tombstones, and recovery state", %{store: store} do
    insert_memory!(store, "pending_memory", "pending", sync_state: "pending")

    insert_memory!(
      store,
      "synced_memory",
      "synced",
      sync_state: "synced",
      synced_at: "2026-06-16T00:00:00Z"
    )

    insert_memory!(store, "dead_memory", "dead", sync_state: "pending")
    pending_seq = insert_outbox!(store, "remember", "pending_memory", "pending")

    failed_seq =
      insert_outbox!(store, "remember", "dead_memory", "dead_letter", "validation failed")

    insert_fact!(store, "fact_1", "fact content", "proj_local", "2026-06-17T00:00:00Z")
    insert_fact!(store, "fact_2", "other fact", "other_scope", "2026-06-15T00:00:00Z")
    insert_tombstone!(store, "wiped")

    assert {:ok,
            %{
              "store" => %{"status" => "ok", "db_path" => "/tmp/memory.db"},
              "memories" => %{"pending" => 2, "synced" => 1},
              "outbox" => %{"pending" => 1, "dead_letter" => 1},
              "oldest_pending_seq" => ^pending_seq,
              "failed_outbox" => [
                %{
                  "seq" => ^failed_seq,
                  "memory_id" => "dead_memory",
                  "op" => "remember",
                  "last_error" => "validation failed"
                }
              ],
              "facts" => %{
                "count" => 2,
                "scopes" => fact_scopes
              },
              "tombstones" => 1,
              "last_successful_sync" => "2026-06-16T00:00:00Z",
              "last_reconcile_at" => "2026-06-17T00:00:00Z"
            }} = Diagnostics.snapshot(store: store, db_path: "/tmp/memory.db")

    assert [
             %{"scope" => "other_scope", "count" => 1},
             %{"scope" => "proj_local", "count" => 1}
           ] = fact_scopes
  end

  test "snapshot reports the edge protection decision without opening edge storage", %{
    store: store
  } do
    assert {:ok, %{"edge_protection" => "protection_unavailable"}} =
             Diagnostics.snapshot(
               store: store,
               host_sync: %{enabled: true, development_plaintext: false}
             )
  end

  test "snapshot reports active edge bounds, staleness, and command retry health without content",
       %{store: store, tmp_dir: dir} do
    insert_memory!(store, "retry", "retry", sync_state: "pending")
    insert_outbox!(store, "remember", "retry", "retry_wait", "temporary")
    insert_memory!(store, "dead", "dead", sync_state: "pending")
    insert_outbox!(store, "remember", "dead", "dead_letter", "permanent")

    {:ok, edge} =
      Backplane.HostAgent.Memory.Edge.Store.start_link(
        database: Path.join(dir, "edge.db"),
        config: %{enabled: true, development_plaintext: true}
      )

    Process.unlink(edge)
    :ok = Backplane.HostAgent.Memory.Edge.Migrator.migrate(edge)
    last_sync = DateTime.utc_now() |> DateTime.add(-5) |> DateTime.to_iso8601()
    older_sync = DateTime.utc_now() |> DateTime.add(-12) |> DateTime.to_iso8601()

    assert {:ok, _} =
             Backplane.HostAgent.Memory.Edge.Store.execute(
               edge,
               "INSERT INTO edge_partitions (memory_space_id,scope,namespace,active_generation,applied_revision,last_sync_at) VALUES ('space','scope','private','g',7,?)",
               [last_sync]
             )

    assert {:ok, _} =
             Backplane.HostAgent.Memory.Edge.Store.execute(
               edge,
               "INSERT INTO edge_partitions (memory_space_id,scope,namespace,active_generation,applied_revision,last_sync_at) VALUES ('older','scope','private','g',6,?)",
               [older_sync]
             )

    assert {:ok, _} =
             Backplane.HostAgent.Memory.Edge.Store.execute(
               edge,
               "INSERT INTO edge_memories (memory_space_id,scope,namespace,generation,canonical_id,lifecycle_state,server_revision,byte_size,content) VALUES ('space','scope','private','g','id','active',7,42,'secret content')"
             )

    assert {:ok, _} =
             Backplane.HostAgent.Memory.Edge.Store.execute(
               edge,
               "INSERT INTO edge_memories (memory_space_id,scope,namespace,generation,canonical_id,lifecycle_state,server_revision,byte_size,content) VALUES ('space','scope','private','staging','future','active',99,999,'staged secret')"
             )

    assert {:ok, %{"edge" => metrics}} =
             Diagnostics.snapshot(
               store: store,
               edge_store: edge,
               host_sync: %{enabled: true, development_plaintext: true}
             )

    assert %{
             "items" => 1,
             "bytes" => 42,
             "revision" => 7,
             "lag" => nil,
             "lag_status" => "unavailable",
             "retry_count" => 1,
             "dead_letter_count" => 1,
             "stale_age_seconds" => age,
             "partitions" => partitions
           } = metrics

    assert age in 11..14

    assert [
             %{"last_sync_at" => ^older_sync, "stale_age_seconds" => older_age},
             %{"last_sync_at" => ^last_sync, "stale_age_seconds" => newer_age}
           ] = partitions

    assert older_age in 11..14
    assert newer_age in 4..7
    refute inspect(metrics) =~ "secret content"
    GenServer.stop(edge)
  end

  test "unavailable edge storage is fault-contained and does not claim a known lag", %{
    store: store,
    tmp_dir: dir
  } do
    {:ok, edge} =
      Backplane.HostAgent.Memory.Edge.Store.start_link(
        database: Path.join(dir, "gone.db"),
        config: %{enabled: true, development_plaintext: true}
      )

    Process.unlink(edge)
    GenServer.stop(edge)

    assert {:ok,
            %{
              "edge" => %{"items" => 0, "bytes" => 0, "lag" => nil, "lag_status" => "unavailable"}
            }} =
             Diagnostics.snapshot(
               store: store,
               edge_store: edge,
               host_sync: %{enabled: true, development_plaintext: true}
             )
  end

  test "diagnostic metadata is capped without truncating counters or global revision", %{
    store: store,
    tmp_dir: dir
  } do
    for n <- 1..52 do
      id = "bounded-#{n}"
      insert_memory!(store, id, "content #{n}", sync_state: "pending")
      insert_outbox!(store, "remember", id, "dead_letter", "failure")
    end

    {:ok, edge} =
      Backplane.HostAgent.Memory.Edge.Store.start_link(
        database: Path.join(dir, "bounded-edge.db"),
        config: %{enabled: true, development_plaintext: true}
      )

    Process.unlink(edge)
    on_exit(fn -> if Process.alive?(edge), do: GenServer.stop(edge) end)
    :ok = Backplane.HostAgent.Memory.Edge.Migrator.migrate(edge)

    for n <- 1..52 do
      {:ok, _} =
        Backplane.HostAgent.Memory.Edge.Store.execute(
          edge,
          "INSERT INTO edge_partitions (memory_space_id,scope,namespace,active_generation,applied_revision,last_sync_at) VALUES (?,'private','private','g',?,?)",
          ["space-#{n}", n, DateTime.utc_now() |> DateTime.add(-n) |> DateTime.to_iso8601()]
        )
    end

    opts = [
      store: store,
      edge_store: edge,
      host_sync: %{enabled: true, development_plaintext: true}
    ]

    assert {:ok, snapshot} = Diagnostics.snapshot(opts)
    assert length(snapshot["failed_outbox"]) == 50
    assert length(snapshot["edge"]["partitions"]) == 50
    assert snapshot["outbox"]["dead_letter"] == 52
    assert snapshot["edge"]["revision"] == 52
    assert snapshot["edge"]["status"] == "available"
    assert {:ok, bounded} = Diagnostics.snapshot(Keyword.put(opts, :metadata_limit, 2))
    assert length(bounded["failed_outbox"]) == 2
    assert length(bounded["edge"]["partitions"]) == 2
    assert bounded["edge"]["revision"] == 52
    assert bounded["edge"]["stale_age_seconds"] in 51..55
    assert {:ok, unavailable} = Diagnostics.snapshot(store: store)
    assert unavailable["edge"]["status"] == "unavailable"
  end

  test "recovery helpers requeue dead-letter rows and purge tombstones explicitly", %{
    store: store
  } do
    insert_memory!(store, "dead_memory", "dead", sync_state: "pending")
    insert_outbox!(store, "remember", "dead_memory", "dead_letter", "validation failed")
    insert_tombstone!(store, "wiped")

    assert {:ok, %{"requeued" => 1}} = Diagnostics.requeue_failed_outbox(store: store)

    assert {:ok, %Result{rows: [%{"state" => "pending", "last_error" => nil}]}} =
             Store.query(store, "SELECT state, last_error FROM memory_outbox")

    assert {:ok, %{"purged" => 1}} = Diagnostics.purge_tombstones(store: store)
    assert_count(store, "tombstones", 0)
  end

  test "migration diagnostics preserve quarantine and ordinary recovery cannot replay it", %{
    store: store
  } do
    assert {:ok, _} =
             Store.execute(
               store,
               "INSERT INTO memory_outbox(op,memory_id,state,attempts,inserted_at,updated_at,migration_state,migration_reason) VALUES ('remember','historical','dead_letter',2,'old','old','inflight','needs_verified_receipt_and_authority_mapping')"
             )

    assert {:ok, snapshot} = Diagnostics.snapshot(store: store)
    assert snapshot["command_migration"] == %{"needs_verified_receipt_and_authority_mapping" => 1}
    assert [%{"migration_state" => "inflight", "attempts" => 2}] = snapshot["failed_outbox"]
    assert {:ok, %{"requeued" => 0}} = Diagnostics.requeue_failed_outbox(store: store)

    assert {:ok, %{rows: [%{"state" => "dead_letter", "attempts" => 2, "updated_at" => "old"}]}} =
             Store.query(store, "SELECT state,attempts,updated_at FROM memory_outbox")
  end

  test "requeues only selected dead-letter rows and resets retry state", %{store: store} do
    insert_memory!(store, "first", "first", sync_state: "pending")
    first = insert_outbox!(store, "remember", "first", "dead_letter", "bad")
    insert_memory!(store, "second", "second", sync_state: "pending")
    insert_outbox!(store, "remember", "second", "dead_letter", "bad")

    assert {:ok, %{"requeued" => 1}} =
             Diagnostics.requeue_failed_outbox(store: store, seqs: [first])

    assert {:ok, %Result{rows: rows}} =
             Store.query(
               store,
               "SELECT state, attempts, last_error, dead_lettered_at FROM memory_outbox ORDER BY seq"
             )

    assert [
             %{
               "state" => "pending",
               "attempts" => 0,
               "last_error" => nil,
               "dead_lettered_at" => nil
             },
             %{"state" => "dead_letter"}
           ] = rows
  end

  test "targeted diagnostics use owner pools and return only bounded transport metadata", %{
    store: store,
    tmp_dir: dir
  } do
    id = "11111111-1111-4111-8111-111111111111"
    event = "22222222-2222-4222-8222-222222222222"

    partition = %{
      "memory_space_id" => "33333333-3333-4333-8333-333333333333",
      "scope" => "proj_local",
      "namespace" => "private"
    }

    insert_memory!(store, id, "private diagnostic memory", sync_state: "pending")
    insert_outbox!(store, "remember", id, "pending")
    insert_tombstone!(store, "private tombstone")

    {:ok, edge} =
      Backplane.HostAgent.Memory.Edge.Store.start_link(
        database: Path.join(dir, "targeted-edge.db"),
        name: Backplane.HostAgent.Memory.Edge.Store,
        config: %{enabled: true, development_plaintext: true}
      )

    Process.unlink(edge)
    on_exit(fn -> if Process.alive?(edge), do: GenServer.stop(edge) end)
    :ok = Backplane.HostAgent.Memory.Edge.Migrator.migrate(edge)

    {:ok, _} =
      Store.execute(
        edge,
        "INSERT INTO edge_partitions (memory_space_id,scope,namespace,active_generation,applied_revision) VALUES (?,?,'private','0',7)",
        [partition["memory_space_id"], partition["scope"]]
      )

    {:ok, _} =
      Store.execute(
        edge,
        "INSERT INTO edge_memories (memory_space_id,scope,namespace,generation,canonical_id,lifecycle_state,server_revision,byte_size,content) VALUES (?,?,'private','0',?,'active',7,42,'private mirror')",
        [partition["memory_space_id"], partition["scope"], id]
      )

    {:ok, spool} =
      Backplane.HostAgent.Memory.Spool.Turso.start_link(
        database: Path.join(dir, "targeted-capture.db"),
        name: nil
      )

    Process.unlink(spool)
    on_exit(fn -> if Process.alive?(spool), do: GenServer.stop(spool) end)

    opts = [
      store: store,
      config: %{enabled: true, bound_scope: "proj_local"},
      capture_runtime: %{spool: spool},
      edge_context: fn claims ->
        if claims == partition,
          do: {:ok, %{edge_partition: partition, edge_store: edge}},
          else: {:error, :partition_mismatch}
      end
    ]

    request = %{
      "partition" => partition,
      "command_ids" => [id],
      "event_ids" => [event],
      "mirror_ids" => [id]
    }

    assert {:ok, result} = Diagnostics.targeted(request, opts)
    assert result["observation_source"] == "owner_connection"

    assert [%{"id" => ^id, "sync_state" => "pending", "deleted" => false}] =
             result["commands"]["memories"]

    assert [%{"memory_id" => ^id, "state" => "pending", "attempts" => 0}] =
             result["commands"]["outbox"]

    assert result["capture"] == %{"rows" => [], "expected" => 1, "missing_or_compacted" => 1}
    assert result["mirror"]["active_target_ids"] == [id]
    assert result["mirror"]["partition"]["applied_revision"] == 7
    # Worker supplies only mirror config, so read_context returns no explicit pool.
    default_context =
      Keyword.put(opts, :edge_context, fn ^partition ->
        {:ok, %{edge_partition: partition, edge_store: nil}}
      end)

    assert {:ok, ^result} = Diagnostics.targeted(request, default_context)
    assert result["tombstones"]["count"] == 1
    assert String.length(result["tombstones"]["digest"]) == 64
    refute inspect(result) =~ "private diagnostic"
    refute inspect(result) =~ "private mirror"
    refute inspect(result) =~ "content_hash"
    refute inspect(result) =~ "db_path"

    assert {:error, :invalid_diagnostic_request} =
             Diagnostics.targeted(Map.put(request, "sql", "SELECT 1"), opts)

    assert {:error, :invalid_diagnostic_request} =
             Diagnostics.targeted(Map.put(request, "command_ids", List.duplicate(id, 33)), opts)

    assert {:error, :diagnostic_partition_mismatch} =
             Diagnostics.targeted(put_in(request, ["partition", "scope"], "foreign"), opts)

    unavailable = Keyword.put(opts, :edge_context, fn _ -> {:error, :mirror_unavailable} end)
    assert {:error, :diagnostic_unavailable} = Diagnostics.targeted(request, unavailable)
  end

  test "shared diagnostics require explicit opt-in and preserve the default four fields", %{
    store: store
  } do
    alias Backplane.HostAgent.Memory.Access
    alias Backplane.HostAgent.Memory.Edge.Syncer, as: EdgeSyncer

    owner = start_supervised!({Access, name: nil, store: store})
    syncer = start_supervised!({EdgeSyncer, name: nil, poll_interval_ms: 1_234})
    id = "11111111-1111-4111-8111-111111111111"

    inventory = %{
      "extensions" => ["memory_access.v1"],
      "default_access_id" => id,
      "accesses" => [
        %{
          "access_id" => id,
          "authority_version" => 1,
          "status" => "active",
          "partition" => %{
            "memory_space_id" => "22222222-2222-4222-8222-222222222222",
            "scope" => "shared",
            "namespace" => "private"
          },
          "capabilities" => ["read"],
          "offline_read_lease_seconds" => 0
        }
      ]
    }

    assert :ok =
             Access.install_inventory(
               %{id: 1, channel: self(), sent_at_ms: System.monotonic_time(:millisecond)},
               inventory,
               owner
             )

    request = %{"memory_access_id" => id, "command_ids" => [], "mirror_ids" => []}
    opts = [access_server: owner, edge_syncer: syncer]
    assert {:ok, original} = Diagnostics.targeted(request, opts)
    assert Enum.sort(Map.keys(original)) == ~w(access commands mirror observation_source)

    assert {:ok, ^original} =
             Diagnostics.targeted(Map.put(request, "include_edge_sync", false), opts)

    assert {:ok, extended} =
             Diagnostics.targeted(Map.put(request, "include_edge_sync", true), opts)

    assert Map.delete(extended, "edge_sync") == original

    assert %{"status" => "available", "poll_interval_ms" => 1_234, "last_poll_result" => "never"} =
             extended["edge_sync"]

    for invalid <- [nil, "true", 1, %{}] do
      assert {:error, :invalid_diagnostic_request} =
               Diagnostics.targeted(Map.put(request, "include_edge_sync", invalid), opts)
    end

    assert {:error, :invalid_diagnostic_request} =
             Diagnostics.targeted(
               Map.merge(request, %{"include_edge_sync" => true, "eval" => "secret"}),
               opts
             )

    GenServer.stop(syncer)

    assert {:ok, unavailable} =
             Diagnostics.targeted(Map.put(request, "include_edge_sync", true), opts)

    assert unavailable["edge_sync"] == %{"status" => "unavailable"}
  end

  defp start_memory!(tmp_dir) do
    name = :"host_agent_memory_diagnostics_#{System.unique_integer([:positive])}"
    db_path = Path.join(tmp_dir, "#{name}.db")

    start_supervised!(
      {Store, database: db_path, name: name, pool_size: 1, busy_timeout_ms: 5_000}
    )

    assert :ok = Migrator.migrate(name)
    name
  end

  defp insert_memory!(store, id, content, opts) do
    now = "2026-06-17T00:00:00Z"
    synced_at = Keyword.get(opts, :synced_at)

    assert {:ok, _} =
             Store.execute(
               store,
               """
               INSERT INTO memories(
                 id, content, content_hash, scope, agent_id, tags, metadata,
                 sync_state, synced_at, inserted_at, updated_at
               )
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
               """,
               [
                 id,
                 content,
                 Reducer.content_hash(content),
                 "proj_local",
                 "agent_1",
                 "[]",
                 "{}",
                 Keyword.fetch!(opts, :sync_state),
                 synced_at,
                 now,
                 now
               ]
             )
  end

  defp insert_outbox!(store, op, memory_id, state, last_error \\ nil) do
    now = "2026-06-17T00:00:00Z"

    assert {:ok, _} =
             Store.execute(
               store,
               """
               INSERT INTO memory_outbox(op, memory_id, state, last_error, inserted_at, updated_at, access_id)
               VALUES (?, ?, ?, ?, ?, ?, '11111111-1111-4111-8111-111111111111')
               """,
               [op, memory_id, state, last_error, now, now]
             )

    assert {:ok, %Result{rows: [%{"seq" => seq}]}} =
             Store.query(store, "SELECT seq FROM memory_outbox WHERE memory_id = ?", [memory_id])

    seq
  end

  defp insert_fact!(store, id, content, scope, updated_at) do
    assert {:ok, _} =
             Store.execute(
               store,
               """
               INSERT INTO facts(id, content, content_hash, scope, tags, metadata, updated_at)
               VALUES (?, ?, ?, ?, ?, ?, ?)
               """,
               [id, content, Reducer.content_hash(content), scope, "[]", "{}", updated_at]
             )
  end

  defp insert_tombstone!(store, content) do
    assert {:ok, _} =
             Store.execute(
               store,
               """
               INSERT INTO tombstones(content_hash, scope, wiped_at, directive_id)
               VALUES (?, ?, ?, ?)
               """,
               [Reducer.content_hash(content), "proj_local", "2026-06-17T00:00:00Z", "wipe_1"]
             )
  end

  defp assert_count(store, table, expected) do
    assert {:ok, %Result{rows: [%{"count" => ^expected}]}} =
             Store.query(store, "SELECT COUNT(*) AS count FROM #{table}")
  end
end

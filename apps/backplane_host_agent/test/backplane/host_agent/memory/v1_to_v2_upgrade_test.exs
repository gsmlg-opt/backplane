defmodule Backplane.HostAgent.Memory.V1ToV2UpgradeTest do
  use ExUnit.Case, async: false

  alias Backplane.HostAgent.Memory.{Migrator, Store}
  alias Backplane.HostAgent.Memory.Migrations.V1
  alias Backplane.HostAgent.Memory.Edge
  alias Backplane.HostAgent.Memory.Edge.Migrations.V1, as: EdgeV1

  @moduletag :tmp_dir
  @now "2026-09-01T00:00:00Z"

  test "populated command V1 survives V2 and V3 with tombstones, sequence and remote identity", %{
    tmp_dir: dir
  } do
    store =
      start_supervised!(
        {Store,
         database: Path.join(dir, "commands.db"), name: unique_name(:commands), pool_size: 1}
      )

    assert {:ok, _} =
             Store.transaction(store, fn conn ->
               Enum.each(V1.up(), fn sql -> assert {:ok, _} = Store.execute(conn, sql) end)
               assert {:ok, _} = Store.execute(conn, "PRAGMA user_version = 1")
             end)

    assert {:ok, _} =
             Store.execute(
               store,
               "INSERT INTO memories(id,content,content_hash,scope,agent_id,session_id,tags,metadata,confidence,remote_id,synced_at,sync_state,inserted_at,updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
               [
                 "local-1",
                 "remember",
                 String.duplicate("a", 64),
                 "project",
                 "agent",
                 "session-1",
                 ~s|["important"]|,
                 ~s|{"source":"legacy"}|,
                 0.75,
                 "canonical-1",
                 @now,
                 "synced",
                 @now,
                 @now
               ]
             )

    assert {:ok, _} =
             Store.execute(
               store,
               "INSERT INTO tombstones(content_hash,scope,wiped_at,directive_id) VALUES (?,?,?,?)",
               [String.duplicate("a", 64), "project", @now, "wipe-1"]
             )

    for {state, seq} <- Enum.with_index(~w(pending inflight done failed), 1) do
      assert {:ok, _} =
               Store.execute(
                 store,
                 "INSERT INTO memory_outbox(seq,op,memory_id,state,attempts,last_error,inserted_at,updated_at) VALUES (?,'remember',?,?,?,?,?,?)",
                 [seq, "local-1", state, seq, "error-#{seq}", @now, @now]
               )
    end

    assert {:ok, _} =
             Store.execute(
               store,
               "INSERT INTO memory_outbox(seq,op,memory_id,state,attempts,inserted_at,updated_at) VALUES (20,'forget','local-1','done',1,?,?)",
               [@now, @now]
             )

    assert {:ok, _} = Store.execute(store, "DELETE FROM memory_outbox WHERE seq=20")

    assert :ok = Migrator.migrate(store)
    assert {:ok, 3} = Migrator.current_version(store)

    assert {:ok,
            %{
              rows: [
                %{
                  "id" => "local-1",
                  "content" => "remember",
                  "scope" => "project",
                  "session_id" => "session-1",
                  "tags" => ~s|["important"]|,
                  "metadata" => ~s|{"source":"legacy"}|,
                  "confidence" => 0.75,
                  "remote_id" => "canonical-1",
                  "remote_revision" => nil,
                  "synced_at" => @now,
                  "sync_state" => "synced"
                }
              ]
            }} =
             Store.query(
               store,
               "SELECT id,content,scope,session_id,tags,metadata,confidence,remote_id,remote_revision,synced_at,sync_state FROM memories"
             )

    assert {:ok,
            %{
              rows: [
                %{
                  "content_hash" => hash,
                  "scope" => "project",
                  "wiped_at" => @now,
                  "directive_id" => "wipe-1"
                }
              ]
            }} =
             Store.query(store, "SELECT content_hash,scope,wiped_at,directive_id FROM tombstones")

    assert hash == String.duplicate("a", 64)

    assert {:ok, %{rows: rows}} =
             Store.query(
               store,
               "SELECT seq,op,memory_id,state,attempts,last_error,completed_at,dead_lettered_at,inserted_at,updated_at FROM memory_outbox ORDER BY seq"
             )

    assert Enum.map(rows, & &1["state"]) == ~w(pending inflight done dead_letter)
    assert Enum.map(rows, & &1["seq"]) == [1, 2, 3, 4]
    assert Enum.map(rows, & &1["attempts"]) == [1, 2, 3, 4]
    assert Enum.map(rows, & &1["last_error"]) == Enum.map(1..4, &"error-#{&1}")
    assert Enum.all?(rows, &(&1["op"] == "remember" and &1["memory_id"] == "local-1"))
    assert Enum.all?(rows, &(&1["inserted_at"] == @now and &1["updated_at"] == @now))
    assert Enum.at(rows, 2)["completed_at"] == @now
    assert Enum.at(rows, 3)["dead_lettered_at"] == @now

    assert {:ok, _} =
             Store.execute(
               store,
               "INSERT INTO memory_outbox(op,memory_id,inserted_at,updated_at) VALUES ('forget','local-1',?,?)",
               [@now, @now]
             )

    assert {:ok, %{rows: [%{"seq" => 21}]}} =
             Store.query(
               store,
               "SELECT seq FROM memory_outbox WHERE op='forget'"
             )

    assert :ok = Migrator.migrate(store)

    assert {:ok, %{rows: [%{"count" => 5}]}} =
             Store.query(
               store,
               "SELECT count(*) AS count FROM memory_outbox"
             )
  end

  test "separate populated edge V1 preserves active canonical rows and resets interrupted snapshot at V3",
       %{tmp_dir: dir} do
    store =
      start_supervised!(
        {Edge.Store,
         database: Path.join(dir, "edge.db"),
         config: %{enabled: true, development_plaintext: true}}
      )

    Enum.each(EdgeV1.up(), fn sql -> assert {:ok, _} = Edge.Store.execute(store, sql) end)
    assert {:ok, _} = Edge.Store.execute(store, "PRAGMA user_version = 1")

    assert {:ok, _} =
             Edge.Store.execute(
               store,
               "INSERT INTO edge_partitions(memory_space_id,scope,namespace,applied_revision,active_generation,snapshot_id,snapshot_revision,next_chunk_index,chunk_count,integrity_hash) VALUES ('space','scope','private',7,'active','interrupted',8,1,2,'hash')"
             )

    for {generation, id} <- [{"active", "canonical-active"}, {"interrupted", "canonical-staging"}] do
      assert {:ok, _} =
               Edge.Store.execute(
                 store,
                 "INSERT INTO edge_memories(memory_space_id,scope,namespace,generation,canonical_id,memory_type,content,content_hash,confidence,lifecycle_state,tags,metadata,source_refs,server_revision,edge_priority,edge_expires_at,updated_at,byte_size) VALUES ('space','scope','private',?,?,'semantic','retained content','digest',0.8,'active','[\"tag\"]','{\"source\":\"legacy\"}','[\"ref\"]',7,0.8,?,?,16)",
                 [generation, id, @now, @now]
               )
    end

    assert {:ok, _} =
             Edge.Store.execute(
               store,
               "INSERT INTO edge_snapshot_chunks(snapshot_id,chunk_index,chunk_hash,applied_at) VALUES ('interrupted',0,'hash',?)",
               [@now]
             )

    assert :ok = Edge.Migrator.migrate(store)
    assert {:ok, 3} = Edge.Migrator.current_version(store)

    assert {:ok,
            %{
              rows: [
                %{
                  "applied_revision" => 7,
                  "active_generation" => "active",
                  "snapshot_id" => nil,
                  "sync_status" => "snapshot_required",
                  "snapshot_received_items" => 0
                }
              ]
            }} =
             Edge.Store.query(
               store,
               "SELECT applied_revision,active_generation,snapshot_id,sync_status,snapshot_received_items FROM edge_partitions"
             )

    assert {:ok,
            %{
              rows: [
                %{
                  "canonical_id" => "canonical-active",
                  "content" => "retained content",
                  "memory_type" => "semantic",
                  "metadata" => ~s|{"source":"legacy"}|,
                  "tags" => ~s|["tag"]|,
                  "source_refs" => ~s|["ref"]|,
                  "server_revision" => 7,
                  "edge_priority" => 0.8,
                  "edge_expires_at" => @now,
                  "byte_size" => 16
                }
              ]
            }} =
             Edge.Store.query(
               store,
               "SELECT canonical_id,content,memory_type,metadata,tags,source_refs,server_revision,edge_priority,edge_expires_at,byte_size FROM edge_memories"
             )

    assert {:ok, %{rows: []}} = Edge.Store.query(store, "SELECT * FROM edge_snapshot_chunks")
    assert :disabled = Edge.Protection.status(%{})
    assert :ok = Edge.Migrator.migrate(store)
  end

  defp unique_name(prefix), do: String.to_atom("#{prefix}_#{System.unique_integer([:positive])}")
end

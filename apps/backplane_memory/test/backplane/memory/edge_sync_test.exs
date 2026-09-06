defmodule Backplane.Memory.EdgeSyncTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.EdgeSync
  alias Backplane.Memory.EdgeSync.{Cursor, Delivery}
  alias Backplane.MemorySpaces

  setup do
    previous = Backplane.Settings.get("memory.host_sync_v2.enabled")
    :ets.insert(:backplane_settings, {"memory.host_sync_v2.enabled", true})
    on_exit(fn -> :ets.insert(:backplane_settings, {"memory.host_sync_v2.enabled", previous}) end)
    host = Ecto.UUID.generate()

    repo().query!(
      "INSERT INTO skill_hosts (id,name,memory_scope,inserted_at,updated_at) VALUES ($1,$2,'edge',now(),now())",
      [Ecto.UUID.dump!(host), host]
    )

    {:ok, partition} = MemorySpaces.provision_private_host(host, "edge")
    %{host: host, partition: Map.new(partition, fn {k, v} -> {Atom.to_string(k), v} end)}
  end

  test "negotiation explicitly selects v2 and inventories exact namespaces", c do
    assert {:ok, %{selected: "host_memory.v2", partitions: [p]}} =
             EdgeSync.negotiate(c.host, offer())

    assert p["memory_space_id"] == c.partition["memory_space_id"]
    assert p["namespace"] == "private"
    assert p["status"] == "snapshot_required"

    assert {:error, %{code: :invalid_request, retryable: false}} =
             EdgeSync.negotiate(c.host, %{"memory_v2" => 42})

    :ets.insert(:backplane_settings, {"memory.host_sync_v2.enabled", false})

    assert {:error, %{code: :protocol_disabled}} =
             EdgeSync.negotiate(c.host, Map.put(offer(), "selected", "host_memory.v2"))

    assert {:ok, %{selected: "host_memory.v1"}} =
             EdgeSync.negotiate(c.host, %{"memory" => %{"protocol" => "host_memory.v1"}})
  end

  test "initial snapshot is durable and only its bound activation advances the cursor", c do
    insert_memory(c, "first")
    assert {:ok, batch} = EdgeSync.next(c.host, request(c))
    assert batch["kind"] == "snapshot_chunk"
    assert {:ok, ^batch} = EdgeSync.next(c.host, request(c))
    assert repo().one(Cursor).applied_revision == 0

    assert {:error, %{code: :invalid_ack}} =
             EdgeSync.ack(c.host, Map.put(ack(c, batch), "applied_revision", 99))

    assert {:ok, %{status: :advanced, applied_revision: 1}} = EdgeSync.ack(c.host, ack(c, batch))
    assert {:ok, %{status: :duplicate}} = EdgeSync.ack(c.host, ack(c, batch))

    assert {:error, %{code: :invalid_ack}} =
             EdgeSync.ack(c.host, Map.put(ack(c, batch), "chunk_hash", "bad"))

    assert {:error, %{code: :invalid_ack}} =
             EdgeSync.ack(c.host, Map.put(ack(c, batch), "next_chunk_index", 1.0))

    assert repo().one(Cursor).applied_revision == 1
  end

  test "deltas use server cursor, bound count and bytes and preserve exact retries", c do
    {:ok, first} = EdgeSync.next(c.host, request(c))
    {:ok, _} = EdgeSync.ack(c.host, ack(c, first))
    for n <- 1..3, do: insert_memory(c, "fact #{n}")
    req = Map.merge(request(c), %{"max_changes" => 2, "max_frame_bytes" => 2000})
    assert {:ok, batch} = EdgeSync.next(c.host, req)
    assert batch["kind"] == "delta"
    assert length(batch["changes"]) == 2
    assert byte_size(Jason.encode!(batch)) <= 2000
    assert {:ok, ^batch} = EdgeSync.next(c.host, req)

    assert {:error, %{code: :payload_too_large}} =
             EdgeSync.next(c.host, Map.put(req, "max_changes", 1))

    assert repo().aggregate(Delivery, :count) == 2
    assert {:ok, %{applied_revision: 2}} = EdgeSync.ack(c.host, ack(c, batch))
    assert {:error, %{code: :batch_not_found}} = EdgeSync.ack(Ecto.UUID.generate(), ack(c, batch))
    assert {:error, %{code: :invalid_request}} = EdgeSync.ack(c.host, %{})
  end

  test "ahead claims and missing retained history recover through snapshots", c do
    {:ok, first} = EdgeSync.next(c.host, request(c))
    {:ok, _} = EdgeSync.ack(c.host, ack(c, first))
    insert_memory(c, "canonical")

    repo().query!("DELETE FROM bpm_memory_changes WHERE memory_space_id=$1", [
      Ecto.UUID.dump!(c.partition["memory_space_id"])
    ])

    assert {:ok, batch} = EdgeSync.next(c.host, request(c))
    assert batch["kind"] == "snapshot_chunk"
    {:ok, _} = EdgeSync.ack(c.host, ack(c, batch))
    assert {:ok, ahead} = EdgeSync.next(c.host, Map.put(request(c), "applied_revision", 100))
    assert ahead["kind"] == "snapshot_chunk"
  end

  test "intermediate snapshot ACK changes progress only and exact old ACK stays duplicate", c do
    for n <- 1..3, do: insert_memory(c, "snapshot #{n}")
    req = Map.put(request(c), "max_changes", 1)
    {:ok, first} = EdgeSync.next(c.host, req)
    assert first["chunk_count"] == 3
    progress = ack(c, first) |> Map.merge(%{"status" => "progress", "applied_revision" => 0})
    assert {:error, %{code: :invalid_ack}} = EdgeSync.ack(c.host, ack(c, first))

    assert {:ok, %{status: :progress, applied_revision: 0, next_chunk_index: 1}} =
             EdgeSync.ack(c.host, progress)

    assert repo().one(Cursor).applied_revision == 0

    continuation =
      Map.merge(req, %{"snapshot_id" => first["snapshot_id"], "next_chunk_index" => 1})

    {:ok, second} = EdgeSync.next(c.host, continuation)
    assert second["chunk_index"] == 1
    assert {:ok, ^second} = EdgeSync.next(c.host, continuation)
    assert {:ok, %{status: :duplicate}} = EdgeSync.ack(c.host, progress)

    {:ok, _} =
      EdgeSync.ack(
        c.host,
        ack(c, second) |> Map.merge(%{"status" => "progress", "applied_revision" => 0})
      )

    {:ok, third} = EdgeSync.next(c.host, Map.put(continuation, "next_chunk_index", 2))
    assert {:ok, %{status: :advanced, applied_revision: 3}} = EdgeSync.ack(c.host, ack(c, third))
    assert {:ok, %{status: :duplicate, applied_revision: 3}} = EdgeSync.ack(c.host, progress)
  end

  test "failed initial build blocks readiness until explicit rebuild succeeds", c do
    insert_memory(c, String.duplicate("large ", 1000))

    assert {:error, %{code: :payload_too_large}} =
             EdgeSync.next(c.host, Map.put(request(c), "max_frame_bytes", 1000))

    repo().query!(
      "ALTER TABLE bpm_memory_snapshots ADD CONSTRAINT reject_test_build CHECK (memory_space_id <> '#{c.partition["memory_space_id"]}'::uuid)"
    )

    assert {:error, %{code: :snapshot_build_unavailable}} = EdgeSync.next(c.host, request(c))
    repo().query!("ALTER TABLE bpm_memory_snapshots DROP CONSTRAINT reject_test_build")
    assert {:error, %{code: :partition_not_ready}} = EdgeSync.next(c.host, request(c))
    assert {:ok, _} = EdgeSync.SnapshotBuilder.rebuild(c.host, c.partition)
    assert {:ok, %{"kind" => "snapshot_chunk"}} = EdgeSync.next(c.host, request(c))
    id = EdgeSync.SnapshotBuilder.issue_id(c.partition)

    issues =
      repo().all(from(i in Backplane.MemorySpaces.BackfillIssue, where: i.source_id == ^id))

    assert [%{disposition: "resolved"}] = issues
  end

  test "exact shared entitlement inventory and ambiguous omitted owner fail closed", c do
    space = Ecto.UUID.generate()

    repo().query!(
      "INSERT INTO bpm_memory_spaces (id,kind,status,inserted_at,updated_at) VALUES ($1,'shared','active',now(),now())",
      [Ecto.UUID.dump!(space)]
    )

    repo().query!(
      "INSERT INTO bpm_memory_space_entitlements (memory_space_id,host_id,scope,namespace,status,inserted_at,updated_at) VALUES ($1,$2,'edge','team:blue','active',now(),now())",
      [Ecto.UUID.dump!(space), Ecto.UUID.dump!(c.host)]
    )

    assert {:ok, %{partitions: inventory}} = EdgeSync.negotiate(c.host, offer())

    assert Enum.any?(
             inventory,
             &(&1["memory_space_id"] == space and &1["namespace"] == "team:blue")
           )

    shared = Map.merge(c.partition, %{"memory_space_id" => space, "namespace" => "team:blue"})

    assert {:ok, %{"partition" => ^shared}} =
             EdgeSync.next(c.host, Map.put(request(c), "partition", shared))

    repo().query!(
      "INSERT INTO bpm_memory_space_entitlements (memory_space_id,host_id,scope,namespace,status,inserted_at,updated_at) VALUES ($1,$2,'edge','private','active',now(),now())",
      [Ecto.UUID.dump!(space), Ecto.UUID.dump!(c.host)]
    )

    assert {:error, %{code: :ambiguous_partition}} =
             EdgeSync.next(c.host, put_in(request(c), ["partition", "memory_space_id"], nil))
  end

  test "negotiation and current envelopes respect tiny frame limits", c do
    assert {:error, %{code: :payload_too_large}} =
             EdgeSync.negotiate(c.host, put_in(offer(), ["memory_v2", "max_frame_bytes"], 10))

    {:ok, b} = EdgeSync.next(c.host, request(c))
    {:ok, _} = EdgeSync.ack(c.host, ack(c, b))

    assert {:error, %{code: :payload_too_large}} =
             EdgeSync.next(c.host, Map.put(request(c), "max_frame_bytes", 10))
  end

  test "expired snapshots reject late ACK and restart at a new durable identity", c do
    insert_memory(c, "expiry")
    {:ok, old} = EdgeSync.next(c.host, request(c))

    repo().update_all(from(s in EdgeSync.Snapshot, where: s.id == ^old["snapshot_id"]),
      set: [expires_at: DateTime.add(DateTime.utc_now(), -1)]
    )

    assert {:error, %{code: :invalid_ack}} = EdgeSync.ack(c.host, ack(c, old))
    {:ok, fresh} = EdgeSync.next(c.host, request(c))
    refute fresh["snapshot_id"] == old["snapshot_id"]
    assert repo().get!(Delivery, old["batch_id"]).status == "expired"
    assert {:error, %{code: :invalid_ack}} = EdgeSync.ack(c.host, ack(c, old))
    assert {:ok, %{status: :advanced}} = EdgeSync.ack(c.host, ack(c, fresh))
  end

  test "forged stale future and foreign partition ACKs never move cursor", c do
    {:ok, initial} = EdgeSync.next(c.host, request(c))
    {:ok, _} = EdgeSync.ack(c.host, ack(c, initial))
    insert_memory(c, "delta")
    {:ok, batch} = EdgeSync.next(c.host, request(c))

    for revision <- [0, 2, 999] do
      assert {:error, %{code: :invalid_ack}} =
               EdgeSync.ack(c.host, Map.put(ack(c, batch), "applied_revision", revision))
    end

    assert {:error, %{code: :batch_not_found}} =
             EdgeSync.ack(c.host, Map.put(ack(c, batch), "batch_id", Ecto.UUID.generate()))

    :ok = MemorySpaces.update_default_scope(c.host, "another")

    assert {:error, %{code: :batch_conflict}} =
             EdgeSync.ack(c.host, put_in(ack(c, batch), ["partition", "scope"], "another"))

    assert repo().one(from(cur in Cursor, where: cur.scope == "edge")).applied_revision == 0
    :ok = MemorySpaces.revoke_host(c.host)
    assert {:error, %{code: :unauthorized}} = EdgeSync.ack(c.host, ack(c, batch))
  end

  test "byte limit cuts delta before count limit and lowered retry limit cannot alter payload",
       c do
    {:ok, initial} = EdgeSync.next(c.host, request(c))
    {:ok, _} = EdgeSync.ack(c.host, ack(c, initial))
    for n <- 1..3, do: insert_memory(c, "byte bound #{n}")
    req = Map.put(request(c), "max_frame_bytes", 750)
    {:ok, batch} = EdgeSync.next(c.host, req)
    assert length(batch["changes"]) == 1
    assert byte_size(Jason.encode!(batch)) <= 750

    assert {:error, %{code: :payload_too_large}} =
             EdgeSync.next(c.host, Map.put(req, "max_frame_bytes", 10))

    assert {:ok, ^batch} = EdgeSync.next(c.host, req)
  end

  test "explicit snapshot rebuild cannot bypass unrelated canonical readiness issue", c do
    p = Map.new(c.partition, fn {k, v} -> {String.to_existing_atom(k), v} end)
    :ok = EdgeSync.SnapshotBuilder.record_failure(p, 0)

    root =
      repo().insert!(%Backplane.MemorySpaces.BackfillIssue{
        source_table: "bpm_memories",
        source_id: Ecto.UUID.generate(),
        reason: "missing_mapping",
        details: c.partition
      })

    assert {:error, %{code: :partition_not_ready}} =
             EdgeSync.SnapshotBuilder.rebuild(c.host, c.partition)

    repo().update_all(from(i in Backplane.MemorySpaces.BackfillIssue, where: i.id == ^root.id),
      set: [disposition: "resolved"]
    )

    assert {:ok, _} = EdgeSync.SnapshotBuilder.rebuild(c.host, c.partition)
    assert {:ok, _} = EdgeSync.next(c.host, request(c))
  end

  test "missing private host mapping blocks negotiation even when entitlements remain", c do
    repo().query!("DELETE FROM bpm_memory_space_legacy_aliases WHERE memory_space_id=$1", [
      Ecto.UUID.dump!(c.partition["memory_space_id"])
    ])

    assert {:error, %{code: :partition_not_ready}} = EdgeSync.negotiate(c.host, offer())
  end

  test "explicit rebuild resolves pre-seeded exact initial snapshot issue with legacy identity",
       c do
    repo().insert!(%Backplane.MemorySpaces.BackfillIssue{
      source_table: "initial_snapshot",
      source_id: "#{c.partition["memory_space_id"]}:edge:private",
      reason: "initial_snapshot_pending",
      details: c.partition
    })

    assert {:error, %{code: :partition_not_ready}} = EdgeSync.next(c.host, request(c))
    assert {:ok, _} = EdgeSync.SnapshotBuilder.rebuild(c.host, c.partition)
    assert {:ok, _} = EdgeSync.next(c.host, request(c))
  end

  test "delayed failure bookkeeping cannot reopen readiness after a successful rebuild", c do
    p = Map.new(c.partition, fn {k, v} -> {String.to_existing_atom(k), v} end)

    repo().query!(
      "ALTER TABLE bpm_memory_snapshots ADD CONSTRAINT reject_delayed_build CHECK (memory_space_id <> '#{p.memory_space_id}'::uuid)"
    )

    assert {:error, {:snapshot_build_unavailable, ^p, failed_revision}} =
             repo().transaction(fn ->
               EdgeSync.SnapshotBuilder.build_locked(p, %{
                 max_changes: 100,
                 max_frame_bytes: 524_288
               })
             end)

    repo().query!("ALTER TABLE bpm_memory_snapshots DROP CONSTRAINT reject_delayed_build")
    assert {:ok, _} = EdgeSync.SnapshotBuilder.rebuild(c.host, c.partition)
    insert_memory(c, "mutation after successful rebuild")
    assert :ok = EdgeSync.SnapshotBuilder.record_failure(p, failed_revision)
    assert {:ok, _} = EdgeSync.next(c.host, request(c))
    issue_id = EdgeSync.SnapshotBuilder.issue_id(p)

    refute repo().exists?(
             from(i in Backplane.MemorySpaces.BackfillIssue,
               where: i.source_id == ^issue_id and i.disposition == "pending"
             )
           )
  end

  test "an older ready snapshot cannot suppress a genuine current revision build failure", c do
    p = Map.new(c.partition, fn {k, v} -> {String.to_existing_atom(k), v} end)
    assert {:ok, _} = EdgeSync.SnapshotBuilder.rebuild(c.host, c.partition)
    insert_memory(c, "newer canonical revision")

    repo().query!(
      "ALTER TABLE bpm_memory_snapshots ADD CONSTRAINT reject_newer_build CHECK (memory_space_id <> '#{p.memory_space_id}'::uuid) NOT VALID"
    )

    assert {:error, {:snapshot_build_unavailable, ^p, failed_revision}} =
             repo().transaction(fn ->
               EdgeSync.SnapshotBuilder.build_locked(p, %{
                 max_changes: 100,
                 max_frame_bytes: 524_288
               })
             end)

    repo().query!("ALTER TABLE bpm_memory_snapshots DROP CONSTRAINT reject_newer_build")
    assert failed_revision == 1
    assert :ok = EdgeSync.SnapshotBuilder.record_failure(p, failed_revision)
    assert {:error, %{code: :partition_not_ready}} = EdgeSync.next(c.host, request(c))
  end

  defp offer,
    do: %{
      "memory_v2" => %{
        "offers" => ["host_memory.v2"],
        "partitions" => [],
        "max_frame_bytes" => 524_288
      }
    }

  defp request(c),
    do: %{"protocol" => "host_memory.v2", "partition" => c.partition, "applied_revision" => 0}

  defp ack(c, b) do
    %{
      "protocol" => "host_memory.v2",
      "partition" => c.partition,
      "batch_id" => b["batch_id"],
      "status" => "applied",
      "applied_revision" => b["to_revision"],
      "snapshot_id" => b["snapshot_id"],
      "next_chunk_index" => if(b["kind"] == "snapshot_chunk", do: b["chunk_index"] + 1),
      "chunk_hash" => b["chunk_hash"],
      "integrity_hash" => b["integrity_hash"]
    }
  end

  defp insert_memory(c, content) do
    repo().query!(
      "INSERT INTO bpm_memories (id,memory_space_id,host_id,client_id,scope,namespace,agent_id,content,content_hash,memory_type,lifecycle_state,inserted_at,updated_at) VALUES ($1,$2,$3,$4,'edge','private','test',$5,$6,'semantic','active',now(),now())",
      [
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        Ecto.UUID.dump!(c.partition["memory_space_id"]),
        c.host,
        "host:" <> c.host,
        content,
        :crypto.hash(:sha256, content)
      ]
    )
  end
end

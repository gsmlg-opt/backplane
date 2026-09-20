defmodule Backplane.HostAgent.Memory.MirrorTest do
  use ExUnit.Case, async: false
  alias Backplane.HostAgent.Memory.Mirror
  alias Backplane.HostAgent.Memory.Edge.{Store, Migrator}
  alias Backplane.Memory.EdgeSync.SnapshotBuilder
  @moduletag :tmp_dir
  @partition %{"memory_space_id" => "space", "scope" => "proj_local", "namespace" => "private"}
  @config %{enabled: true, development_plaintext: true}

  setup %{tmp_dir: dir} do
    open = [database: Path.join(dir, "edge.db"), config: @config]
    {:ok, store} = Store.start_link(open)
    Process.unlink(store)
    :ok = Migrator.migrate(store)
    on_exit(fn -> if Process.alive?(store), do: GenServer.stop(store) end)
    %{store: store, open: open, opts: [store: store, config: @config]}
  end

  test "contiguous delta and exact retry commit one durable cursor", c do
    delivery = delta(1, [upsert(1, "a", "alpha")])
    assert {:ok, ack} = Mirror.apply_delivery(delivery, c.opts)
    assert ack == ack(delivery)
    assert {:ok, ^ack} = Mirror.apply_delivery(delivery, c.opts)
    assert {:ok, result} = Mirror.offline_read("list", @partition, c.opts)
    assert [%{"canonical_id" => "a", "content" => "alpha"}] = result["items"]
    assert result["partition_revision"] == 1
    assert result["consistency"] == "bounded_stale"
    assert result["source"] == "edge_mirror"
    assert result["history_available"]
    assert is_binary(result["as_of"])
    assert result["last_sync_age_seconds"] >= 0
    assert {:ok, offer} = Mirror.offer(c.opts)
    assert [p] = offer["partitions"]
    assert p["applied_revision"] == 1
  end

  test "forward gap persists recovery without changing mirror or cursor", c do
    assert {:ok, _} = Mirror.apply_delivery(delta(1, [upsert(1, "a", "alpha")]), c.opts)

    assert {:error, :snapshot_required} =
             Mirror.apply_delivery(delta(3, [upsert(3, "b", "beta")]), c.opts)

    assert {:ok, %{rows: [p]}} = Store.query(c.store, "SELECT * FROM edge_partitions")
    assert p["applied_revision"] == 1
    assert p["sync_status"] == "snapshot_required"
    assert {:ok, result} = Mirror.offline_read("list", @partition, c.opts)
    assert length(result["items"]) == 1
  end

  test "delete tombstone survives an older replayed upsert", c do
    first = delta(1, [upsert(1, "a", "alpha")])
    assert {:ok, _} = Mirror.apply_delivery(first, c.opts)
    assert {:ok, _} = Mirror.apply_delivery(delta(2, [delete(2, "a")]), c.opts)
    assert {:ok, _} = Mirror.apply_delivery(first, c.opts)
    assert {:ok, result} = Mirror.offline_read("list", @partition, c.opts)
    assert result["items"] == []
    assert result["partition_revision"] == 2

    assert {:ok,
            %{rows: [%{"lifecycle_state" => "deleted", "server_revision" => 2, "content" => nil}]}} =
             Store.query(
               c.store,
               "SELECT lifecycle_state, server_revision, content FROM edge_memories"
             )
  end

  test "malformed changes and partition conflicts write nothing", c do
    valid = delta(1, [upsert(1, "a", "alpha")])
    invalid = put_in(valid, ["changes", Access.at(0), "payload", "canonical_id"], "other")
    assert {:error, :invalid_delivery} = Mirror.apply_delivery(invalid, c.opts)

    assert {:error, :partition_mismatch} =
             Mirror.apply_delivery(
               valid,
               Keyword.put(c.opts, :partition, Map.put(@partition, "namespace", "shared"))
             )

    assert {:ok, %{rows: []}} = Store.query(c.store, "SELECT * FROM edge_partitions")
  end

  test "same batch identity with a changed payload is rejected", c do
    valid = delta(1, [upsert(1, "a", "alpha")])
    assert {:ok, _} = Mirror.apply_delivery(valid, c.opts)
    changed = put_in(valid, ["changes", Access.at(0), "payload", "content"], "tampered")
    assert {:error, :delivery_conflict} = Mirror.apply_delivery(changed, c.opts)
  end

  test "SQL failure rolls back preceding memory writes and cursor without an ACK", c do
    assert {:ok, _} =
             Store.execute(
               c.store,
               "CREATE TRIGGER reject_b BEFORE INSERT ON edge_memories WHEN NEW.canonical_id = 'b' BEGIN SELECT RAISE(ABORT, 'injected'); END"
             )

    assert {:error, _} =
             Mirror.apply_delivery(
               delta(1, [upsert(1, "a", "alpha"), upsert(2, "b", "beta")]),
               c.opts
             )

    assert {:ok, %{rows: []}} = Store.query(c.store, "SELECT * FROM edge_memories")
    assert {:ok, %{rows: []}} = Store.query(c.store, "SELECT * FROM edge_partitions")
  end

  test "staged chunks stay invisible, resume after restart and activate only on complete manifest",
       c do
    assert {:ok, _} = Mirror.apply_delivery(delta(1, [upsert(1, "old", "old value")]), c.opts)
    [first, final] = snapshot([[item("new-a", "new alpha")], [item("new-b", "new beta")]], 1, 8)
    assert {:ok, progress} = Mirror.apply_delivery(first, c.opts)
    assert progress == ack(first)
    assert progress["applied_revision"] == 1
    assert {:ok, before} = Mirror.offline_read("list", @partition, c.opts)
    assert [%{"canonical_id" => "old"}] = before["items"]

    assert {:error, :snapshot_restart_required} =
             Mirror.apply_delivery(delta(2, [upsert(2, "x", "x")]), c.opts)

    GenServer.stop(c.store)
    {:ok, reopened} = Store.start_link(c.open)
    Process.unlink(reopened)
    on_exit(fn -> if Process.alive?(reopened), do: GenServer.stop(reopened) end)
    opts = Keyword.put(c.opts, :store, reopened)
    assert {:ok, offer} = Mirror.offer(opts)

    assert [%{"snapshot" => %{"snapshot_id" => id, "next_chunk_index" => 1}}] =
             offer["partitions"]

    assert id == first["snapshot_id"]
    assert {:ok, ^progress} = Mirror.apply_delivery(first, opts)
    assert {:ok, applied} = Mirror.apply_delivery(final, opts)
    assert applied == ack(final)
    assert {:ok, ^applied} = Mirror.apply_delivery(final, opts)

    # A lost progress ACK can cause the server to retry an earlier chunk after
    # activation. The persisted chunk manifest makes that retry unambiguous.
    assert {:ok, ^progress} = Mirror.apply_delivery(first, opts)

    assert {:ok, %{rows: [%{"active_generation" => active, "applied_revision" => 8}]}} =
             Store.query(
               opts[:store],
               "SELECT active_generation, applied_revision FROM edge_partitions"
             )

    assert active == first["snapshot_id"]

    changed = first |> put_in(["items", Access.at(0), "content"], "changed") |> put_chunk_hash()
    assert {:error, :delivery_conflict} = Mirror.apply_delivery(changed, opts)

    assert {:error, :delivery_conflict} =
             Mirror.apply_delivery(
               Map.put(first, "integrity_hash", "sha256:" <> String.duplicate("0", 64)),
               opts
             )

    assert {:ok, after_read} = Mirror.offline_read("list", @partition, opts)
    assert Enum.map(after_read["items"], & &1["canonical_id"]) == ["new-a", "new-b"]
    assert after_read["partition_revision"] == 8
    GenServer.stop(reopened)
    {:ok, persisted} = Store.start_link(c.open)
    Process.unlink(persisted)
    on_exit(fn -> if Process.alive?(persisted), do: GenServer.stop(persisted) end)

    assert {:ok, again} =
             Mirror.offline_read("list", @partition, Keyword.put(opts, :store, persisted))

    assert again["items"] == after_read["items"]
    assert again["as_of"] == after_read["as_of"]
  end

  test "chunk hash and final manifest failures cannot activate or advance", c do
    [first, final] = snapshot([[item("a", "alpha")], [item("b", "beta")]], 0, 8)
    bad = put_in(first, ["items", Access.at(0), "content"], "tampered")
    assert {:error, :integrity_failure} = Mirror.apply_delivery(bad, c.opts)
    false_manifest = "sha256:" <> String.duplicate("0", 64)
    first = Map.put(first, "integrity_hash", false_manifest)
    final = Map.put(final, "integrity_hash", false_manifest)
    assert {:ok, _} = Mirror.apply_delivery(first, c.opts)
    assert {:error, :integrity_failure} = Mirror.apply_delivery(final, c.opts)
    assert {:ok, %{rows: [p]}} = Store.query(c.store, "SELECT * FROM edge_partitions")
    assert p["applied_revision"] == 0
    assert p["next_chunk_index"] == 1
    assert {:error, :mirror_unavailable} = Mirror.offline_read("list", @partition, c.opts)
  end

  test "an active snapshot chunk remains idempotent after a newer contiguous delta", c do
    [first, final] = snapshot([[item("snapshot-a", "alpha")], [item("snapshot-b", "beta")]], 0, 8)
    assert {:ok, progress} = Mirror.apply_delivery(first, c.opts)
    assert {:ok, _} = Mirror.apply_delivery(final, c.opts)
    assert {:ok, _} = Mirror.apply_delivery(delta(9, [upsert(9, "delta", "newer")]), c.opts)

    assert {:ok, ^progress} = Mirror.apply_delivery(first, c.opts)

    assert {:ok,
            %{
              rows: [
                %{
                  "active_generation" => active,
                  "applied_revision" => 9,
                  "last_batch_id" => "delta-9"
                }
              ]
            }} =
             Store.query(
               c.store,
               "SELECT active_generation, applied_revision, last_batch_id FROM edge_partitions"
             )

    assert active == first["snapshot_id"]
    assert {:ok, result} = Mirror.offline_read("list", @partition, c.opts)

    assert Enum.map(result["items"], & &1["canonical_id"]) == [
             "delta",
             "snapshot-a",
             "snapshot-b"
           ]
  end

  test "same staged chunk index with different hash fails closed", c do
    [first, _] = snapshot([[item("a", "alpha")], [item("b", "beta")]], 0, 8)
    assert {:ok, _} = Mirror.apply_delivery(first, c.opts)
    changed = Map.put(first, "items", [item("x", "different")])
    changed = Map.put(changed, "chunk_hash", SnapshotBuilder.hash(%{"items" => changed["items"]}))
    assert {:error, :delivery_conflict} = Mirror.apply_delivery(changed, c.opts)
  end

  test "offline lexical matching and limits only inspect the exact partition", c do
    assert {:ok, _} =
             Mirror.apply_delivery(
               delta(1, [
                 upsert(1, "a", "Alpha first"),
                 upsert(2, "b", "Beta"),
                 upsert(3, "c", "Alpha second")
               ]),
               c.opts
             )

    assert {:ok, read} =
             Mirror.offline_read(
               "recall",
               Map.merge(@partition, %{"query" => "alpha", "limit" => 1}),
               c.opts
             )

    assert [%{"canonical_id" => "a"}] = read["items"]
    assert {:ok, stats} = Mirror.offline_read("stats", @partition, c.opts)
    assert stats["count"] == 3

    assert {:error, :mirror_unavailable} =
             Mirror.offline_read("list", Map.put(@partition, "namespace", "shared"), c.opts)

    assert {:error, :invalid_request} = Mirror.offline_read("search", @partition, c.opts)
  end

  test "disabled protection refuses all entrypoints even with an open store", c do
    opts = Keyword.put(c.opts, :config, %{enabled: true})
    assert {:error, :protection_unavailable} = Mirror.offer(opts)

    assert {:error, :protection_unavailable} =
             Mirror.apply_delivery(delta(1, [upsert(1, "a", "a")]), opts)

    assert {:error, :protection_unavailable} = Mirror.offline_read("list", @partition, opts)
  end

  test "server eligible disputed memories remain readable", c do
    delivery =
      delta(1, [upsert(1, "a", "disputed fact")])
      |> put_in(["changes", Access.at(0), "payload", "lifecycle_state"], "disputed")

    assert {:ok, _} = Mirror.apply_delivery(delivery, c.opts)
    assert {:ok, result} = Mirror.offline_read("list", @partition, c.opts)
    assert [%{"lifecycle_state" => "disputed"}] = result["items"]
  end

  test "transport item and byte limits reject before opening a transaction", c do
    delivery = delta(1, [upsert(1, "a", "alpha"), upsert(2, "b", "beta")])
    opts = Keyword.put(c.opts, :config, Map.put(@config, :max_changes, 1))
    assert {:error, :invalid_delivery} = Mirror.apply_delivery(delivery, opts)
    opts = Keyword.put(c.opts, :config, Map.put(@config, :max_frame_bytes, 100))
    assert {:error, :payload_too_large} = Mirror.apply_delivery(delivery, opts)
    assert {:ok, %{rows: []}} = Store.query(c.store, "SELECT * FROM edge_partitions")
  end

  test "host canonical JSON hash matches the server across nested and escaped values" do
    payload = %{
      "items" => [%{"z" => nil, "é" => [true, 1.5, %{"b" => "quote\"\n", "a" => false}]}]
    }

    assert Mirror.Store.hash(payload) == SnapshotBuilder.hash(payload)
  end

  test "offline result bytes are bounded across multiple maximum sized memories", c do
    content = String.duplicate("x", 180_000)

    for revision <- 1..4 do
      assert {:ok, _} =
               Mirror.apply_delivery(
                 delta(revision, [upsert(revision, "id-#{revision}", content)]),
                 c.opts
               )
    end

    assert {:ok, result} = Mirror.offline_read("list", @partition, c.opts)
    assert byte_size(Jason.encode!(result)) <= 524_288
    assert length(result["items"]) > 0
  end

  defp item(id, content),
    do: %{
      "canonical_id" => id,
      "memory_type" => "semantic",
      "content" => content,
      "content_hash" => "hash",
      "confidence" => 0.9,
      "lifecycle_state" => "active",
      "tags" => [],
      "metadata" => %{},
      "expires_at" => nil
    }

  defp upsert(revision, id, content),
    do: %{
      "revision" => revision,
      "op" => "upsert",
      "memory_id" => id,
      "payload" => item(id, content)
    }

  defp delete(revision, id),
    do: %{
      "revision" => revision,
      "op" => "delete",
      "memory_id" => id,
      "payload" => %{"canonical_id" => id}
    }

  defp delta(from, changes),
    do: %{
      "protocol" => "host_memory.v2",
      "status" => "batch",
      "kind" => "delta",
      "batch_id" => "delta-#{from}",
      "partition" => @partition,
      "from_revision" => from,
      "to_revision" => from + length(changes) - 1,
      "changes" => changes
    }

  defp snapshot(chunks, base, revision) do
    hashes = Enum.map(chunks, &SnapshotBuilder.hash(%{"items" => &1}))
    manifest = "sha256:" <> Base.encode16(:crypto.hash(:sha256, hashes), case: :lower)

    Enum.with_index(chunks, fn items, index ->
      %{
        "protocol" => "host_memory.v2",
        "status" => "batch",
        "kind" => "snapshot_chunk",
        "batch_id" => "snap-#{index}",
        "partition" => @partition,
        "snapshot_id" => "snapshot-one",
        "chunk_index" => index,
        "chunk_count" => length(chunks),
        "item_count" => chunks |> List.flatten() |> length(),
        "base_revision" => base,
        "to_revision" => revision,
        "chunk_hash" => Enum.at(hashes, index),
        "integrity_hash" => manifest,
        "items" => items
      }
    end)
  end

  defp put_chunk_hash(frame),
    do: Map.put(frame, "chunk_hash", SnapshotBuilder.hash(%{"items" => frame["items"]}))

  defp ack(%{"kind" => "delta"} = d),
    do:
      Map.merge(Map.take(d, ["protocol", "partition", "batch_id"]), %{
        "status" => "applied",
        "applied_revision" => d["to_revision"],
        "snapshot_id" => nil,
        "next_chunk_index" => nil,
        "chunk_hash" => nil,
        "integrity_hash" => nil
      })

  defp ack(d) do
    final = d["chunk_index"] + 1 == d["chunk_count"]

    Map.merge(
      Map.take(d, [
        "protocol",
        "partition",
        "batch_id",
        "snapshot_id",
        "chunk_hash",
        "integrity_hash"
      ]),
      %{
        "status" => if(final, do: "applied", else: "progress"),
        "applied_revision" => if(final, do: d["to_revision"], else: d["base_revision"]),
        "next_chunk_index" => d["chunk_index"] + 1
      }
    )
  end
end

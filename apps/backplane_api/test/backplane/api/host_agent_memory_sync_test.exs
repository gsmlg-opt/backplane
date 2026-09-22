defmodule Backplane.Api.HostAgentMemorySyncTest do
  use Backplane.Api.DataCase, async: false

  import Ecto.Query

  alias Backplane.Repo
  alias Backplane.Skills.Hosts
  alias Backplane.Api.HostAgentMemorySync
  alias Backplane.Api.HostMemoryRevocation
  alias Backplane.Memory.Memories.{Evidence, RememberRequest}
  alias Backplane.Memory.Memories.Memory, as: MemorySchema
  alias Backplane.MemorySpaces

  setup do
    Application.delete_env(:backplane_api, :host_memory_sync_adapter)
    Application.delete_env(:backplane_api, :memory_service)
    :ok
  end

  test "compat receipts bind issued content, host and kind and never advance v2" do
    host = create_host!("receipts", "scope:receipts")
    other = create_host!("foreign-receipts", "scope:receipts")
    payload = %{"scope" => host.memory_scope, "full" => true, "facts" => []}
    assert {:ok, issued} = HostAgentMemorySync.issue_receipt(host, "facts", payload)
    assert issued["receipt_key"] =~ "facts:"
    receipt = Repo.one!(Backplane.Memory.EdgeSync.CompatReceipt)
    assert is_nil(receipt.acknowledged_at)

    ack =
      Map.take(issued, ["receipt_key", "payload_hash", "scope"]) |> Map.put("status", "applied")

    assert {:error, :batch_not_found} = HostAgentMemorySync.ack_receipt(other, "facts", ack)
    assert {:error, :batch_not_found} = HostAgentMemorySync.ack_receipt(host, "wipe", ack)

    assert {:error, :invalid_ack} =
             HostAgentMemorySync.ack_receipt(host, "facts", Map.put(ack, "status", "failed"))

    assert {:error, :batch_conflict} =
             HostAgentMemorySync.ack_receipt(
               host,
               "facts",
               Map.put(ack, "payload_hash", String.duplicate("0", 64))
             )

    assert {:ok, %{status: :acknowledged}} = HostAgentMemorySync.ack_receipt(host, "facts", ack)
    assert {:ok, %{status: :duplicate}} = HostAgentMemorySync.ack_receipt(host, "facts", ack)
    assert Repo.one!(Backplane.Memory.EdgeSync.CompatReceipt).acknowledged_at
    assert Repo.aggregate(Backplane.Memory.EdgeSync.Cursor, :count) == 0
  end

  test "compat facts and wipes fail explicitly for invalid authority and oversized results" do
    host = create_host!("bounds", "scope:bounds")
    assert {:error, :unauthorized} = HostAgentMemorySync.facts_for_scope(host, "foreign", nil)
    assert {:error, :unauthorized} = HostAgentMemorySync.active_wipes(host, "foreign")

    insert_memory!(host, host.memory_scope, String.duplicate("x", 524_288),
      memory_type: "semantic"
    )

    assert {:error, :payload_too_large} =
             HostAgentMemorySync.facts_for_scope(host, host.memory_scope, nil)
  end

  test "compat queries bound fact and wipe counts without returning partial replacements" do
    host = create_host!("counts", "scope:counts")
    for n <- 1..101, do: insert_memory!(host, host.memory_scope, "fact #{n}", [])

    assert {:error, :payload_too_large} =
             HostAgentMemorySync.facts_for_scope(host, host.memory_scope, nil)

    from(m in MemorySchema, where: m.host_id == ^host.id)
    |> Repo.update_all(set: [deleted_at: DateTime.utc_now(), lifecycle_state: "tombstoned"])

    assert {:error, :payload_too_large} =
             HostAgentMemorySync.active_wipes(host, host.memory_scope)
  end

  test "compat facts use canonical ownership and active or disputed lifecycle" do
    host = create_host!("canonical", "scope:canonical")
    owned = insert_memory!(host, host.memory_scope, "canonical shared provenance", [])

    owned
    |> Ecto.Changeset.change(client_id: "some-other-provenance", lifecycle_state: "disputed")
    |> Repo.update!()

    hidden = insert_memory!(host, host.memory_scope, "archived", [])
    hidden |> Ecto.Changeset.change(lifecycle_state: "archived") |> Repo.update!()

    assert {:full, [%{"id" => id}]} =
             HostAgentMemorySync.facts_for_scope(host, host.memory_scope, nil)

    assert id == owned.id
  end

  test "stable wipe receipt cannot be reissued with conflicting content" do
    host = create_host!("wipe-receipt", "scope:wipe-receipt")

    payload = %{
      "scope" => host.memory_scope,
      "directive_id" => "deleted:stable",
      "items" => [%{"remote_id" => "one"}]
    }

    assert {:ok, issued} = HostAgentMemorySync.issue_receipt(host, "wipe", payload)
    assert {:ok, ^issued} = HostAgentMemorySync.issue_receipt(host, "wipe", payload)

    assert {:error, :batch_conflict} =
             HostAgentMemorySync.issue_receipt(host, "wipe", Map.put(payload, "items", []))

    ack =
      Map.take(issued, ["receipt_key", "payload_hash", "scope"]) |> Map.put("status", "applied")

    assert {:ok, %{status: :acknowledged}} = HostAgentMemorySync.ack_receipt(host, "wipe", ack)

    assert {:error, :invalid_ack} =
             HostAgentMemorySync.ack_receipt(host, "wipe", Map.put(ack, "unbound", "extra"))

    assert {:ok, %{status: :duplicate}} = HostAgentMemorySync.ack_receipt(host, "wipe", ack)
  end

  test "revocation schema includes canonical ownership and provenance fields" do
    required_fields = [:memory_space_id, :host_id, :source_client_id, :scope, :namespace]

    assert [] == required_fields -- HostMemoryRevocation.__schema__(:fields)
  end

  test "remember maps a host local id to one stable canonical memory id" do
    host = create_host!("remember", "scope:stable")

    item =
      remember_item("local_1", "scope:stable", "local memory")
      |> Map.put("client_id", "host:attacker")

    assert {:ok, %{status: :ok, canonical_id: canonical_id}} =
             HostAgentMemorySync.apply_sync_item(host, item)

    assert {:ok, %{status: :duplicate, canonical_id: ^canonical_id}} =
             HostAgentMemorySync.apply_sync_item(host, item)

    assert [
             %MemorySchema{
               id: ^canonical_id,
               client_id: partition_id,
               metadata: %{
                 "host_memory" => %{
                   "local_id" => "local_1",
                   "content_hash" => _
                 }
               }
             }
           ] = memories_for(host, "scope:stable", include_deleted: true)

    assert partition_id == "host:#{host.id}"
  end

  test "host remember persists the exact edge revision for duplicate replies" do
    host = create_host!("edge-receipt", "scope:edge-receipt")
    item = remember_item("local_edge", host.memory_scope, "edge memory")

    assert {:ok, %{status: :ok, canonical_id: canonical_id, revision: revision}} =
             HostAgentMemorySync.apply_sync_item(host, item)

    assert is_integer(revision) and revision > 0

    assert {:ok, %{revision: later_revision}} =
             HostAgentMemorySync.apply_sync_item(
               host,
               remember_item("another_local", host.memory_scope, "another edge memory")
             )

    assert later_revision > revision

    assert {:ok, %{status: :duplicate, canonical_id: ^canonical_id, revision: ^revision}} =
             HostAgentMemorySync.apply_sync_item(host, item)

    assert %{revision: ^revision, op: "upsert"} =
             Repo.one!(
               from(c in Backplane.Memory.EdgeSync.Change,
                 where: c.memory_id == ^canonical_id,
                 order_by: [desc: c.revision],
                 limit: 1,
                 select: %{revision: c.revision, op: c.op}
               )
             )

    request = Repo.one!(from(r in RememberRequest, where: r.memory_id == ^canonical_id))

    assert [[^revision]] =
             Repo.query!(
               "SELECT edge_revision FROM bpm_host_memory_command_receipts WHERE source_request_id = $1",
               [Ecto.UUID.dump!(request.id)]
             ).rows
  end

  test "a newly inserted item keeps its insertion revision when a marker would exceed the edge budget" do
    host = create_host!("insert-edge-limit", "scope:insert-edge-limit")
    first = remember_item("first-local", host.memory_scope, "edge memory one")
    second = remember_item("other-local", host.memory_scope, "edge memory two")

    assert {:ok, %{canonical_id: first_id}} = HostAgentMemorySync.apply_sync_item(host, first)

    assert [[budget]] =
             Repo.query!(
               "SELECT octet_length(bpm_memory_edge_payload(jsonb_populate_record(m, jsonb_build_object('metadata', m.metadata - 'host_memory_command_revision')))::text) FROM bpm_memories m WHERE id = $1",
               [Ecto.UUID.dump!(first_id)]
             ).rows

    Repo.query!(
      "INSERT INTO system_settings (key,value,value_type,updated_at) VALUES ('memory.host_sync_max_item_bytes',jsonb_build_object('v',$1::integer),'integer',now()) ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value",
      [budget]
    )

    assert {:ok, %{status: :ok, canonical_id: second_id, revision: revision}} =
             HostAgentMemorySync.apply_sync_item(host, second)

    assert second_id != first_id
    assert is_integer(revision) and revision > 0

    assert %{revision: ^revision, op: "upsert"} =
             Repo.one!(
               from(c in Backplane.Memory.EdgeSync.Change,
                 where: c.memory_id == ^second_id,
                 select: %{revision: c.revision, op: c.op}
               )
             )

    assert {:ok, %{status: :duplicate, revision: ^revision}} =
             HostAgentMemorySync.apply_sync_item(host, second)
  end

  test "a marker preflight includes its updated timestamp at the byte limit" do
    host = create_host!("timestamp-edge-limit", "scope:timestamp-edge-limit")

    crystal =
      insert_memory!(host, host.memory_scope, "timestamp edge limit",
        memory_type: "episodic",
        metadata: %{"crystal" => %{"source" => "summary"}}
      )

    Repo.query!(
      "UPDATE bpm_memories SET updated_at = '2026-01-01 00:00:00'::timestamp WHERE id = $1",
      [Ecto.UUID.dump!(crystal.id)]
    )

    # The old row fits, but the marker plus a fractional updated_at does not.
    assert [[budget]] =
             Repo.query!(
               "SELECT octet_length(bpm_memory_edge_payload(jsonb_populate_record(m, jsonb_build_object('metadata', jsonb_set(m.metadata, '{host_memory_command_revision}', to_jsonb($2::text), true))))::text) FROM bpm_memories m WHERE id = $1",
               [Ecto.UUID.dump!(crystal.id), Ecto.UUID.generate()]
             ).rows

    Repo.query!(
      "INSERT INTO system_settings (key,value,value_type,updated_at) VALUES ('memory.host_sync_max_item_bytes',jsonb_build_object('v',$1::integer),'integer',now()) ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value",
      [budget]
    )

    item = remember_item("timestamp-local", host.memory_scope, crystal.content)

    assert {:ok, %{status: :ok, canonical_id: canonical_id, revision: nil}} =
             HostAgentMemorySync.apply_sync_item(host, item)

    assert canonical_id == crystal.id
    assert Repo.get!(MemorySchema, crystal.id).metadata == crystal.metadata
  end

  test "valid remember outside the edge item byte budget keeps its canonical result" do
    host = create_host!("oversized-edge", "scope:oversized-edge")
    item = remember_item("large-local", host.memory_scope, String.duplicate("large", 200))

    Repo.query!(
      "INSERT INTO system_settings (key,value,value_type,updated_at) VALUES ('memory.host_sync_max_item_bytes','{\"v\":512}','integer',now()) ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value",
      []
    )

    assert {:ok, %{status: :ok, canonical_id: canonical_id, revision: nil}} =
             HostAgentMemorySync.apply_sync_item(host, item)

    assert {:ok, %{status: :duplicate, canonical_id: ^canonical_id, revision: nil}} =
             HostAgentMemorySync.apply_sync_item(host, item)

    assert Repo.get!(MemorySchema, canonical_id).content == item["content"]

    assert Repo.aggregate(
             from(c in Backplane.Memory.EdgeSync.Change, where: c.memory_id == ^canonical_id),
             :count
           ) == 0

    assert Repo.aggregate(from(r in RememberRequest, where: r.memory_id == ^canonical_id), :count) ==
             1

    assert [] ==
             Repo.query!(
               "SELECT edge_revision FROM bpm_host_memory_command_receipts WHERE memory_id = $1",
               [Ecto.UUID.dump!(canonical_id)]
             ).rows
  end

  test "replay of a pre-receipt host remember lazily assigns one durable revision" do
    host = create_host!("legacy-edge", "scope:legacy-edge")
    item = remember_item("legacy-local", host.memory_scope, String.duplicate("legacy", 200))

    Repo.query!(
      "INSERT INTO system_settings (key,value,value_type,updated_at) VALUES ('memory.host_sync_max_item_bytes','{\"v\":512}','integer',now()) ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value",
      []
    )

    # A previously committed command without a receipt has the same persisted
    # shape as a pre-migration host request. Make it edge-eligible for replay.
    assert {:ok, %{canonical_id: canonical_id, revision: nil}} =
             HostAgentMemorySync.apply_sync_item(host, item)

    Repo.query!(
      "UPDATE system_settings SET value = '{\"v\":262144}' WHERE key = 'memory.host_sync_max_item_bytes'",
      []
    )

    request = Repo.one!(from(r in RememberRequest, where: r.memory_id == ^canonical_id))

    assert {:ok, %{status: :duplicate, canonical_id: ^canonical_id, revision: revision}} =
             HostAgentMemorySync.apply_sync_item(host, item)

    assert is_integer(revision) and revision > 0

    assert {:ok, %{status: :duplicate, canonical_id: ^canonical_id, revision: ^revision}} =
             HostAgentMemorySync.apply_sync_item(host, item)

    assert [[^revision]] =
             Repo.query!(
               "SELECT edge_revision FROM bpm_host_memory_command_receipts WHERE source_request_id = $1",
               [Ecto.UUID.dump!(request.id)]
             ).rows
  end

  test "rolled back host remember leaves neither edge change nor command receipt" do
    host = create_host!("rolled-back-edge", "scope:rolled-back-edge")
    item = remember_item("rolled-back-local", host.memory_scope, "rolled back memory")

    assert {:error, :abort} =
             Repo.transaction(fn ->
               assert {:ok, %{revision: revision}} =
                        HostAgentMemorySync.apply_sync_item(host, item)

               assert revision > 0
               Repo.rollback(:abort)
             end)

    assert [] ==
             Repo.query!(
               "SELECT receipt.source_request_id FROM bpm_host_memory_command_receipts receipt JOIN bpm_memory_remember_requests request ON request.id = receipt.source_request_id WHERE request.idempotency_scope = $1",
               ["host-memory.v1:#{host.id}"]
             ).rows

    assert {:ok, %{status: :ok, revision: revision}} =
             HostAgentMemorySync.apply_sync_item(host, item)

    assert revision > 0
  end

  test "a second local id deduplicated onto one canonical memory receives that memory revision" do
    host = create_host!("dedup-edge-receipt", "scope:dedup-edge")
    first = remember_item("first-local", host.memory_scope, "same memory")
    second = remember_item("second-local", host.memory_scope, "same memory")

    assert {:ok, %{canonical_id: canonical_id, revision: revision}} =
             HostAgentMemorySync.apply_sync_item(host, first)

    assert {:ok, %{status: :ok, canonical_id: ^canonical_id, revision: second_revision}} =
             HostAgentMemorySync.apply_sync_item(host, second)

    assert second_revision > revision

    assert {:ok, %{status: :duplicate, canonical_id: ^canonical_id, revision: ^second_revision}} =
             HostAgentMemorySync.apply_sync_item(host, second)

    assert 2 ==
             Repo.aggregate(
               from(c in Backplane.Memory.EdgeSync.Change, where: c.memory_id == ^canonical_id),
               :count
             )

    assert 2 ==
             Repo.aggregate(
               from(r in RememberRequest, where: r.memory_id == ^canonical_id),
               :count
             )
  end

  test "same-content host remember gives a crystal-origin canonical memory an edge revision without changing provenance" do
    host = create_host!("crystal-dedup-edge", "scope:crystal-dedup-edge")
    metadata = %{"crystal" => %{"source" => "summary"}}

    crystal =
      insert_memory!(host, host.memory_scope, "crystal-origin memory",
        memory_type: "episodic",
        metadata: metadata
      )

    item = remember_item("crystal-local", host.memory_scope, crystal.content)

    assert {:ok, %{status: :ok, canonical_id: canonical_id, revision: revision}} =
             HostAgentMemorySync.apply_sync_item(host, item)

    assert canonical_id == crystal.id
    assert is_integer(revision) and revision > 0

    stored = Repo.get!(MemorySchema, canonical_id)
    assert Map.drop(stored.metadata, ["host_memory_command_revision"]) == metadata
    refute Map.has_key?(stored.metadata, "host_memory")
    assert stored.host_id == host.id
    assert stored.client_id == "host:#{host.id}"

    assert {:ok, %{status: :duplicate, canonical_id: ^canonical_id, revision: ^revision}} =
             HostAgentMemorySync.apply_sync_item(host, item)

    assert [%{revision: ^revision, op: "upsert"}] =
             Repo.all(
               from(c in Backplane.Memory.EdgeSync.Change,
                 where: c.memory_id == ^canonical_id,
                 select: %{revision: c.revision, op: c.op}
               )
             )
  end

  test "deduplicated host remember stays ID-only when the revision marker would exceed the edge budget" do
    host = create_host!("crystal-edge-budget", "scope:crystal-edge-budget")
    metadata = %{"crystal" => %{"source" => "summary"}}

    crystal =
      insert_memory!(host, host.memory_scope, "crystal at edge limit",
        memory_type: "episodic",
        metadata: metadata
      )

    assert [[budget]] =
             Repo.query!(
               "SELECT octet_length(bpm_memory_edge_payload(m)::text) FROM bpm_memories m WHERE id = $1",
               [Ecto.UUID.dump!(crystal.id)]
             ).rows

    Repo.query!(
      "INSERT INTO system_settings (key,value,value_type,updated_at) VALUES ('memory.host_sync_max_item_bytes',jsonb_build_object('v',$1::integer),'integer',now()) ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value",
      [budget]
    )

    Repo.query!(
      "INSERT INTO bpm_memory_partition_revisions (memory_space_id,scope,namespace,current_revision) VALUES ($1,$2,'private',0) ON CONFLICT DO NOTHING",
      [Ecto.UUID.dump!(crystal.memory_space_id), host.memory_scope]
    )

    Repo.query!(
      "INSERT INTO bpm_host_memory_cursors (host_id,memory_space_id,scope,namespace,applied_revision,acknowledged_at) VALUES ($1,$2,$3,'private',0,now())",
      [Ecto.UUID.dump!(host.id), Ecto.UUID.dump!(crystal.memory_space_id), host.memory_scope]
    )

    item = remember_item("crystal-budget-local", host.memory_scope, crystal.content)

    assert {:ok, %{status: :ok, canonical_id: canonical_id, revision: nil}} =
             HostAgentMemorySync.apply_sync_item(host, item)

    assert canonical_id == crystal.id
    assert Repo.get!(MemorySchema, canonical_id).metadata == metadata

    assert [[false]] =
             Repo.query!(
               "SELECT bpm_memory_edge_eligible(m) FROM bpm_memories m WHERE id = $1",
               [Ecto.UUID.dump!(crystal.id)]
             ).rows

    assert [[0, %NaiveDateTime{}]] =
             Repo.query!(
               "SELECT applied_revision, acknowledged_at FROM bpm_host_memory_cursors WHERE host_id = $1 AND memory_space_id = $2 AND scope = $3 AND namespace = 'private'",
               [
                 Ecto.UUID.dump!(host.id),
                 Ecto.UUID.dump!(crystal.memory_space_id),
                 host.memory_scope
               ]
             ).rows

    assert Repo.aggregate(
             from(c in Backplane.Memory.EdgeSync.Change, where: c.memory_id == ^canonical_id),
             :count
           ) == 0
  end

  test "remember retries keep one immutable request and one request evidence row" do
    host = create_host!("retry-ledger", "scope:retry")
    item = remember_item("local_retry", "scope:retry", "retry-safe memory")

    results = Enum.map(1..10, fn _attempt -> HostAgentMemorySync.apply_sync_item(host, item) end)

    assert [{:ok, %{status: :ok, canonical_id: canonical_id, revision: revision}} | retries] =
             results

    assert Enum.all?(retries, fn result ->
             result ==
               {:ok, %{status: :duplicate, canonical_id: canonical_id, revision: revision}}
           end)

    assert 1 ==
             Repo.aggregate(
               from(r in RememberRequest,
                 where:
                   r.idempotency_scope == ^"host-memory.v1:#{host.id}" and
                     r.idempotency_key == "local_retry"
               ),
               :count
             )

    assert 1 ==
             Repo.aggregate(
               from(e in Evidence,
                 where: e.memory_id == ^canonical_id and not is_nil(e.source_request_id)
               ),
               :count
             )
  end

  test "concurrent retries atomically report one first write and duplicate replays" do
    host = create_host!("concurrent-ledger", "scope:concurrent")
    item = remember_item("local_concurrent", "scope:concurrent", "concurrent memory")

    results =
      1..8
      |> Task.async_stream(
        fn _ -> HostAgentMemorySync.apply_sync_item(host, item) end,
        max_concurrency: 8,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert 1 == Enum.count(results, &match?({:ok, %{status: :ok}}, &1))
    assert 7 == Enum.count(results, &match?({:ok, %{status: :duplicate}}, &1))
    assert 1 == Repo.aggregate(RememberRequest, :count)
    assert 1 == Repo.aggregate(Evidence, :count)
  end

  test "remember rejects changed immutable content or scope without partial writes" do
    host = create_host!("immutable", "scope:first")
    item = remember_item("local_immutable", "scope:first", "first content")

    assert {:ok, %{canonical_id: canonical_id}} =
             HostAgentMemorySync.apply_sync_item(host, item)

    changed_content =
      item
      |> Map.put("content", "changed content")
      |> Map.put("content_hash", sha256_hex("changed content"))

    assert {:error, :validation, :idempotency_conflict} =
             HostAgentMemorySync.apply_sync_item(host, changed_content)

    assert {:error, :validation, "scope is not registered for host"} =
             HostAgentMemorySync.apply_sync_item(host, Map.put(item, "scope", "scope:changed"))

    assert 1 == Repo.aggregate(RememberRequest, :count)
    assert 1 == Repo.aggregate(Evidence, :count)

    assert [%MemorySchema{id: ^canonical_id, content: "first content", scope: "scope:first"}] =
             Repo.all(MemorySchema)
  end

  test "remember rejects a supplied content hash mismatch before writing" do
    host = create_host!("hash-mismatch", "scope:hash")

    item =
      remember_item("local_bad_hash", "scope:hash", "trusted content")
      |> Map.put("content_hash", String.duplicate("0", 64))

    assert {:error, :validation, "content_hash does not match content"} =
             HostAgentMemorySync.apply_sync_item(host, item)

    assert 0 == Repo.aggregate(MemorySchema, :count)
    assert 0 == Repo.aggregate(RememberRequest, :count)
    assert 0 == Repo.aggregate(Evidence, :count)
  end

  test "remember accepts uppercase hex hashes and rejects non-string supplied hashes" do
    host = create_host!("hash-shape", "scope:hash-shape")
    content = "case-insensitive hash"

    assert {:ok, %{status: :ok}} =
             HostAgentMemorySync.apply_sync_item(
               host,
               remember_item("uppercase", "scope:hash-shape", content)
               |> Map.put("content_hash", String.upcase(sha256_hex(content)))
             )

    assert {:error, :validation, "content_hash does not match content"} =
             HostAgentMemorySync.apply_sync_item(
               host,
               remember_item("invalid", "scope:hash-shape", "invalid hash shape")
               |> Map.put("content_hash", 123)
             )

    assert 1 == Repo.aggregate(MemorySchema, :count)
    assert 1 == Repo.aggregate(RememberRequest, :count)
  end

  test "remember rejects scope injection and ignores payload memory type" do
    host = create_host!("payload-trust", "proj_local")

    assert {:error, :validation, "scope is not registered for host"} =
             HostAgentMemorySync.apply_sync_item(
               host,
               remember_item("evil", "scope:foreign", "untrusted scope")
             )

    assert {:ok, %{canonical_id: id}} =
             HostAgentMemorySync.apply_sync_item(
               host,
               remember_item("typed", "proj_local", "forced episodic")
               |> Map.put("type", "procedural")
             )

    assert %MemorySchema{memory_type: "episodic"} = Repo.get!(MemorySchema, id)
  end

  test "fact payload removes private host mapping metadata" do
    host = create_host!("fact-redaction", "scope:redacted")

    memory =
      insert_memory!(host, "scope:redacted", "redacted fact",
        memory_type: "semantic",
        metadata: %{"public" => "yes", "host_memory" => %{"local_id" => "secret"}}
      )

    assert {:full, [%{"id" => id, "metadata" => %{"public" => "yes"}}]} =
             HostAgentMemorySync.facts_for_scope(host, "scope:redacted", nil)

    assert id == memory.id
  end

  test "identical content from two hosts with one scope remains partitioned" do
    scope = "scope:shared"
    first_host = create_host!("shared-first", scope)
    second_host = create_host!("shared-second", scope)
    content = "shared host memory"

    durable_fact =
      insert_memory!(first_host, scope, "shared durable fact", memory_type: "semantic")

    first_item = remember_item("first_local", scope, content) |> Map.put("type", "semantic")
    second_item = remember_item("second_local", scope, content) |> Map.put("type", "semantic")

    assert {:ok, %{status: :ok, canonical_id: canonical_id}} =
             HostAgentMemorySync.apply_sync_item(first_host, first_item)

    assert {:ok, %{status: :ok, canonical_id: second_canonical_id}} =
             HostAgentMemorySync.apply_sync_item(second_host, second_item)

    refute second_canonical_id == canonical_id

    assert %MemorySchema{id: ^canonical_id, host_id: first_host_id, metadata: metadata} =
             Repo.get!(MemorySchema, canonical_id)

    assert first_host_id == first_host.id
    assert get_in(metadata, ["host_memory", "local_id"]) == "first_local"
    assert 2 == Repo.aggregate(RememberRequest, :count)
    assert 2 == Repo.aggregate(Evidence, :count)
    assert MapSet.member?(HostAgentMemorySync.entitled_scopes(first_host), scope)
    assert MapSet.member?(HostAgentMemorySync.entitled_scopes(second_host), scope)

    assert {:ok, %{status: :ok, canonical_id: ^second_canonical_id}} =
             HostAgentMemorySync.apply_sync_item(second_host, %{
               "id" => "second_local",
               "op" => "forget",
               "scope" => scope
             })

    assert %MemorySchema{deleted_at: nil} = Repo.get!(MemorySchema, canonical_id)

    assert {:full, [%{"id" => fact_id}]} =
             HostAgentMemorySync.facts_for_scope(first_host, scope, nil)

    assert fact_id == durable_fact.id
    assert {:full, []} = HostAgentMemorySync.facts_for_scope(second_host, scope, nil)
    assert [] = HostAgentMemorySync.active_wipes(first_host, scope)

    assert [%{"remote_id" => ^second_canonical_id}] =
             HostAgentMemorySync.active_wipes(second_host, scope)
  end

  test "forget binds remote id to the authenticated host local mapping" do
    host = create_host!("forget-binding", "scope:binding")
    content = "same canonical source"

    assert {:ok, %{canonical_id: canonical_id}} =
             HostAgentMemorySync.apply_sync_item(
               host,
               remember_item("local_a", "scope:binding", content)
             )

    assert {:ok, %{canonical_id: ^canonical_id}} =
             HostAgentMemorySync.apply_sync_item(
               host,
               remember_item("local_b", "scope:binding", content)
             )

    forget = %{
      "id" => "local_a",
      "op" => "forget",
      "remote_id" => canonical_id,
      "scope" => "scope:binding"
    }

    assert {:error, :validation, "remote_id does not match local mapping"} =
             HostAgentMemorySync.apply_sync_item(host, %{
               forget
               | "remote_id" => Ecto.UUID.generate()
             })

    assert %MemorySchema{deleted_at: nil} = Repo.get!(MemorySchema, canonical_id)
    assert 0 == Repo.aggregate(HostMemoryRevocation, :count)

    assert {:ok, %{canonical_id: ^canonical_id}} =
             HostAgentMemorySync.apply_sync_item(host, forget)

    assert {:ok, %{status: :duplicate, canonical_id: ^canonical_id}} =
             HostAgentMemorySync.apply_sync_item(host, forget)

    assert {:error, :validation, :mapping_revoked} =
             HostAgentMemorySync.apply_sync_item(
               host,
               remember_item("local_b", "scope:binding", content)
             )

    assert {:ok, %{status: :duplicate, canonical_id: ^canonical_id}} =
             HostAgentMemorySync.apply_sync_item(host, %{
               "id" => "local_b",
               "op" => "forget",
               "remote_id" => canonical_id,
               "scope" => "scope:binding"
             })

    assert 2 == Repo.aggregate(HostMemoryRevocation, :count)

    assert ["local_a", "local_b"] ==
             HostMemoryRevocation
             |> order_by([revocation], asc: revocation.local_id)
             |> select([revocation], revocation.local_id)
             |> Repo.all()
  end

  test "forget rejects malformed supplied remote ids but accepts explicit nil" do
    scope = "scope:remote-id-shape"
    host = create_host!("remote-id-shape", scope)

    assert {:ok, %{canonical_id: canonical_id}} =
             HostAgentMemorySync.apply_sync_item(
               host,
               remember_item("local_remote_shape", scope, "remote id shape")
             )

    forget = %{"id" => "local_remote_shape", "op" => "forget", "scope" => scope}

    for malformed <- [123, "", "   ", "not-a-uuid", %{"uuid" => canonical_id}] do
      assert {:error, :validation, "remote_id must be a UUID"} =
               HostAgentMemorySync.apply_sync_item(
                 host,
                 Map.put(forget, "remote_id", malformed)
               )

      assert %MemorySchema{deleted_at: nil, lifecycle_state: "active"} =
               Repo.get!(MemorySchema, canonical_id)

      assert 0 == Repo.aggregate(HostMemoryRevocation, :count)
    end

    assert {:ok, %{status: :ok, canonical_id: ^canonical_id}} =
             HostAgentMemorySync.apply_sync_item(host, Map.put(forget, "remote_id", nil))
  end

  test "reloads the current registered scope instead of trusting a stale host struct" do
    stale_host = create_host!("fresh-scope", "scope:old")
    assert {:ok, current_host} = Hosts.update_agent(stale_host, %{"memory_scope" => "scope:new"})

    assert {:error, :validation, "scope is not registered for host"} =
             HostAgentMemorySync.apply_sync_item(
               stale_host,
               remember_item("stale", "scope:old", "stale scope")
             )

    assert MapSet.new(["scope:new"]) == HostAgentMemorySync.entitled_scopes(stale_host)
    assert MapSet.new(["scope:new"]) == HostAgentMemorySync.entitled_scopes(current_host)
  end

  test "forget tombstones the canonical mapped memory and remains idempotent" do
    scope = "scope:same-batch"
    host = create_host!("same-batch", scope)

    assert {:ok, %{canonical_id: canonical_id}} =
             HostAgentMemorySync.apply_sync_item(
               host,
               remember_item("local_2", scope, "remember then forget")
             )

    forget = %{"id" => "local_2", "op" => "forget", "scope" => scope}

    assert {:ok, %{status: :ok, canonical_id: ^canonical_id}} =
             HostAgentMemorySync.apply_sync_item(host, forget)

    assert %MemorySchema{deleted_at: %DateTime{}, lifecycle_state: "tombstoned"} =
             Repo.get!(MemorySchema, canonical_id)

    assert [%{"remote_id" => ^canonical_id}] =
             HostAgentMemorySync.active_wipes(host, scope)

    assert {:ok, %{status: :duplicate, canonical_id: ^canonical_id}} =
             HostAgentMemorySync.apply_sync_item(host, forget)

    assert 1 == Repo.aggregate(HostMemoryRevocation, :count)

    assert {:error, :validation, :mapping_revoked} =
             HostAgentMemorySync.apply_sync_item(
               host,
               remember_item("local_2", scope, "remember then forget")
             )
  end

  test "local-id forget rejects the wrong scope and leaves the canonical memory active" do
    host = create_host!("wrong-forget-scope", "scope:owned")

    assert {:ok, %{canonical_id: canonical_id}} =
             HostAgentMemorySync.apply_sync_item(
               host,
               remember_item("local_scoped", "scope:owned", "scope-bound local memory")
             )

    assert {:error, :validation, "scope is not registered for host"} =
             HostAgentMemorySync.apply_sync_item(host, %{
               "id" => "local_scoped",
               "op" => "forget",
               "scope" => "scope:wrong"
             })

    assert %MemorySchema{deleted_at: nil} = Repo.get!(MemorySchema, canonical_id)
    assert [] = HostAgentMemorySync.active_wipes(host, "scope:owned")
    assert 0 == Repo.aggregate(HostMemoryRevocation, :count)
  end

  test "forget rejects remote ids owned by another host" do
    requester = create_host!("requester", "scope:private")
    owner = create_host!("owner", "scope:private")
    foreign = insert_memory!(owner, "scope:private", "foreign memory", memory_type: "episodic")

    assert {:error, :validation, _reason} =
             HostAgentMemorySync.apply_sync_item(requester, %{
               "id" => "forget_foreign",
               "op" => "forget",
               "remote_id" => foreign.id,
               "scope" => "scope:private"
             })

    assert %MemorySchema{deleted_at: nil} = Repo.get!(MemorySchema, foreign.id)
    assert 0 == Repo.aggregate(HostMemoryRevocation, :count)
  end

  test "canonical lifecycle failure rolls back the revocation" do
    scope = "scope:atomic-forget"
    host = create_host!("atomic-forget", scope)

    assert {:ok, %{canonical_id: canonical_id}} =
             HostAgentMemorySync.apply_sync_item(
               host,
               remember_item("local_atomic", scope, "atomically forgotten")
             )

    Repo.query!("""
    CREATE FUNCTION bpm_test_fail_host_tombstone() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      RAISE EXCEPTION 'injected host tombstone failure' USING ERRCODE = '23514';
    END; $$
    """)

    Repo.query!("""
    CREATE TRIGGER bpm_test_fail_host_tombstone
    BEFORE UPDATE ON bpm_memories
    FOR EACH ROW
    WHEN (NEW.id = '#{canonical_id}'::uuid AND NEW.lifecycle_state = 'tombstoned')
    EXECUTE FUNCTION bpm_test_fail_host_tombstone()
    """)

    assert_raise Postgrex.Error, fn ->
      HostAgentMemorySync.apply_sync_item(host, %{
        "id" => "local_atomic",
        "op" => "forget",
        "scope" => scope
      })
    end

    assert %MemorySchema{deleted_at: nil, lifecycle_state: "active"} =
             Repo.get!(MemorySchema, canonical_id)

    assert 0 == Repo.aggregate(HostMemoryRevocation, :count)
  end

  test "conflicting alias revocation rolls back the tombstone and prior alias revocations" do
    scope = "scope:revocation-conflict"
    host = create_host!("revocation-conflict", scope)
    content = "requested memory"

    assert {:ok, %{canonical_id: canonical_id}} =
             HostAgentMemorySync.apply_sync_item(
               host,
               remember_item("local_a", scope, content)
             )

    assert {:ok, %{canonical_id: ^canonical_id}} =
             HostAgentMemorySync.apply_sync_item(
               host,
               remember_item("local_b", scope, content)
             )

    foreign = insert_memory!(host, scope, "conflicting memory", memory_type: "episodic")
    partition = partition_for!(host, scope)

    assert {:ok, conflict} =
             %HostMemoryRevocation{}
             |> HostMemoryRevocation.changeset(%{
               memory_space_id: partition.memory_space_id,
               host_id: host.id,
               source_client_id: foreign.source_client_id,
               local_id: "local_b",
               memory_id: foreign.id,
               scope: partition.scope,
               namespace: partition.namespace,
               content_hash: foreign.content_hash
             })
             |> Repo.insert()

    assert {:error, :validation, :revocation_conflict} =
             HostAgentMemorySync.apply_sync_item(host, %{
               "id" => "local_a",
               "op" => "forget",
               "remote_id" => canonical_id,
               "scope" => scope
             })

    assert %MemorySchema{deleted_at: nil, lifecycle_state: "active"} =
             Repo.get!(MemorySchema, canonical_id)

    assert [%HostMemoryRevocation{id: conflict_id, memory_id: foreign_id}] =
             Repo.all(HostMemoryRevocation)

    assert conflict_id == conflict.id
    assert foreign_id == foreign.id

    refute Repo.exists?(
             from(revocation in HostMemoryRevocation,
               where: revocation.memory_id == ^canonical_id
             )
           )
  end

  test "host forget remains a soft tombstone when global hard delete is enabled" do
    previous = Backplane.Settings.get("memory.hard_delete_enabled")
    :ok = Backplane.Settings.set("memory.hard_delete_enabled", "true")
    on_exit(fn -> Backplane.Settings.set("memory.hard_delete_enabled", previous) end)

    scope = "scope:always-soft"
    host = create_host!("always-soft", scope)

    assert {:ok, %{canonical_id: canonical_id}} =
             HostAgentMemorySync.apply_sync_item(
               host,
               remember_item("local_soft", scope, "retain the canonical tombstone")
             )

    assert {:ok, %{status: :ok, canonical_id: ^canonical_id}} =
             HostAgentMemorySync.apply_sync_item(host, %{
               "id" => "local_soft",
               "op" => "forget",
               "scope" => scope
             })

    assert %MemorySchema{deleted_at: %DateTime{}, lifecycle_state: "tombstoned"} =
             Repo.get!(MemorySchema, canonical_id)

    assert 1 == Repo.aggregate(HostMemoryRevocation, :count)
  end

  test "facts_for_scope returns canonical hub facts and recognizes matching hashes" do
    scope = "scope:facts"
    host = create_host!("facts", scope)

    fact =
      insert_memory!(host, scope, "use the project formatter",
        memory_type: "semantic",
        tags: ["style"]
      )

    _episodic = insert_memory!(host, scope, "draft local note", memory_type: "episodic")

    assert {:full, facts} = HostAgentMemorySync.facts_for_scope(host, scope, "stale")

    assert [
             %{
               "id" => fact_id,
               "content" => "use the project formatter",
               "content_hash" => content_hash,
               "tags" => ["style"],
               "metadata" => %{},
               "updated_at" => updated_at
             }
           ] = facts

    assert fact_id == fact.id
    assert content_hash == Base.encode16(fact.content_hash, case: :lower)
    assert is_binary(updated_at)

    assert :unchanged =
             HostAgentMemorySync.facts_for_scope(host, scope, fact_set_hash(facts))
  end

  test "entitled_scopes and active_wipes are backed by memory rows" do
    host = create_host!("entitled", "scope:entitled")
    other = create_host!("other", "scope:foreign")
    scope = "scope:entitled"

    _owned = insert_memory!(host, scope, "owned fact", memory_type: "semantic")
    _foreign = insert_memory!(other, "scope:foreign", "foreign fact", memory_type: "semantic")

    deleted =
      host
      |> insert_memory!(scope, "deleted fact", memory_type: "semantic")
      |> Ecto.Changeset.change(deleted_at: DateTime.utc_now(), lifecycle_state: "tombstoned")
      |> Repo.update!()

    entitled = HostAgentMemorySync.entitled_scopes(host)
    assert MapSet.member?(entitled, scope)
    refute MapSet.member?(entitled, "scope:foreign")

    assert [
             %{
               "directive_id" => directive_id,
               "remote_id" => deleted_id,
               "content_hash" => deleted_hash,
               "scope" => ^scope
             }
           ] = HostAgentMemorySync.active_wipes(host, scope)

    assert directive_id == "deleted:#{deleted.id}"
    assert deleted_id == deleted.id
    assert deleted_hash == Base.encode16(deleted.content_hash, case: :lower)
  end

  defp create_host!(suffix, memory_scope) do
    name = "host-memory-sync-#{suffix}-#{System.unique_integer([:positive])}"

    assert {:ok, host, _auth_token, _token} =
             Hosts.create_agent_with_token(%{"name" => name, "memory_scope" => memory_scope})

    host
  end

  defp remember_item(local_id, scope, content) do
    %{
      "id" => local_id,
      "op" => "remember",
      "content" => content,
      "content_hash" => sha256_hex(content),
      "scope" => scope,
      "agent_id" => "agent_1",
      "tags" => ["local"],
      "metadata" => %{"source" => "test"}
    }
  end

  defp insert_memory!(host, scope, content, opts) do
    partition = partition_for!(host, scope)

    attrs = %{
      content: content,
      memory_space_id: partition.memory_space_id,
      memory_type: Keyword.get(opts, :memory_type, "semantic"),
      scope: partition.scope,
      agent_id: "agent_1",
      host_id: host.id,
      client_id: "host:#{host.id}",
      source_client_id: Keyword.get(opts, :source_client_id, "host:#{host.id}"),
      namespace: partition.namespace,
      tags: Keyword.get(opts, :tags, []),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    %MemorySchema{} |> MemorySchema.changeset(attrs) |> Repo.insert!()
  end

  defp partition_for!(host, scope) do
    assert {:ok, partition} = MemorySpaces.resolve_host_partition(host.id, scope, "private")
    partition
  end

  defp memories_for(host, scope, opts) do
    include_deleted? = Keyword.fetch!(opts, :include_deleted)

    MemorySchema
    |> where([memory], memory.host_id == ^host.id)
    |> where([memory], memory.scope == ^scope)
    |> maybe_exclude_deleted(include_deleted?)
    |> order_by([memory], asc: memory.inserted_at)
    |> Repo.all()
  end

  defp maybe_exclude_deleted(query, true), do: query
  defp maybe_exclude_deleted(query, false), do: where(query, [memory], is_nil(memory.deleted_at))

  defp fact_set_hash(facts) do
    facts
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp sha256_hex(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end
end

defmodule Backplane.Api.HostAgentMemorySyncConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Backplane.Api.{HostAgentMemorySync, HostMemoryRevocation}
  alias Backplane.Memory.Audit
  alias Backplane.Memory.Memories.Memory, as: MemorySchema
  alias Backplane.MemorySpaces
  alias Backplane.Repo
  alias Backplane.Skills.Host
  alias Ecto.Adapters.SQL.Sandbox

  @timeout 30_000

  test "independent connections serialize concurrent same-local forgets" do
    scope = unique("scope:same-local")
    host = create_host!("same-local", scope)
    cleanup_on_exit(host.id)

    canonical_id =
      remember!(host, "local_same", scope, "concurrent same-local forget #{host.id}")

    forget = %{"id" => "local_same", "op" => "forget", "scope" => scope}

    results =
      1..8
      |> Task.async_stream(
        fn _ -> unboxed(fn -> HostAgentMemorySync.apply_sync_item(host, forget) end) end,
        max_concurrency: 8,
        timeout: @timeout,
        on_timeout: :kill_task,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert 1 == Enum.count(results, &match?({:ok, %{status: :ok}}, &1))
    assert 7 == Enum.count(results, &match?({:ok, %{status: :duplicate}}, &1))

    unboxed(fn ->
      assert %MemorySchema{deleted_at: %DateTime{}, lifecycle_state: "tombstoned"} =
               Repo.get!(MemorySchema, canonical_id)

      assert 1 ==
               Repo.aggregate(
                 from(revocation in HostMemoryRevocation,
                   where: revocation.host_id == ^host.id
                 ),
                 :count
               )

      assert 1 == forget_audit_count(canonical_id)
    end)
  end

  test "different aliases converge under one canonical lock" do
    scope = unique("scope:aliases")
    host = create_host!("aliases", scope)
    cleanup_on_exit(host.id)
    content = "concurrent alias forget #{host.id}"

    canonical_id = remember!(host, "local_a", scope, content)
    assert canonical_id == remember!(host, "local_b", scope, content)

    gate = hold_memory_row_lock(canonical_id)

    forgets = [
      %{"id" => "local_a", "op" => "forget", "scope" => scope},
      %{"id" => "local_b", "op" => "forget", "scope" => scope}
    ]

    lock_tag = unique("host-memory-alias-race")
    tasks = concurrent_forget_tasks(host, forgets, lock_tag)
    wait_for_lock_waiters!(lock_tag, 2, 100)
    send(gate.pid, :release)
    assert {:ok, :ok} = Task.await(gate, @timeout)
    results = Enum.map(tasks, &Task.await(&1, @timeout))

    assert 1 == Enum.count(results, &match?({:ok, %{status: :ok}}, &1))
    assert 1 == Enum.count(results, &match?({:ok, %{status: :duplicate}}, &1))

    unboxed(fn ->
      assert %MemorySchema{deleted_at: %DateTime{}, lifecycle_state: "tombstoned"} =
               Repo.get!(MemorySchema, canonical_id)

      assert ["local_a", "local_b"] ==
               HostMemoryRevocation
               |> where([revocation], revocation.host_id == ^host.id)
               |> order_by([revocation], asc: revocation.local_id)
               |> select([revocation], revocation.local_id)
               |> Repo.all()

      assert 1 == forget_audit_count(canonical_id)

      assert {:error, :validation, :mapping_revoked} =
               HostAgentMemorySync.apply_sync_item(
                 host,
                 remember_item("local_b", scope, content)
               )
    end)
  end

  defp concurrent_forget_tasks(host, forgets, lock_tag) do
    parent = self()

    tasks =
      Enum.map(forgets, fn forget ->
        Task.async(fn ->
          send(parent, {:forget_ready, self()})

          receive do
            :forget ->
              tagged_unboxed(lock_tag, fn ->
                HostAgentMemorySync.apply_sync_item(host, forget)
              end)
          after
            @timeout -> raise "timed out waiting to start concurrent forget"
          end
        end)
      end)

    pids =
      Enum.map(tasks, fn _task ->
        assert_receive {:forget_ready, pid}, @timeout
        pid
      end)

    Enum.each(pids, &send(&1, :forget))
    tasks
  end

  defp hold_memory_row_lock(memory_id) do
    parent = self()

    gate =
      Task.async(fn ->
        unboxed(fn ->
          Repo.transaction(fn ->
            Repo.query!("SELECT id FROM bpm_memories WHERE id = $1::uuid FOR UPDATE", [
              Ecto.UUID.dump!(memory_id)
            ])

            send(parent, {:memory_row_locked, self()})

            receive do
              :release -> :ok
            after
              @timeout -> Repo.rollback(:gate_timeout)
            end
          end)
        end)
      end)

    assert_receive {:memory_row_locked, gate_pid}, @timeout
    assert gate_pid == gate.pid
    gate
  end

  defp wait_for_lock_waiters!(_lock_tag, _expected, 0),
    do: flunk("concurrent forget workers did not reach their database locks")

  defp wait_for_lock_waiters!(lock_tag, expected, attempts) do
    count =
      unboxed(fn ->
        %{rows: [[count]]} =
          Repo.query!(
            """
            SELECT count(*)::integer
            FROM pg_stat_activity
            WHERE datname = current_database()
              AND pid <> pg_backend_pid()
              AND wait_event_type = 'Lock'
              AND application_name = $1
            """,
            [lock_tag]
          )

        count
      end)

    if count >= expected do
      :ok
    else
      Process.sleep(20)
      wait_for_lock_waiters!(lock_tag, expected, attempts - 1)
    end
  end

  defp create_host!(suffix, memory_scope) do
    unboxed(fn ->
      host =
        %Host{}
        |> Host.changeset(%{
          "name" => unique("host-memory-sync-concurrency:#{suffix}"),
          "memory_scope" => memory_scope
        })
        |> Repo.insert!()

      assert {:ok, _partition} = MemorySpaces.provision_private_host(host.id, memory_scope)
      host
    end)
  end

  defp remember!(host, local_id, scope, content) do
    unboxed(fn ->
      {:ok, %{canonical_id: canonical_id}} =
        HostAgentMemorySync.apply_sync_item(host, remember_item(local_id, scope, content))

      canonical_id
    end)
  end

  defp remember_item(local_id, scope, content) do
    %{
      "id" => local_id,
      "op" => "remember",
      "content" => content,
      "content_hash" => sha256_hex(content),
      "scope" => scope,
      "agent_id" => "agent_1",
      "tags" => ["local"],
      "metadata" => %{"source" => "concurrency-test"}
    }
  end

  defp forget_audit_count(memory_id) do
    Audit.list_for_target(memory_id)
    |> Enum.count(&(&1.operation == "forget"))
  end

  defp cleanup_on_exit(host_id) do
    on_exit(fn ->
      unboxed(fn ->
        memory_space_id = MemorySpaces.private_host_space_id(host_id)

        tables = [
          "bpm_host_memory_revocations",
          "memory_audit_log",
          "bpm_memory_evidence",
          "bpm_host_memory_command_receipts",
          "bpm_memory_remember_requests"
        ]

        Enum.each(tables, &Repo.query!("ALTER TABLE #{&1} DISABLE TRIGGER USER"))

        try do
          Repo.query!("DELETE FROM bpm_host_memory_revocations WHERE host_id = $1", [host_id])
          Repo.query!("DELETE FROM memory_audit_log WHERE metadata->>'host_id' = $1", [host_id])

          Repo.query!(
            """
            DELETE FROM bpm_memory_evidence
            WHERE memory_id IN (SELECT id FROM bpm_memories WHERE host_id = $1)
            """,
            [host_id]
          )

          Repo.query!(
            """
            DELETE FROM bpm_host_memory_command_receipts
            WHERE source_request_id IN
              (SELECT id FROM bpm_memory_remember_requests WHERE idempotency_scope = $1)
            """,
            ["host-memory.v1:#{host_id}"]
          )

          Repo.query!(
            """
            DELETE FROM bpm_memory_remember_requests
            WHERE idempotency_scope = $1
            """,
            ["host-memory.v1:#{host_id}"]
          )

          Repo.query!("DELETE FROM bpm_memories WHERE host_id = $1", [host_id])

          for table <- [
                "bpm_host_memory_deliveries",
                "bpm_host_memory_cursors",
                "bpm_memory_snapshot_chunks",
                "bpm_memory_snapshots",
                "bpm_memory_changes",
                "bpm_memory_partition_revisions"
              ] do
            case table do
              "bpm_memory_snapshot_chunks" ->
                Repo.query!(
                  "DELETE FROM bpm_memory_snapshot_chunks WHERE snapshot_id IN (SELECT id FROM bpm_memory_snapshots WHERE memory_space_id = $1::uuid)",
                  [Ecto.UUID.dump!(memory_space_id)]
                )

              _ ->
                Repo.query!("DELETE FROM #{table} WHERE memory_space_id = $1::uuid", [
                  Ecto.UUID.dump!(memory_space_id)
                ])
            end
          end

          Repo.query!("DELETE FROM bpm_memory_space_entitlements WHERE host_id = $1::uuid", [
            Ecto.UUID.dump!(host_id)
          ])

          Repo.query!(
            "DELETE FROM bpm_memory_space_legacy_aliases WHERE memory_space_id = $1::uuid",
            [Ecto.UUID.dump!(memory_space_id)]
          )

          for table <- ["bpm_projection_snapshots", "bpm_projection_states"] do
            Repo.query!("DELETE FROM #{table} WHERE memory_space_id = $1::uuid", [
              Ecto.UUID.dump!(memory_space_id)
            ])
          end

          Repo.query!("DELETE FROM bpm_memory_spaces WHERE id = $1::uuid", [
            Ecto.UUID.dump!(memory_space_id)
          ])

          Repo.query!("DELETE FROM skill_hosts WHERE id = $1::uuid", [Ecto.UUID.dump!(host_id)])
        after
          Enum.each(Enum.reverse(tables), &Repo.query!("ALTER TABLE #{&1} ENABLE TRIGGER USER"))
        end
      end)
    end)
  end

  defp unboxed(fun) do
    :ok = Sandbox.checkout(Repo, sandbox: false)

    try do
      fun.()
    after
      :ok = Sandbox.checkin(Repo)
    end
  end

  defp tagged_unboxed(lock_tag, fun) do
    unboxed(fn ->
      Repo.query!("SELECT set_config('application_name', $1, false)", [lock_tag])

      try do
        fun.()
      after
        Repo.query!("RESET application_name")
      end
    end)
  end

  defp sha256_hex(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end

  defp unique(prefix), do: "#{prefix}:#{Ecto.UUID.generate()}"
end

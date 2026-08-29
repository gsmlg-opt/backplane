defmodule Backplane.Api.HostAgentMemorySyncTest do
  use Backplane.Api.DataCase, async: false

  import Ecto.Query

  alias Backplane.Repo
  alias Backplane.Skills.Hosts
  alias Backplane.Api.HostAgentMemorySync
  alias Backplane.Api.HostMemoryRevocation
  alias Backplane.Memory.Memories.{Evidence, RememberRequest}
  alias Backplane.Memory.Memories.Memory, as: MemorySchema

  setup do
    Application.delete_env(:backplane_api, :host_memory_sync_adapter)
    Application.delete_env(:backplane_api, :memory_service)
    :ok
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

  test "remember retries keep one immutable request and one request evidence row" do
    host = create_host!("retry-ledger", "scope:retry")
    item = remember_item("local_retry", "scope:retry", "retry-safe memory")

    results = Enum.map(1..10, fn _attempt -> HostAgentMemorySync.apply_sync_item(host, item) end)

    assert [{:ok, %{status: :ok, canonical_id: canonical_id}} | retries] = results

    assert Enum.all?(retries, fn result ->
             result == {:ok, %{status: :duplicate, canonical_id: canonical_id}}
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
    requester = create_host!("requester")
    owner = create_host!("owner")
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

    assert {:ok, conflict} =
             %HostMemoryRevocation{}
             |> HostMemoryRevocation.changeset(%{
               host_id: host.id,
               local_id: "local_b",
               memory_id: foreign.id,
               scope: scope,
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
    other = create_host!("other")
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

  defp create_host!(suffix, memory_scope \\ "proj_local") do
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
    attrs = %{
      content: content,
      memory_type: Keyword.get(opts, :memory_type, "semantic"),
      scope: scope,
      agent_id: "agent_1",
      host_id: host.id,
      client_id: "host:#{host.id}",
      namespace: "private",
      tags: Keyword.get(opts, :tags, []),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    %MemorySchema{} |> MemorySchema.changeset(attrs) |> Repo.insert!()
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
      %Host{}
      |> Host.changeset(%{
        "name" => unique("host-memory-sync-concurrency:#{suffix}"),
        "memory_scope" => memory_scope
      })
      |> Repo.insert!()
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
        tables = [
          "bpm_host_memory_revocations",
          "memory_audit_log",
          "bpm_memory_evidence",
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
            DELETE FROM bpm_memory_remember_requests
            WHERE idempotency_scope = $1
            """,
            ["host-memory.v1:#{host_id}"]
          )

          Repo.query!("DELETE FROM bpm_memories WHERE host_id = $1", [host_id])
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

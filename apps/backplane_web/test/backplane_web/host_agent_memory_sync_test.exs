defmodule BackplaneWeb.HostAgentMemorySyncTest do
  use Backplane.DataCase, async: false

  import Ecto.Query

  alias Backplane.Repo
  alias Backplane.Skills.Hosts
  alias BackplaneWeb.HostAgentMemorySync
  alias BackplaneMemory.Memories.Memory, as: MemorySchema

  setup do
    Application.delete_env(:backplane_web, :host_memory_sync_adapter)
    Application.delete_env(:backplane_web, :memory_service)
    :ok
  end

  test "remember maps a host local id to one stable canonical memory id" do
    host = create_host!("remember")
    item = remember_item("local_1", "scope:stable", "local memory")

    assert {:ok, %{status: :ok, canonical_id: canonical_id}} =
             HostAgentMemorySync.apply_sync_item(host, item)

    assert {:ok, %{status: :duplicate, canonical_id: ^canonical_id}} =
             HostAgentMemorySync.apply_sync_item(host, item)

    assert [
             %MemorySchema{
               id: ^canonical_id,
               metadata: %{
                 "host_memory" => %{
                   "local_id" => "local_1",
                   "content_hash" => _
                 }
               }
             }
           ] = memories_for(host, "scope:stable", include_deleted: true)
  end

  test "forget resolves a host local id remembered earlier in the same sync flow" do
    host = create_host!("same-batch")
    scope = "scope:same-batch"

    assert {:ok, %{canonical_id: canonical_id}} =
             HostAgentMemorySync.apply_sync_item(
               host,
               remember_item("local_2", scope, "remember then forget")
             )

    assert {:ok, %{status: :ok, canonical_id: ^canonical_id}} =
             HostAgentMemorySync.apply_sync_item(host, %{
               "id" => "local_2",
               "op" => "forget",
               "scope" => scope
             })

    assert [%MemorySchema{id: ^canonical_id, deleted_at: %DateTime{}}] =
             memories_for(host, scope, include_deleted: true)
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
  end

  test "facts_for_scope returns canonical hub facts and recognizes matching hashes" do
    host = create_host!("facts")
    scope = "scope:facts"

    fact =
      insert_memory!(host, scope, "use the project formatter",
        memory_type: "semantic",
        tags: ["style"]
      )

    _episodic = insert_memory!(host, scope, "draft local note", memory_type: "episodic")

    assert {:full, facts} = HostAgentMemorySync.facts_for_scope(scope, "stale")

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
    assert :unchanged = HostAgentMemorySync.facts_for_scope(scope, fact_set_hash(facts))
  end

  test "entitled_scopes and active_wipes are backed by memory rows" do
    host = create_host!("entitled")
    other = create_host!("other")
    scope = "scope:entitled"

    _owned = insert_memory!(host, scope, "owned fact", memory_type: "semantic")
    _foreign = insert_memory!(other, "scope:foreign", "foreign fact", memory_type: "semantic")

    deleted =
      host
      |> insert_memory!(scope, "deleted fact", memory_type: "semantic")
      |> Ecto.Changeset.change(deleted_at: DateTime.utc_now())
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
           ] = HostAgentMemorySync.active_wipes(scope)

    assert directive_id == "deleted:#{deleted.id}"
    assert deleted_id == deleted.id
    assert deleted_hash == Base.encode16(deleted.content_hash, case: :lower)
  end

  defp create_host!(suffix) do
    name = "host-memory-sync-#{suffix}-#{System.unique_integer([:positive])}"
    assert {:ok, host, _auth_token, _token} = Hosts.create_agent_with_token(%{"name" => name})
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

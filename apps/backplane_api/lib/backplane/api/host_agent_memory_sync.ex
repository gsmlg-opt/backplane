defmodule Backplane.Api.HostAgentMemorySync do
  @moduledoc """
  Default hub-side adapter for host-agent memory sync protocol events.
  """

  import Ecto.Query

  alias Backplane.Repo
  alias BackplaneMemory.Memory
  alias BackplaneMemory.Memories.Memory, as: MemorySchema

  @fact_memory_types ~w(semantic procedural)
  @host_memory_metadata_key "host_memory"

  def apply_sync_item(host, %{"op" => "remember"} = item) do
    with {:ok, local_id} <- required_binary(item, "id"),
         {:ok, content} <- required_binary(item, "content") do
      scope = scope_for(item)

      case find_by_local_id(host.id, scope, local_id) do
        %MemorySchema{} = existing ->
          {:ok, %{status: :duplicate, canonical_id: existing.id}}

        nil ->
          remember_host_item(host, item, local_id, content, scope)
      end
    else
      {:error, reason} -> {:error, :validation, reason}
    end
  end

  def apply_sync_item(host, %{"op" => "forget"} = item) do
    with {:ok, memory} <- resolve_forget_memory(host, item),
         :ok <- Memory.forget(memory.id) do
      {:ok, %{status: :ok, canonical_id: memory.id}}
    else
      {:error, reason} -> {:error, :validation, reason}
    end
  end

  def apply_sync_item(_host, _item), do: {:error, :validation, "unsupported memory sync op"}

  def facts_for_scope(scope, host_fact_set_hash) when is_binary(scope) do
    facts =
      MemorySchema
      |> where([memory], memory.scope == ^scope)
      |> where([memory], memory.memory_type in ^@fact_memory_types)
      |> where([memory], is_nil(memory.deleted_at))
      |> order_by([memory], asc: memory.id, asc: memory.updated_at)
      |> select([memory], %{
        id: memory.id,
        content: memory.content,
        content_hash: memory.content_hash,
        tags: memory.tags,
        metadata: memory.metadata,
        updated_at: memory.updated_at
      })
      |> Repo.all()
      |> Enum.map(&fact_payload/1)

    if host_fact_set_hash == fact_set_hash(facts) do
      :unchanged
    else
      {:full, facts}
    end
  end

  def facts_for_scope(_scope, _host_fact_set_hash), do: :unchanged

  def active_wipes(scope) when is_binary(scope) do
    MemorySchema
    |> where([memory], memory.scope == ^scope)
    |> where([memory], not is_nil(memory.deleted_at))
    |> order_by([memory], asc: memory.deleted_at, asc: memory.id)
    |> select([memory], %{
      id: memory.id,
      scope: memory.scope,
      content_hash: memory.content_hash
    })
    |> Repo.all()
    |> Enum.map(fn memory ->
      %{
        "directive_id" => "deleted:#{memory.id}",
        "remote_id" => memory.id,
        "content_hash" => encode_hash(memory.content_hash),
        "scope" => memory.scope
      }
    end)
  end

  def active_wipes(_scope), do: []

  def entitled_scopes(host) do
    MemorySchema
    |> where([memory], memory.host_id == ^host.id)
    |> where([memory], not is_nil(memory.scope))
    |> distinct(true)
    |> select([memory], memory.scope)
    |> Repo.all()
    |> MapSet.new()
  end

  defp remember_host_item(host, item, local_id, content, scope) do
    content_hash = :crypto.hash(:sha256, content)
    duplicate? = not is_nil(find_by_content_hash(scope, content_hash))
    host_content_hash = host_content_hash(item, content)
    metadata = item |> Map.get("metadata", %{}) |> normalize_metadata()

    opts = [
      type: optional_binary(item, "type") || "episodic",
      scope: scope,
      agent_id: optional_binary(item, "agent_id") || "",
      host_id: host.id,
      client_id: optional_binary(item, "client_id"),
      session_id: optional_binary(item, "session_id"),
      tags: normalize_tags(Map.get(item, "tags", [])),
      metadata: put_host_metadata(metadata, local_id, host_content_hash)
    ]

    case Memory.remember(content, opts) do
      {:ok, %MemorySchema{} = memory} ->
        memory = ensure_local_mapping(memory, host.id, local_id, host_content_hash)
        status = if duplicate?, do: :duplicate, else: :ok
        {:ok, %{status: status, canonical_id: memory.id}}

      {:error, reason} ->
        {:error, :validation, reason}
    end
  end

  defp resolve_forget_memory(host, item) do
    scope = optional_scope(item)

    memory =
      case optional_binary(item, "remote_id") do
        nil -> find_by_local_id(host.id, scope_for(item), item["id"])
        remote_id -> find_by_remote_id(host.id, remote_id, scope)
      end

    case memory do
      %MemorySchema{} = memory -> {:ok, memory}
      nil -> {:error, "memory not found"}
    end
  end

  defp find_by_remote_id(host_id, remote_id, scope) do
    with {:ok, uuid} <- Ecto.UUID.cast(remote_id) do
      MemorySchema
      |> where([memory], memory.id == ^uuid)
      |> where([memory], memory.host_id == ^host_id)
      |> where([memory], is_nil(memory.deleted_at))
      |> maybe_scope(scope)
      |> limit(1)
      |> Repo.one()
    else
      :error -> nil
    end
  end

  defp find_by_local_id(host_id, scope, local_id) when is_binary(local_id) do
    MemorySchema
    |> where([memory], memory.host_id == ^host_id)
    |> where([memory], is_nil(memory.deleted_at))
    |> where(
      [memory],
      fragment("?->'host_memory'->>'local_id' = ?", memory.metadata, ^local_id)
    )
    |> maybe_scope(scope)
    |> order_by([memory], desc: memory.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  defp find_by_local_id(_host_id, _scope, _local_id), do: nil

  defp find_by_content_hash(scope, content_hash) do
    MemorySchema
    |> where([memory], memory.scope == ^scope)
    |> where([memory], memory.content_hash == ^content_hash)
    |> where([memory], is_nil(memory.deleted_at))
    |> limit(1)
    |> Repo.one()
  end

  defp maybe_scope(query, nil), do: query
  defp maybe_scope(query, scope), do: where(query, [memory], memory.scope == ^scope)

  defp ensure_local_mapping(
         %MemorySchema{host_id: host_id} = memory,
         host_id,
         local_id,
         content_hash
       ) do
    if get_in(memory.metadata || %{}, [@host_memory_metadata_key, "local_id"]) == local_id do
      memory
    else
      memory
      |> Ecto.Changeset.change(
        metadata: put_host_metadata(memory.metadata || %{}, local_id, content_hash)
      )
      |> Repo.update!()
    end
  end

  defp ensure_local_mapping(memory, _host_id, _local_id, _content_hash), do: memory

  defp fact_payload(memory) do
    %{
      "id" => memory.id,
      "content" => memory.content,
      "content_hash" => encode_hash(memory.content_hash),
      "tags" => memory.tags || [],
      "metadata" => memory.metadata || %{},
      "updated_at" => DateTime.to_iso8601(memory.updated_at)
    }
  end

  defp fact_set_hash(facts) do
    facts
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp put_host_metadata(metadata, local_id, content_hash) do
    Map.put(metadata, @host_memory_metadata_key, %{
      "local_id" => local_id,
      "content_hash" => content_hash
    })
  end

  defp host_content_hash(%{"content_hash" => hash}, _content)
       when is_binary(hash) and hash != "" do
    hash
  end

  defp host_content_hash(_item, content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end

  defp scope_for(item), do: optional_scope(item) || "global"

  defp optional_scope(item), do: optional_binary(item, "scope")

  defp optional_binary(item, key) do
    case Map.get(item, key) do
      value when is_binary(value) and value != "" -> value
      _other -> nil
    end
  end

  defp required_binary(item, key) do
    case optional_binary(item, key) do
      nil -> {:error, "#{key} is required and must be a string"}
      value -> {:ok, value}
    end
  end

  defp normalize_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_metadata(_metadata), do: %{}

  defp normalize_tags(tags) when is_list(tags) do
    Enum.filter(tags, &is_binary/1)
  end

  defp normalize_tags(_tags), do: []

  defp encode_hash(nil), do: nil
  defp encode_hash(hash) when is_binary(hash), do: Base.encode16(hash, case: :lower)
end

defmodule Backplane.Api.HostAgentMemorySync do
  @moduledoc """
  Default hub-side adapter for host-agent memory sync protocol events.
  """

  import Ecto.Query

  alias Backplane.Repo
  alias Backplane.Memory.Memories
  alias Backplane.Memory.Memories.RememberRequest
  alias Backplane.Memory.Memories.Memory, as: MemorySchema
  alias Backplane.Api.HostMemoryRevocation
  alias Backplane.Skills.Host

  @fact_memory_types ~w(semantic procedural)
  @host_memory_metadata_key "host_memory"
  @host_memory_idempotency_prefix "host-memory.v1:"

  def apply_sync_item(host, %{"op" => "remember"} = item) do
    with {:ok, host} <- reload_host(host),
         {:ok, local_id} <- required_binary(item, "id"),
         {:ok, content} <- required_binary(item, "content"),
         :ok <- validate_content_hash(item, content),
         :ok <- validate_host_scope(host, scope_for(item)) do
      remember_host_item(host, item, local_id, content, scope_for(item))
    else
      {:error, reason} -> {:error, :validation, reason}
    end
  end

  def apply_sync_item(host, %{"op" => "forget"} = item) do
    with {:ok, host} <- reload_host(host),
         :ok <- validate_host_scope(host, scope_for(item)),
         {:ok, mapping} <- resolve_forget_mapping(host, item),
         {:ok, _revocation} <- revoke_mapping(host, mapping) do
      {:ok, %{status: :ok, canonical_id: mapping.memory.id}}
    else
      {:error, reason} -> {:error, :validation, reason}
    end
  end

  def apply_sync_item(_host, _item), do: {:error, :validation, "unsupported memory sync op"}

  def facts_for_scope(host, scope, host_fact_set_hash) when is_binary(scope) do
    with {:ok, current_host} <- reload_host(host),
         :ok <- validate_host_scope(current_host, scope) do
      partition_id = host_partition_id(current_host)

      facts =
        MemorySchema
        |> where([memory], memory.scope == ^scope)
        |> where([memory], memory.namespace == "private")
        |> where([memory], memory.client_id == ^partition_id)
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
    else
      _error -> :unchanged
    end
  end

  def facts_for_scope(_host, _scope, _host_fact_set_hash), do: :unchanged

  def active_wipes(host, scope) when is_binary(scope) do
    with {:ok, current_host} <- reload_host(host),
         :ok <- validate_host_scope(current_host, scope) do
      partition_id = host_partition_id(current_host)

      MemorySchema
      |> where([memory], memory.scope == ^scope)
      |> where([memory], memory.namespace == "private")
      |> where([memory], memory.client_id == ^partition_id)
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
    else
      _error -> []
    end
  end

  def active_wipes(_host, _scope), do: []

  def entitled_scopes(host) do
    case reload_host(host) do
      {:ok, current} -> MapSet.new([current.memory_scope])
      {:error, _reason} -> MapSet.new()
    end
  end

  defp remember_host_item(host, item, local_id, content, scope) do
    host_content_hash = host_content_hash(item, content)
    metadata = item |> Map.get("metadata", %{}) |> normalize_metadata()

    opts = [
      type: "episodic",
      scope: scope,
      agent_id: optional_binary(item, "agent_id") || "",
      host_id: host.id,
      client_id: host_partition_id(host),
      namespace: "private",
      session_id: optional_binary(item, "session_id"),
      tags: normalize_tags(Map.get(item, "tags", [])),
      metadata: put_host_metadata(metadata, local_id, host_content_hash),
      idempotency_scope: host_request_scope(host.id),
      idempotency_key: local_id
    ]

    case Repo.transaction(fn ->
           advisory_lock!(host.id, local_id)

           if revoked?(host.id, local_id), do: Repo.rollback(:mapping_revoked)

           replay? = request_exists?(host.id, local_id)

           case Memories.remember(content, opts) do
             {:ok, %MemorySchema{} = memory} -> {memory, replay?}
             {:error, reason} -> Repo.rollback(reason)
           end
         end) do
      {:ok, {memory, replay?}} ->
        status = if replay?, do: :duplicate, else: :ok
        {:ok, %{status: status, canonical_id: memory.id}}

      {:error, reason} ->
        {:error, :validation, reason}
    end
  end

  defp resolve_forget_mapping(host, item) do
    with {:ok, local_id} <- required_binary(item, "id"),
         scope = scope_for(item),
         %{memory: %MemorySchema{}} = mapping <-
           find_local_mapping(host.id, scope, local_id) ||
             find_revoked_mapping(host.id, scope, local_id),
         :ok <- validate_remote_id(item, mapping.memory.id) do
      {:ok, mapping}
    else
      nil -> {:error, "memory not found"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp find_local_mapping(host_id, scope, local_id) when is_binary(local_id) do
    request_memory =
      from(request in RememberRequest, as: :request)
      |> join(:inner, [request], memory in MemorySchema, on: memory.id == request.memory_id)
      |> where([request, _memory], request.idempotency_scope == ^host_request_scope(host_id))
      |> where([request, _memory], request.idempotency_key == ^local_id)
      |> where([_request, memory], is_nil(memory.deleted_at))
      |> where(
        [request, _memory],
        not exists(
          from(rv in HostMemoryRevocation, where: rv.source_request_id == parent_as(:request).id)
        )
      )
      |> select([request, memory], {memory, request})
      |> limit(1)
      |> Repo.one()

    case request_memory do
      {%MemorySchema{scope: ^scope} = memory, request} ->
        %{memory: memory, request: request, local_id: local_id}

      {%MemorySchema{}, _request} ->
        nil

      nil ->
        case find_legacy_local_mapping(host_id, scope, local_id) do
          nil -> nil
          memory -> %{memory: memory, request: nil, local_id: local_id}
        end
    end
  end

  defp find_local_mapping(_host_id, _scope, _local_id), do: nil

  defp find_revoked_mapping(host_id, scope, local_id) when is_binary(local_id) do
    HostMemoryRevocation
    |> join(:inner, [revocation], memory in MemorySchema, on: memory.id == revocation.memory_id)
    |> where(
      [revocation, _memory],
      revocation.host_id == ^host_id and revocation.local_id == ^local_id
    )
    |> where([revocation, _memory], revocation.scope == ^scope)
    |> select([revocation, memory], %{memory: memory, request: nil, local_id: revocation.local_id})
    |> limit(1)
    |> Repo.one()
  end

  defp find_revoked_mapping(_host_id, _scope, _local_id), do: nil

  defp find_legacy_local_mapping(host_id, scope, local_id) do
    from(memory in MemorySchema, as: :memory)
    |> where([memory], memory.host_id == ^host_id)
    |> where([memory], is_nil(memory.deleted_at))
    |> where([memory], memory.scope == ^scope)
    |> where(
      [memory],
      not exists(
        from(rv in HostMemoryRevocation,
          where: rv.host_id == ^host_id and rv.local_id == ^local_id
        )
      )
    )
    |> where(
      [memory],
      fragment("?->'host_memory'->>'local_id' = ?", memory.metadata, ^local_id)
    )
    |> order_by([memory], desc: memory.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  defp fact_payload(memory) do
    %{
      "id" => memory.id,
      "content" => memory.content,
      "content_hash" => encode_hash(memory.content_hash),
      "tags" => memory.tags || [],
      "metadata" => Map.delete(memory.metadata || %{}, @host_memory_metadata_key),
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
    String.downcase(hash)
  end

  defp host_content_hash(_item, content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end

  defp validate_content_hash(%{"content_hash" => hash}, content)
       when is_binary(hash) and hash != "" do
    if String.downcase(hash) == host_content_hash(%{}, content) do
      :ok
    else
      {:error, "content_hash does not match content"}
    end
  end

  defp validate_content_hash(%{"content_hash" => _invalid}, _content),
    do: {:error, "content_hash does not match content"}

  defp validate_content_hash(_item, _content), do: :ok

  defp host_request_scope(host_id), do: @host_memory_idempotency_prefix <> host_id
  defp host_partition_id(%Host{id: host_id}), do: "host:" <> host_id
  defp validate_host_scope(%{memory_scope: scope}, scope), do: :ok
  defp validate_host_scope(_host, _scope), do: {:error, "scope is not registered for host"}

  defp reload_host(%{id: id}) when is_binary(id) do
    case Repo.get(Host, id) do
      %Host{} = host -> {:ok, host}
      nil -> {:error, "host is not registered"}
    end
  end

  defp reload_host(_host), do: {:error, "host is not registered"}

  defp validate_remote_id(item, memory_id) do
    case optional_binary(item, "remote_id") do
      nil ->
        :ok

      remote_id ->
        case Ecto.UUID.cast(remote_id) do
          {:ok, ^memory_id} -> :ok
          _ -> {:error, "remote_id does not match local mapping"}
        end
    end
  end

  defp request_exists?(host_id, local_id) do
    Repo.exists?(
      from(r in RememberRequest,
        where:
          r.idempotency_scope == ^host_request_scope(host_id) and r.idempotency_key == ^local_id
      )
    )
  end

  defp revoked?(host_id, local_id),
    do:
      Repo.exists?(
        from(r in HostMemoryRevocation, where: r.host_id == ^host_id and r.local_id == ^local_id)
      )

  defp revoke_mapping(host, mapping) do
    attrs = %{
      host_id: host.id,
      local_id: mapping.local_id,
      memory_id: mapping.memory.id,
      source_request_id: mapping.request && mapping.request.id,
      scope: mapping.memory.scope,
      content_hash: mapping.memory.content_hash
    }

    Repo.insert(HostMemoryRevocation.changeset(%HostMemoryRevocation{}, attrs),
      on_conflict: :nothing
    )
  end

  defp advisory_lock!(host_id, local_id) do
    <<key::signed-64, _::binary>> =
      :crypto.hash(
        :sha256,
        :erlang.term_to_binary(["host-memory", host_id, local_id], [:deterministic])
      )

    Repo.query!("SELECT pg_advisory_xact_lock($1::bigint)", [key])
    :ok
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

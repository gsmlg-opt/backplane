defmodule Backplane.Memory.Authorization do
  @moduledoc "Authorizes a Memory operation and derives its trusted host partition."

  alias Backplane.Clients
  alias Backplane.Memory.Partition
  alias Backplane.Memory.Memories.Memory
  alias Backplane.MemoryPermissions

  import Ecto.Query

  @trusted_kinds [:oauth, :client_token, :legacy, :open]

  @spec authorize_tool(String.t(), map(), map()) ::
          {:ok, map(), map()} | {:error, :unauthorized}
  def authorize_tool(name, args, auth)
      when is_binary(name) and is_map(args) and is_map(auth) do
    with %{kind: kind, client_id: client_id, scopes: scopes} <- auth,
         true <- kind in @trusted_kinds,
         true <- trusted_identity?(kind, client_id),
         true <- is_list(scopes),
         {:ok, _permission} <- MemoryPermissions.for_tool(name),
         true <- Clients.scope_matches?(scopes, name),
         {:ok, partition} <- Partition.resolve(auth),
         :ok <- validate_requested_partition(args, partition),
         :ok <- validate_memory_target(name, args, partition) do
      {:ok, trusted_args(args, partition), partition}
    else
      {:error, reason} -> {:error, reason}
      _failure -> {:error, :unauthorized}
    end
  end

  def authorize_tool(_name, _args, _auth), do: {:error, :unauthorized}

  defp trusted_identity?(kind, client_id) when kind in [:oauth, :client_token],
    do: is_binary(client_id) and client_id != ""

  defp trusted_identity?(kind, _client_id) when kind in [:legacy, :open], do: true

  defp validate_requested_partition(args, partition) do
    with :ok <- matches_if_present(args, "host_id", partition.host_id),
         :ok <- matches_if_present(args, "client_id", partition.partition_id),
         :ok <- matches_if_present(args, "namespace", partition.namespace),
         :ok <- matches_if_present(args, "scope", partition.scope) do
      :ok
    end
  end

  defp matches_if_present(args, key, expected) do
    case Map.fetch(args, key) do
      :error -> :ok
      {:ok, ^expected} -> :ok
      {:ok, _other} -> {:error, :unauthorized}
    end
  end

  defp trusted_args(args, partition) do
    Map.merge(args, %{
      "host_id" => partition.host_id,
      "client_id" => partition.partition_id,
      "namespace" => partition.namespace,
      "scope" => partition.scope
    })
  end

  @memory_target_keys %{
    "memory::access_log" => "memory_id",
    "memory::apply" => "memory_id",
    "memory::enrich" => "memory_id",
    "memory::facet_tag" => "memory_id",
    "memory::forget" => "id",
    "memory::governance_delete" => "memory_id",
    "memory::lesson_archive" => "memory_id",
    "memory::lesson_promote" => "memory_id",
    "memory::lesson_strengthen" => "memory_id",
    "memory::team_share" => "memory_id",
    "memory::verify" => "memory_id"
  }

  defp validate_memory_target(name, args, partition) do
    case Map.fetch(@memory_target_keys, name) do
      :error ->
        :ok

      {:ok, key} ->
        case args[key] do
          id when is_binary(id) -> owned_memory(id, partition)
          _missing -> :ok
        end
    end
  end

  defp owned_memory(id, partition) do
    query =
      from(m in Memory,
        where:
          m.id == ^id and m.host_id == ^partition.host_id and
            m.client_id == ^partition.partition_id and m.scope == ^partition.scope and
            m.namespace == ^partition.namespace
      )

    if repo().exists?(query), do: :ok, else: {:error, "memory not found"}
  end

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)
end

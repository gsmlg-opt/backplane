defmodule Backplane.Memory.Partition do
  @moduledoc false

  import Ecto.Query

  alias Backplane.MemorySpaces
  alias Backplane.Repo
  alias Backplane.Skills.Host

  @prefix "host:"

  def resolve(%{kind: kind, principal_metadata: metadata} = auth)
      when kind in [:oauth, :client_token] and is_map(metadata) do
    with partition_id when is_binary(partition_id) <- metadata["memory_partition_id"],
         <<@prefix, host_id::binary>> <- partition_id,
         {:ok, canonical_host_id} <- Ecto.UUID.cast(host_id),
         true <- canonical_host_id == host_id,
         {:ok, partition} <-
           MemorySpaces.resolve_host_partition(
             host_id,
             metadata["scope"],
             metadata["namespace"] || "private"
           ),
         :ok <- validate_claim(metadata, partition) do
      {:ok, enrich(partition, host_id, partition_id, source_client_id(auth, metadata))}
    else
      {:error, reason} when reason in [:ambiguous_partition, :partition_not_ready] ->
        {:error, reason}

      _failure ->
        {:error, :unauthorized}
    end
  end

  # Open and legacy MCP modes remain available, but Memory can only derive a
  # safe owner when the installation has exactly one host partition.
  def resolve(%{kind: kind}) when kind in [:legacy, :open] do
    case Repo.all(from(h in Host, order_by: h.id, limit: 2)) do
      [%Host{} = host] -> resolved(host, nil)
      _zero_or_ambiguous -> {:error, :unauthorized}
    end
  end

  def resolve(_auth), do: {:error, :unauthorized}

  defp resolved(host, source_client_id) do
    with {:ok, partition} <- MemorySpaces.resolve_host_partition(host.id, nil, "private") do
      {:ok, enrich(partition, host.id, @prefix <> host.id, source_client_id)}
    end
  end

  defp validate_claim(metadata, partition) do
    claimed_space = metadata["memory_space_id"]

    if is_nil(claimed_space) or claimed_space == partition.memory_space_id,
      do: :ok,
      else: {:error, :partition_mismatch}
  end

  defp enrich(partition, host_id, partition_id, source_client_id) do
    partition
    |> Map.merge(%{
      partition_id: partition_id,
      host_id: host_id,
      client_id: partition_id
    })
    |> maybe_put_source_client_id(source_client_id)
  end

  defp source_client_id(auth, metadata),
    do:
      metadata["source_client_id"] || Map.get(auth, :source_client_id) ||
        Map.get(auth, :client_id)

  defp maybe_put_source_client_id(partition, value) when is_binary(value),
    do: Map.put(partition, :source_client_id, value)

  defp maybe_put_source_client_id(partition, _value), do: partition
end

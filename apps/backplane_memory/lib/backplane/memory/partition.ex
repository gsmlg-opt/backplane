defmodule Backplane.Memory.Partition do
  @moduledoc false

  import Ecto.Query

  alias Backplane.Repo
  alias Backplane.Skills.Host

  @prefix "host:"

  def resolve(%{kind: kind, principal_metadata: metadata})
      when kind in [:oauth, :client_token] and is_map(metadata) do
    with partition_id when is_binary(partition_id) <- metadata["memory_partition_id"],
         <<@prefix, host_id::binary>> <- partition_id,
         {:ok, canonical_host_id} <- Ecto.UUID.cast(host_id),
         true <- canonical_host_id == host_id,
         %Host{} = host <- Repo.get(Host, host_id) do
      {:ok,
       %{
         partition_id: partition_id,
         host_id: host.id,
         scope: host.memory_scope,
         namespace: "private"
       }}
    else
      _failure -> {:error, :unauthorized}
    end
  end

  # Open and legacy MCP modes remain available, but Memory can only derive a
  # safe owner when the installation has exactly one host partition.
  def resolve(%{kind: kind}) when kind in [:legacy, :open] do
    case Repo.all(from(h in Host, order_by: h.id, limit: 2)) do
      [%Host{} = host] -> resolved(host)
      _zero_or_ambiguous -> {:error, :unauthorized}
    end
  end

  def resolve(_auth), do: {:error, :unauthorized}

  defp resolved(host) do
    {:ok,
     %{
       partition_id: @prefix <> host.id,
       host_id: host.id,
       scope: host.memory_scope,
       namespace: "private"
     }}
  end
end

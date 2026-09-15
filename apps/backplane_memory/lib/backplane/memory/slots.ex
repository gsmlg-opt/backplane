defmodule Backplane.Memory.Slots do
  import Ecto.Query
  alias Backplane.Memory.Slots.Slot
  alias Backplane.Memory.PartitionIdentity

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)

  @doc "Read a slot by name. Returns {:ok, slot} or {:error, :not_found}."
  def read(name) when is_binary(name), do: {:error, :incomplete_partition}

  def read(name, partition) when is_binary(name) do
    with {:ok, partition} <- PartitionIdentity.validate(partition) do
      case repo().one(
             from(s in Slot, where: s.name == ^name, where: ^partition_dynamic(partition))
           ) do
        nil -> {:error, :not_found}
        slot -> {:ok, slot}
      end
    end
  end

  @doc "Write content to a named slot, creating it if it does not exist."
  def write(name, content, _updated_by \\ nil) when is_binary(name) and is_binary(content),
    do: {:error, :incomplete_partition}

  def write(name, content, updated_by, partition) when is_binary(name) and is_binary(content) do
    with {:ok, partition} <- PartitionIdentity.validate(partition) do
      slot =
        repo().one(from(s in Slot, where: s.name == ^name, where: ^partition_dynamic(partition))) ||
          struct(Slot, Map.merge(%{name: name}, partition_attrs(partition)))

      slot
      |> Slot.changeset(%{
        content: content,
        updated_at: DateTime.utc_now(),
        updated_by: updated_by
      })
      |> repo().insert_or_update()
    end
  end

  @doc "List all slots ordered by name."
  def list, do: []

  def list(partition) do
    with {:ok, partition} <- PartitionIdentity.validate(partition) do
      repo().all(from(s in Slot, where: ^partition_dynamic(partition), order_by: s.name))
    else
      {:error, _reason} -> []
    end
  end

  defp partition_dynamic(partition) when is_map(partition),
    do:
      dynamic(
        [row],
        row.memory_space_id == ^Map.fetch!(partition, :memory_space_id) and
          row.host_id == ^Map.fetch!(partition, :host_id) and
          row.client_id == ^Map.fetch!(partition, :client_id) and
          row.scope == ^Map.fetch!(partition, :scope) and
          row.namespace == ^Map.fetch!(partition, :namespace)
      )

  defp partition_attrs(partition) when is_map(partition),
    do:
      Map.take(partition, [
        :memory_space_id,
        :host_id,
        :client_id,
        :source_client_id,
        :scope,
        :namespace
      ])
end

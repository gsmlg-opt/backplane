defmodule Backplane.Memory.Slots do
  import Ecto.Query
  alias Backplane.Memory.Slots.Slot

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)

  @doc "Read a slot by name. Returns {:ok, slot} or {:error, :not_found}."
  def read(name) when is_binary(name), do: read(name, nil)

  def read(name, partition) when is_binary(name) do
    case repo().one(from(s in Slot, where: s.name == ^name, where: ^partition_dynamic(partition))) do
      nil -> {:error, :not_found}
      slot -> {:ok, slot}
    end
  end

  @doc "Write content to a named slot, creating it if it does not exist."
  def write(name, content, updated_by \\ nil) when is_binary(name) and is_binary(content),
    do: write(name, content, updated_by, nil)

  def write(name, content, updated_by, partition) when is_binary(name) and is_binary(content) do
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

  @doc "List all slots ordered by name."
  def list, do: list(nil)

  def list(partition) do
    repo().all(from(s in Slot, where: ^partition_dynamic(partition), order_by: s.name))
  end

  defp partition_dynamic(partition) when is_map(partition),
    do:
      dynamic(
        [row],
        row.host_id == ^Map.fetch!(partition, :host_id) and
          row.client_id == ^Map.fetch!(partition, :client_id) and
          row.scope == ^Map.fetch!(partition, :scope) and
          row.namespace == ^Map.fetch!(partition, :namespace)
      )

  defp partition_dynamic(nil),
    do:
      dynamic(
        [row],
        is_nil(row.host_id) and is_nil(row.client_id) and is_nil(row.scope) and
          is_nil(row.namespace)
      )

  defp partition_attrs(partition) when is_map(partition),
    do: Map.take(partition, [:host_id, :client_id, :scope, :namespace])

  defp partition_attrs(nil), do: %{}
end

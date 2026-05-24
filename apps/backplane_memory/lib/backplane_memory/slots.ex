defmodule BackplaneMemory.Slots do
  import Ecto.Query
  alias BackplaneMemory.Slots.Slot

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)

  @doc "Read a slot by name. Returns {:ok, slot} or {:error, :not_found}."
  def read(name) when is_binary(name) do
    case repo().get(Slot, name) do
      nil -> {:error, :not_found}
      slot -> {:ok, slot}
    end
  end

  @doc "Write content to a named slot, creating it if it does not exist."
  def write(name, content, updated_by \\ nil) when is_binary(name) and is_binary(content) do
    slot = repo().get(Slot, name) || %Slot{name: name}

    slot
    |> Slot.changeset(%{
      content: content,
      updated_at: DateTime.utc_now(),
      updated_by: updated_by
    })
    |> repo().insert_or_update()
  end

  @doc "List all slots ordered by name."
  def list do
    repo().all(from(s in Slot, order_by: s.name))
  end
end

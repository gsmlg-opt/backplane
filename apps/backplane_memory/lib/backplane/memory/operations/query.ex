defmodule Backplane.Memory.Operations.Query do
  @moduledoc false

  alias Backplane.Memory.Events.Event

  def get_event(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        case repo().get(Event, uuid) do
          nil -> {:error, :not_found}
          event -> {:ok, event}
        end

      :error ->
        {:error, :not_found}
    end
  end

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)
end

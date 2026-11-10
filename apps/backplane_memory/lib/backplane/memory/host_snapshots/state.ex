defmodule Backplane.Memory.HostSnapshots.State do
  @moduledoc "Last applied host snapshot per (host, collector, unit), with the fact slots it produced."

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "memory_host_snapshots" do
    field(:host_id, :string)
    field(:collector, :string)
    field(:unit, :string)
    field(:collected_at, :utc_datetime_usec)
    field(:event_id, :binary_id)
    field(:slots, :map, default: %{})

    timestamps(type: :utc_datetime_usec)
  end
end

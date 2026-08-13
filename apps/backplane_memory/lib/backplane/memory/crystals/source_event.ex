defmodule Backplane.Memory.Crystals.SourceEvent do
  use Ecto.Schema

  @primary_key false
  schema "memory_crystal_source_events" do
    field(:crystal_id, :binary_id, primary_key: true)
    field(:event_id, :binary_id, primary_key: true)
    field(:inserted_at, :utc_datetime_usec)
  end
end

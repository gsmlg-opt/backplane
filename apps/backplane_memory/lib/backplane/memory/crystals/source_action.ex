defmodule Backplane.Memory.Crystals.SourceAction do
  use Ecto.Schema

  @primary_key false
  @foreign_key_type :binary_id

  schema "memory_crystal_source_actions" do
    field(:crystal_id, :binary_id, primary_key: true)
    field(:action_id, :binary_id, primary_key: true)
    field(:terminal_override, :boolean, default: false)
    field(:inserted_at, :utc_datetime_usec)
  end
end

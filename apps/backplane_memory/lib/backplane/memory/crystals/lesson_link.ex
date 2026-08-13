defmodule Backplane.Memory.Crystals.LessonLink do
  use Ecto.Schema

  @primary_key false
  @foreign_key_type :binary_id

  schema "memory_crystal_lessons" do
    field(:crystal_id, :binary_id, primary_key: true)
    field(:lesson_memory_id, :binary_id, primary_key: true)
    field(:relation_type, :string)
    field(:inserted_at, :utc_datetime_usec)
  end
end

defmodule Backplane.Memory.Crystals.SourceSummary do
  use Ecto.Schema

  @primary_key false
  schema "memory_crystal_source_summaries" do
    field(:crystal_id, :binary_id, primary_key: true)
    field(:summary_id, :binary_id, primary_key: true)
    field(:inserted_at, :utc_datetime_usec)
  end
end

defmodule Backplane.Memory.Summaries.SourceEvent do
  @moduledoc "Normalized provenance linking a durable summary revision to an exact source event."

  use Ecto.Schema

  @primary_key false
  schema "memory_summary_source_events" do
    field(:summary_id, :binary_id)
    field(:event_id, :binary_id)
    field(:host_id, :string)
    field(:session_id, :string)
    field(:inserted_at, :utc_datetime_usec)
  end
end

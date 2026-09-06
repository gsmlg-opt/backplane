defmodule Backplane.Memory.EdgeSync.Cursor do
  @moduledoc "Durable cursor for host memory convergence."
  use Ecto.Schema

  @primary_key false
  schema "bpm_host_memory_cursors" do
    field(:host_id, :binary_id, primary_key: true)
    field(:memory_space_id, :binary_id, primary_key: true)
    field(:scope, :string, primary_key: true)
    field(:namespace, :string, primary_key: true)
    field(:applied_revision, :integer)
    field(:active_snapshot_id, :binary_id)
    field(:snapshot_next_chunk_index, :integer)
    field(:last_acknowledged_batch_id, :binary_id)
    field(:acknowledged_at, :utc_datetime_usec)
  end
end

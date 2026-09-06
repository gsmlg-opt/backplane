defmodule Backplane.Memory.EdgeSync.SnapshotChunk do
  @moduledoc "Durable snapshot chunk for host memory convergence."
  use Ecto.Schema

  @primary_key false
  schema "bpm_memory_snapshot_chunks" do
    field(:snapshot_id, :binary_id, primary_key: true)
    field(:chunk_index, :integer, primary_key: true)
    field(:item_count, :integer)
    field(:encoded_bytes, :integer)
    field(:chunk_hash, :string)
    field(:payload, :map)
  end
end

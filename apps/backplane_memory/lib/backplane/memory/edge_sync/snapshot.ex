defmodule Backplane.Memory.EdgeSync.Snapshot do
  @moduledoc "Durable snapshot for host memory convergence."
  use Ecto.Schema

  @primary_key false
  schema "bpm_memory_snapshots" do
    field(:id, :binary_id, primary_key: true, autogenerate: true)
    field(:memory_space_id, :binary_id)
    field(:scope, :string)
    field(:namespace, :string)
    field(:revision, :integer)
    field(:item_count, :integer)
    field(:chunk_count, :integer)
    field(:integrity_hash, :string)
    field(:status, :string)
    field(:expires_at, :utc_datetime_usec)
    field(:inserted_at, :utc_datetime_usec)
  end
end

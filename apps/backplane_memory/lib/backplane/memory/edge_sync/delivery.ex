defmodule Backplane.Memory.EdgeSync.Delivery do
  @moduledoc "Durable delivery for host memory convergence."
  use Ecto.Schema

  @primary_key false
  schema "bpm_host_memory_deliveries" do
    field(:id, :binary_id, primary_key: true, autogenerate: true)
    field(:host_id, :binary_id)
    field(:memory_space_id, :binary_id)
    field(:scope, :string)
    field(:namespace, :string)
    field(:kind, :string)
    field(:snapshot_id, :binary_id)
    field(:chunk_index, :integer)
    field(:from_revision, :integer)
    field(:to_revision, :integer)
    field(:payload, :map)
    field(:encoded_bytes, :integer)
    field(:chunk_hash, :string)
    field(:integrity_hash, :string)
    field(:status, :string)
    field(:issued_at, :utc_datetime_usec)
    field(:acknowledged_at, :utc_datetime_usec)
  end
end

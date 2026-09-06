defmodule Backplane.Memory.EdgeSync.CompatReceipt do
  @moduledoc "Durable compat receipt for host memory convergence."
  use Ecto.Schema

  @primary_key false
  schema "bpm_host_memory_compat_receipts" do
    field(:id, :binary_id, primary_key: true, autogenerate: true)
    field(:host_id, :binary_id)
    field(:kind, :string)
    field(:receipt_key, :string)
    field(:scope, :string)
    field(:payload_hash, :string)
    field(:issued_at, :utc_datetime_usec)
    field(:acknowledged_at, :utc_datetime_usec)
  end
end

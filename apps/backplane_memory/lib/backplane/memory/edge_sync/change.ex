defmodule Backplane.Memory.EdgeSync.Change do
  @moduledoc "Durable change for host memory convergence."
  use Ecto.Schema

  @primary_key false
  schema "bpm_memory_changes" do
    field(:memory_space_id, :binary_id, primary_key: true)
    field(:scope, :string, primary_key: true)
    field(:namespace, :string, primary_key: true)
    field(:revision, :integer, primary_key: true)
    field(:op, :string)
    field(:memory_id, :binary_id)
    field(:payload, :map)
    field(:payload_bytes, :integer)
    field(:created_at, :utc_datetime_usec)
  end
end

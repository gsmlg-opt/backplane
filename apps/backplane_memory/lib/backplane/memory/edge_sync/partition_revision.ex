defmodule Backplane.Memory.EdgeSync.PartitionRevision do
  @moduledoc "Durable partition revision for host memory convergence."
  use Ecto.Schema

  @primary_key false
  schema "bpm_memory_partition_revisions" do
    field(:memory_space_id, :binary_id, primary_key: true)
    field(:scope, :string, primary_key: true)
    field(:namespace, :string, primary_key: true)
    field(:current_revision, :integer)
    field(:first_available_revision, :integer)
    field(:updated_at, :utc_datetime_usec)
  end
end

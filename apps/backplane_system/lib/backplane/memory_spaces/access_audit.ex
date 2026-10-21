defmodule Backplane.MemorySpaces.AccessAudit do
  @moduledoc "Append-only, transactional Memory authority history, independent of telemetry."

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "bpm_memory_access_audits" do
    field(:request_id, :binary_id)
    field(:actor_kind, :string)
    field(:actor_ref, :string)
    field(:action, :string)
    field(:access_id, :binary_id)
    field(:host_id, :binary_id)
    field(:memory_space_id, :binary_id)
    field(:scope, :string)
    field(:namespace, :string)
    field(:previous_status, :string)
    field(:new_status, :string)
    field(:previous_capabilities, {:array, :string})
    field(:new_capabilities, {:array, :string})
    field(:previous_offline_read_lease_seconds, :integer)
    field(:new_offline_read_lease_seconds, :integer)
    field(:previous_authority_version, :integer)
    field(:new_authority_version, :integer)
    field(:reason, :string)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end

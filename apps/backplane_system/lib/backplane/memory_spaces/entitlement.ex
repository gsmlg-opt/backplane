defmodule Backplane.MemorySpaces.Entitlement do
  @moduledoc "Host authorization for one exact canonical memory partition."

  use Ecto.Schema
  import Ecto.Changeset

  alias Backplane.MemorySpaces.MemorySpace

  @type t :: %__MODULE__{}
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "bpm_memory_space_entitlements" do
    belongs_to(:memory_space, MemorySpace)
    field(:host_id, :binary_id)
    field(:scope, :string)
    field(:namespace, :string, default: "private")
    field(:default_capture, :boolean, default: false)
    field(:status, :string, default: "active")
    field(:capabilities, {:array, :string}, default: [])
    field(:authority_version, :integer, default: 1)
    field(:offline_read_lease_seconds, :integer, default: 0)
    timestamps()
  end

  @doc false
  def changeset(entitlement, attrs) do
    entitlement
    |> cast(attrs, [
      :memory_space_id,
      :host_id,
      :scope,
      :namespace,
      :default_capture,
      :status,
      :capabilities,
      :authority_version,
      :offline_read_lease_seconds
    ])
    |> update_change(:scope, &String.trim/1)
    |> update_change(:namespace, &String.trim/1)
    |> validate_required([
      :memory_space_id,
      :host_id,
      :scope,
      :namespace,
      :default_capture,
      :status
    ])
    |> validate_inclusion(:status, ["active", "revoked"])
    |> validate_number(:authority_version, greater_than: 0)
    |> validate_number(:offline_read_lease_seconds,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 300
    )
    |> check_constraint(:capabilities, name: :bpm_memory_access_capabilities_check)
    |> check_constraint(:authority_version, name: :bpm_memory_access_version_check)
    |> check_constraint(:offline_read_lease_seconds, name: :bpm_memory_access_lease_check)
    |> foreign_key_constraint(:memory_space_id)
    |> unique_constraint([:memory_space_id, :host_id, :scope, :namespace],
      name: :bpm_memory_space_entitlements_partition_index
    )
    |> unique_constraint(:default_capture,
      name: :bpm_memory_space_entitlements_active_default_index
    )
  end
end

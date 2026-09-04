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
      :status
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
    |> foreign_key_constraint(:memory_space_id)
    |> foreign_key_constraint(:host_id)
    |> unique_constraint([:memory_space_id, :host_id, :scope, :namespace],
      name: :bpm_memory_space_entitlements_partition_index
    )
  end
end

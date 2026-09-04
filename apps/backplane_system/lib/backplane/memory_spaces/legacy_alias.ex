defmodule Backplane.MemorySpaces.LegacyAlias do
  @moduledoc "Stable legacy identity mapped to a canonical memory space."

  use Ecto.Schema
  import Ecto.Changeset

  alias Backplane.MemorySpaces.MemorySpace

  @type t :: %__MODULE__{}
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "bpm_memory_space_legacy_aliases" do
    field(:alias_type, :string)
    field(:alias_value, :string)
    belongs_to(:memory_space, MemorySpace)
    timestamps()
  end

  @doc false
  def changeset(alias_row, attrs) do
    alias_row
    |> cast(attrs, [:alias_type, :alias_value, :memory_space_id])
    |> update_change(:alias_type, &String.trim/1)
    |> update_change(:alias_value, &String.trim/1)
    |> validate_required([:alias_type, :alias_value, :memory_space_id])
    |> foreign_key_constraint(:memory_space_id)
    |> unique_constraint([:alias_type, :alias_value],
      name: :bpm_memory_space_legacy_aliases_identity_index
    )
  end
end

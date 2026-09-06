defmodule Backplane.MemorySpaces.MemorySpace do
  @moduledoc "Stable canonical memory ownership boundary."

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "bpm_memory_spaces" do
    field(:kind, :string)
    field(:status, :string)
    timestamps()
  end

  @doc false
  def changeset(space, attrs) do
    space
    |> cast(attrs, [:id, :kind, :status])
    |> validate_required([:kind, :status])
    |> validate_inclusion(:kind, ["private", "shared"])
    |> validate_inclusion(:status, ["active", "disabled"])
  end
end

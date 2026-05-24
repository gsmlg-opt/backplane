defmodule BackplaneMemory.Facets.Facet do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false, inserted_at: :created_at]

  schema "memory_facets" do
    field(:memory_id, :binary_id)
    field(:dimension, :string)
    field(:value, :string)
    timestamps()
  end

  def changeset(facet, attrs) do
    facet
    |> cast(attrs, [:memory_id, :dimension, :value])
    |> validate_required([:memory_id, :dimension, :value])
  end
end

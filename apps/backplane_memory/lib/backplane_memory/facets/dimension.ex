defmodule BackplaneMemory.Facets.Dimension do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:name, :string, autogenerate: false}
  @timestamps_opts false

  schema "memory_facet_dimensions" do
    field(:description, :string)
    field(:allowed_values, {:array, :string}, default: [])
    field(:created_at, :utc_datetime_usec)
  end

  def changeset(dim, attrs) do
    dim
    |> cast(attrs, [:name, :description, :allowed_values])
    |> validate_required([:name])
  end
end

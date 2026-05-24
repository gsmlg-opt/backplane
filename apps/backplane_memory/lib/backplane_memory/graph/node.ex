defmodule BackplaneMemory.Graph.Node do
  use Ecto.Schema
  import Ecto.Changeset

  @valid_types ~w(File Function Module Library Concept Decision Bug Pattern Person)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false, inserted_at: :created_at]

  schema "memory_graph_nodes" do
    field(:type, :string)
    field(:name, :string)
    field(:properties, :map, default: %{})
    field(:source_observation_ids, {:array, :binary_id}, default: [])
    timestamps()
  end

  def changeset(node, attrs) do
    node
    |> cast(attrs, [:type, :name, :properties, :source_observation_ids])
    |> validate_required([:type, :name])
    |> validate_inclusion(:type, @valid_types)
  end
end

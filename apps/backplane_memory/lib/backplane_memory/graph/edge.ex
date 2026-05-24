defmodule BackplaneMemory.Graph.Edge do
  use Ecto.Schema
  import Ecto.Changeset

  @valid_relations ~w(uses imports calls depends_on tests documents caused_by supersedes relates_to)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false, inserted_at: :created_at]

  schema "memory_graph_edges" do
    field(:source_id, :binary_id)
    field(:target_id, :binary_id)
    field(:relation, :string)
    field(:weight, :float, default: 1.0)
    timestamps()
  end

  def changeset(edge, attrs) do
    edge
    |> cast(attrs, [:source_id, :target_id, :relation, :weight])
    |> validate_required([:source_id, :target_id, :relation])
    |> validate_inclusion(:relation, @valid_relations)
  end
end

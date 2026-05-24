defmodule Backplane.Repo.Migrations.CreateMemoryGraph do
  use Ecto.Migration

  def change do
    create table(:memory_graph_nodes, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:type, :text, null: false)
      add(:name, :text, null: false)
      add(:properties, :map, null: false, default: %{})
      add(:source_observation_ids, {:array, :binary_id}, null: false, default: [])
      add(:created_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create(
      index(:memory_graph_nodes, [:properties],
        using: :gin,
        name: :memory_graph_nodes_properties_gin_idx
      )
    )

    create(index(:memory_graph_nodes, [:type, :name]))

    create table(:memory_graph_edges, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))

      add(:source_id, references(:memory_graph_nodes, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:target_id, references(:memory_graph_nodes, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:relation, :text, null: false)
      add(:weight, :float, null: false, default: 1.0)
      add(:created_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create(index(:memory_graph_edges, [:source_id]))
    create(index(:memory_graph_edges, [:target_id]))
    create(index(:memory_graph_edges, [:relation]))
  end
end

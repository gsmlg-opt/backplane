defmodule Backplane.Repo.Migrations.CreateMemoryFacets do
  use Ecto.Migration

  def change do
    create table(:memory_facet_dimensions, primary_key: false) do
      add(:name, :text, primary_key: true)
      add(:description, :text)
      add(:allowed_values, {:array, :text}, default: [])
      add(:created_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create table(:memory_facets, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))

      add(:memory_id, references(:bpm_memories, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(
        :dimension,
        references(:memory_facet_dimensions, column: :name, type: :text, on_delete: :delete_all),
        null: false
      )

      add(:value, :text, null: false)
      add(:created_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create(index(:memory_facets, [:memory_id]))
    create(index(:memory_facets, [:dimension, :value]))

    create(
      unique_index(:memory_facets, [:memory_id, :dimension], name: :memory_facets_mem_dim_uniq)
    )
  end
end

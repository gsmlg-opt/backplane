defmodule Backplane.Repo.Migrations.CreateMemoryActions do
  use Ecto.Migration

  def change do
    create table(:memory_actions, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:title, :text, null: false)
      add(:description, :text)
      add(:status, :text, null: false, default: "pending")
      add(:priority, :integer, null: false, default: 0)
      add(:created_by, :text)
      add(:project, :text)
      add(:tags, {:array, :text}, null: false, default: [])
      add(:source_observation_ids, {:array, :binary_id}, null: false, default: [])
      add(:source_memory_ids, {:array, :binary_id}, null: false, default: [])
      add(:parent_id, :binary_id)
      add(:created_at, :utc_datetime_usec, null: false, default: fragment("now()"))
      add(:updated_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create(index(:memory_actions, [:status]))
    create(index(:memory_actions, [:project]))
    create(index(:memory_actions, [:priority]))

    create table(:memory_action_edges, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))

      add(
        :source_id,
        references(:memory_actions, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(
        :target_id,
        references(:memory_actions, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:edge_type, :text, null: false)
    end

    create(index(:memory_action_edges, [:source_id]))
    create(index(:memory_action_edges, [:target_id]))
    create(unique_index(:memory_action_edges, [:source_id, :target_id, :edge_type]))

    execute(
      "ALTER TABLE memory_actions ADD CONSTRAINT memory_actions_status_check CHECK (status IN ('pending','in_progress','done','blocked','cancelled'))",
      "ALTER TABLE memory_actions DROP CONSTRAINT memory_actions_status_check"
    )

    execute(
      "ALTER TABLE memory_action_edges ADD CONSTRAINT memory_action_edges_type_check CHECK (edge_type IN ('requires','unlocks','spawned_by','gated_by','conflicts_with'))",
      "ALTER TABLE memory_action_edges DROP CONSTRAINT memory_action_edges_type_check"
    )
  end
end

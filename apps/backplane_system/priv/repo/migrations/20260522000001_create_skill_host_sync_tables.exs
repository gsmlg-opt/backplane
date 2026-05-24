defmodule Backplane.Repo.Migrations.CreateSkillHostSyncTables do
  use Ecto.Migration

  def change do
    create table(:skill_hosts, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :name, :text, null: false
      add :hostname, :text
      add :token_hash, :text, null: false
      add :agent_version, :text
      add :last_seen_at, :utc_datetime_usec
      add :status, :text, null: false, default: "unknown"
      add :targets, :map, null: false, default: %{}
      add :active, :boolean, null: false, default: true
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:skill_hosts, [:name])

    create table(:skill_host_assignments, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :host_id, references(:skill_hosts, type: :binary_id, on_delete: :delete_all), null: false
      add :skill_id, references(:skills, type: :text, column: :id, on_delete: :delete_all), null: false
      add :targets, {:array, :text}, null: false, default: []
      add :enabled, :boolean, null: false, default: true
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:skill_host_assignments, [:host_id])
    create unique_index(:skill_host_assignments, [:host_id, :skill_id])

    create table(:skill_host_statuses, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :host_id, references(:skill_hosts, type: :binary_id, on_delete: :delete_all), null: false
      add :skill_id, references(:skills, type: :text, column: :id, on_delete: :nilify_all)
      add :skill_slug, :text
      add :skill_name, :text, null: false
      add :desired_version, :text
      add :installed_version, :text
      add :desired_checksum, :text
      add :installed_checksum, :text
      add :targets, {:array, :text}, null: false, default: []
      add :status, :text, null: false
      add :error, :text
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:skill_host_statuses, [:host_id])
    create unique_index(:skill_host_statuses, [:host_id, :skill_name])
  end
end

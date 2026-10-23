defmodule Backplane.Repo.Migrations.CreatePluginRegistry do
  use Ecto.Migration

  def change do
    create table(:plugin_sources, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :name, :text, null: false
      add :url, :text, null: false
      add :ref, :text, null: false, default: "HEAD"
      add :path, :text, null: false, default: ""
      add :kind, :text, null: false, default: "plugin"
      add :credential_name, :text
      add :auto_publish, :boolean, null: false, default: false
      add :enabled, :boolean, null: false, default: true
      add :interval_seconds, :integer, null: false, default: 300
      add :last_attempt_at, :utc_datetime_usec
      add :last_success_at, :utc_datetime_usec
      add :source_commit, :text
      add :status, :text, null: false, default: "pending"
      add :diagnostics, {:array, :map}, null: false, default: []
      timestamps(type: :utc_datetime_usec)
    end

    create table(:plugins, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :identity, :text, null: false
      add :publisher, :text, null: false
      add :name, :text, null: false
      add :source_id, references(:plugin_sources, type: :uuid, on_delete: :nilify_all)
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:plugins, [:identity])

    create table(:plugin_releases, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :plugin_id, references(:plugins, type: :uuid, on_delete: :restrict), null: false
      add :manifest, :map, null: false
      add :raw_manifest, :text, null: false
      add :upstream_version, :text
      add :artifact, :binary, null: false
      add :artifact_digest, :text, null: false
      add :source_commit, :text
      add :source_path, :text
      add :provenance, :map, null: false, default: %{}
      add :diagnostics, {:array, :map}, null: false, default: []
      add :published_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:plugin_releases, [:plugin_id, :artifact_digest, :source_commit])
    create index(:plugin_releases, [:artifact_digest])

    create table(:plugin_channels, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :plugin_id, references(:plugins, type: :uuid, on_delete: :restrict), null: false

      add :release_id, references(:plugin_releases, type: :uuid, on_delete: :restrict),
        null: false

      add :name, :text, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:plugin_channels, [:plugin_id, :name])

    create table(:plugin_installations, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :target, :text, null: false
      add :plugin_id, references(:plugins, type: :uuid, on_delete: :restrict), null: false

      add :desired_release_id, references(:plugin_releases, type: :uuid, on_delete: :restrict),
        null: false

      add :actual_release_id, references(:plugin_releases, type: :uuid, on_delete: :restrict)
      add :actual_enabled, :boolean
      add :enabled, :boolean, null: false, default: true
      add :status, :text, null: false, default: "pending"
      add :components, :map, null: false, default: %{}
      add :diagnostics, {:array, :map}, null: false, default: []
      add :reported_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:plugin_installations, [:target, :plugin_id])
  end
end

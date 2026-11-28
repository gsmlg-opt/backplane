defmodule Backplane.Repo.Migrations.CreateDiagnosticsResolutions do
  use Ecto.Migration

  def change do
    create table(:diagnostics_resolutions) do
      add :issue_id, references(:diagnostics_issues, on_delete: :restrict), null: false
      add :repository, :text, null: false
      add :fix_sha, :text
      add :fix_reference, :text
      add :change_identity, :text
      add :releases, {:array, :text}, null: false
      add :source_ids, {:array, :text}, null: false
      add :workload, :text, null: false
      add :min_runs, :integer, null: false
      add :min_seconds, :integer, null: false
      add :test_state, :text, null: false
      add :implementation_state, :text, null: false
      add :deployment_state, :text, null: false
      add :observation_state, :text, null: false
      add :active, :boolean, null: false, default: true
      add :activation_at, :utc_datetime_usec
      add :deployed_at, :utc_datetime_usec
      add :recurrence_event_key, references(:diagnostics_events, on_delete: :nilify_all)
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:diagnostics_resolutions, [:issue_id],
             where: "active",
             name: :diagnostics_active_resolution
           )

    create table(:diagnostics_resolution_checks) do
      add :resolution_id, references(:diagnostics_resolutions, on_delete: :restrict), null: false
      add :state, :text, null: false
      add :evidence_reference, :text, null: false
      add :actor, :text, null: false
      add :checked_at, :utc_datetime_usec, null: false
    end

    create index(:diagnostics_resolution_checks, [:resolution_id, :checked_at])

    create table(:diagnostics_resolution_runs, primary_key: false) do
      add :resolution_id, references(:diagnostics_resolutions, on_delete: :restrict),
        primary_key: true

      add :source_id, :text, primary_key: true
      add :run_id, :text, primary_key: true
      add :event_key, references(:diagnostics_events, on_delete: :nilify_all)
      add :outcome, :text, null: false
      add :observed_at, :utc_datetime_usec, null: false
    end

    create table(:diagnostics_management_actions) do
      add :issue_id, references(:diagnostics_issues, on_delete: :restrict)
      add :action, :text, null: false
      add :actor, :text, null: false
      add :entity_id, :bigint
      add :recorded_at, :utc_datetime_usec, null: false
    end

    create index(:diagnostics_management_actions, [:issue_id, :recorded_at])
  end
end

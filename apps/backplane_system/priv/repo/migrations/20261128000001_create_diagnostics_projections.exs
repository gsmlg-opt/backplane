defmodule Backplane.Repo.Migrations.CreateDiagnosticsProjections do
  use Ecto.Migration

  def change do
    create table(:diagnostics_projection_claims, primary_key: false) do
      add :projector, :text, primary_key: true
      add :projector_version, :integer, primary_key: true

      add :source_id, references(:diagnostics_sources, type: :text, on_delete: :restrict),
        primary_key: true

      add :event_id, :text, primary_key: true
      add :processed_at, :utc_datetime_usec, null: false
    end

    create table(:diagnostics_projection_sequences, primary_key: false) do
      add :source_id, references(:diagnostics_sources, type: :text, on_delete: :restrict),
        primary_key: true

      add :producer_epoch, :text, primary_key: true
      add :projector_version, :integer, primary_key: true
      add :highest_sequence, :bigint, null: false
      add :seen, :bigint, null: false
    end

    create table(:diagnostics_runs) do
      add :source_id, references(:diagnostics_sources, type: :text, on_delete: :restrict),
        null: false

      add :run_id, :text, null: false
      add :parent_run_id, :text
      add :state_event_key, references(:diagnostics_events, on_delete: :restrict)
      add :native_revision, :bigint
      add :state_occurred_at, :utc_datetime_usec
      add :state_epoch, :text
      add :state_sequence, :bigint
      add :phase, :text
      add :outcome, :text
      add :release, :text
      add :workload, :text
      add :deadline_at, :utc_datetime_usec
      add :last_progress_at, :utc_datetime_usec
      add :wait_kind, :text
      add :sampled, :boolean, null: false, default: false
      add :truncated, :boolean, null: false, default: false
      add :source_gap, :boolean, null: false, default: false
      add :clock_skew, :boolean, null: false, default: false
      add :first_seen_at, :utc_datetime_usec, null: false
      add :last_seen_at, :utc_datetime_usec, null: false
    end

    create unique_index(:diagnostics_runs, [:source_id, :run_id])
    create index(:diagnostics_runs, [:source_id, :workload, :last_seen_at])
    create index(:diagnostics_runs, [:source_id, :parent_run_id])

    create table(:diagnostics_run_events, primary_key: false) do
      add :run_key, references(:diagnostics_runs, on_delete: :restrict), primary_key: true
      add :event_key, references(:diagnostics_events, on_delete: :restrict), primary_key: true
      add :disposition, :text, null: false
    end

    create table(:diagnostics_occurrences) do
      add :source_id, references(:diagnostics_sources, type: :text, on_delete: :restrict),
        null: false

      add :identity, :text, null: false
      add :run_key, references(:diagnostics_runs, on_delete: :restrict)
      add :rule, :text, null: false
      add :category, :text, null: false
      add :certainty, :text, null: false
      add :first_seen_at, :utc_datetime_usec, null: false
      add :last_seen_at, :utc_datetime_usec, null: false
    end

    create unique_index(:diagnostics_occurrences, [:source_id, :identity])
    create index(:diagnostics_occurrences, [:run_key])

    create table(:diagnostics_occurrence_events, primary_key: false) do
      add :occurrence_id, references(:diagnostics_occurrences, on_delete: :restrict),
        primary_key: true

      add :event_key, references(:diagnostics_events, on_delete: :restrict), primary_key: true
    end

    create index(:diagnostics_occurrence_events, [:event_key])

    create table(:diagnostics_issues) do
      add :fingerprint, :text, null: false
      add :fingerprint_version, :integer, null: false
      add :category, :text, null: false
      add :severity, :text, null: false
      add :status, :text, null: false, default: "open"
      add :occurrence_count, :bigint, null: false, default: 0
      add :first_seen_at, :utc_datetime_usec, null: false
      add :last_seen_at, :utc_datetime_usec, null: false
    end

    create unique_index(:diagnostics_issues, [:fingerprint_version, :fingerprint])
    create index(:diagnostics_issues, [:status, :last_seen_at])

    create table(:diagnostics_issue_occurrences, primary_key: false) do
      add :issue_id, references(:diagnostics_issues, on_delete: :restrict), primary_key: true

      add :occurrence_id, references(:diagnostics_occurrences, on_delete: :restrict),
        primary_key: true
    end

    create unique_index(:diagnostics_issue_occurrences, [:occurrence_id])

    create table(:diagnostics_issue_evidence_kinds, primary_key: false) do
      add :issue_id, references(:diagnostics_issues, on_delete: :restrict), primary_key: true
      add :digest, :text, primary_key: true
    end

    create table(:diagnostics_issue_grouping_actions) do
      add :from_issue_id, references(:diagnostics_issues, on_delete: :restrict), null: false
      add :to_issue_id, references(:diagnostics_issues, on_delete: :restrict), null: false
      add :occurrence_id, references(:diagnostics_occurrences, on_delete: :restrict), null: false
      add :actor, :text, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    execute(
      "CREATE SEQUENCE diagnostics_issue_change_revisions",
      "DROP SEQUENCE diagnostics_issue_change_revisions"
    )

    create table(:diagnostics_issue_changes, primary_key: false) do
      add :issue_id, references(:diagnostics_issues, on_delete: :restrict), primary_key: true
      add :event_key, references(:diagnostics_events, on_delete: :restrict), null: false
      add :kind, :text, null: false

      add :revision, :bigint,
        null: false,
        default: fragment("nextval('diagnostics_issue_change_revisions')")

      add :available_at, :utc_datetime_usec, null: false
    end

    create index(:diagnostics_issue_changes, [:available_at, :issue_id])

    create table(:diagnostics_findings) do
      add :event_key, references(:diagnostics_events, on_delete: :restrict), null: false
      add :occurrence_id, references(:diagnostics_occurrences, on_delete: :restrict)
      add :rule, :text, null: false
      add :rule_version, :integer, null: false
      add :status, :text, null: false
      add :category, :text, null: false
      add :details, :map, null: false
      add :evidence_event_ids, {:array, :bigint}, null: false
    end

    create unique_index(:diagnostics_findings, [:event_key, :rule, :rule_version])
    create index(:diagnostics_findings, [:occurrence_id])
    create index(:diagnostics_findings, [:rule, :status, :event_key])
    create index(:diagnostics_events, [:source_id, :event_type, :occurred_at])
  end
end

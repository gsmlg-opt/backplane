defmodule Backplane.Repo.Migrations.CreateDiagnosticsAnalyses do
  use Ecto.Migration

  def change do
    create table(:diagnostics_evidence_bundles) do
      add :issue_id, references(:diagnostics_issues, on_delete: :delete_all), null: false
      add :digest, :text, null: false
      add :payload, :map
      add :expires_at, :utc_datetime_usec, null: false
      add :expired_at, :utc_datetime_usec
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:diagnostics_evidence_bundles, [:issue_id, :digest])
    create index(:diagnostics_evidence_bundles, [:expires_at], where: "payload IS NOT NULL")

    create table(:diagnostics_reports, primary_key: false) do
      add :issue_id, references(:diagnostics_issues, on_delete: :delete_all), primary_key: true
      add :revision, :bigint, null: false
      add :change, :text, null: false
      add :body, :map, null: false
      add :evidence_bundle_id, references(:diagnostics_evidence_bundles, on_delete: :nilify_all)
      timestamps(type: :utc_datetime_usec)
    end

    create table(:diagnostics_notification_candidates) do
      add :issue_id, references(:diagnostics_issues, on_delete: :delete_all), null: false
      add :report_revision, :bigint, null: false
      add :kind, :text, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:diagnostics_notification_candidates, [:issue_id, :report_revision, :kind])

    create table(:diagnostics_analyses) do
      add :issue_id, references(:diagnostics_issues, on_delete: :delete_all), null: false

      add :evidence_bundle_id, references(:diagnostics_evidence_bundles, on_delete: :restrict),
        null: false

      add :evidence_digest, :text, null: false
      add :policy_version, :integer, null: false
      add :template_version, :integer, null: false
      add :status, :text, null: false
      add :reason, :text
      add :model, :text
      add :result, :map
      add :usage, :map
      add :available_at, :utc_datetime_usec, null: false
      add :bypass_cooldown, :boolean, null: false, default: false
      add :attempts, :integer, null: false, default: 0
      add :lease_token, :text
      add :lease_until, :utc_datetime_usec
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec
      add :expired_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:diagnostics_analyses, [:issue_id, :evidence_digest, :policy_version],
             name: :diagnostics_analysis_evidence_policy
           )

    create unique_index(:diagnostics_analyses, [:issue_id],
             where: "status = 'running'",
             name: :diagnostics_analysis_running_per_issue
           )

    create unique_index(:diagnostics_analyses, [:issue_id],
             where: "status IN ('queued', 'waiting_for_model', 'budget_exhausted', 'retrying')",
             name: :diagnostics_analysis_pending_per_issue
           )

    create index(:diagnostics_analyses, [:available_at, :id],
             where: "status IN ('queued', 'waiting_for_model', 'budget_exhausted', 'retrying')",
             name: :diagnostics_analysis_due
           )

    create index(:diagnostics_analyses, [:lease_until], where: "status = 'running'")

    create table(:diagnostics_analysis_budgets, primary_key: false) do
      add :day, :date, primary_key: true
      add :calls, :integer, null: false
      add :tokens, :bigint, null: false
      add :cost_micros, :bigint, null: false
    end

    create table(:diagnostics_repair_tasks) do
      add :issue_id, references(:diagnostics_issues, on_delete: :delete_all), null: false
      add :analysis_id, references(:diagnostics_analyses, on_delete: :delete_all), null: false

      add :evidence_bundle_id, references(:diagnostics_evidence_bundles, on_delete: :restrict),
        null: false

      add :body, :map
      add :expired_at, :utc_datetime_usec
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:diagnostics_repair_tasks, [:analysis_id])
    create index(:diagnostics_repair_tasks, [:issue_id, :id])
  end
end

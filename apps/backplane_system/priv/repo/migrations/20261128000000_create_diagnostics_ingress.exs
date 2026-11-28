defmodule Backplane.Repo.Migrations.CreateDiagnosticsIngress do
  use Ecto.Migration

  def change do
    create table(:diagnostics_sources, primary_key: false) do
      add :id, :text, primary_key: true
      add :host_id, references(:skill_hosts, type: :binary_id, on_delete: :nilify_all)
      add :application, :text, null: false
      add :repository, :text
      add :service_instance, :text
      add :enabled, :boolean, null: false, default: true
      timestamps(type: :utc_datetime_usec)
    end

    create index(:diagnostics_sources, [:host_id])

    create table(:diagnostics_event_receipts, primary_key: false) do
      add :source_id, references(:diagnostics_sources, type: :text, on_delete: :restrict),
        primary_key: true

      add :event_id, :text, primary_key: true
      add :producer_epoch, :text, null: false
      add :source_sequence, :bigint, null: false
      add :forward_digest, :text, null: false
      add :received_at, :utc_datetime_usec, null: false
    end

    create unique_index(
             :diagnostics_event_receipts,
             [:source_id, :producer_epoch, :source_sequence],
             name: :diagnostics_receipt_source_sequence_index
           )

    create table(:diagnostics_epochs, primary_key: false) do
      add :source_id, references(:diagnostics_sources, type: :text, on_delete: :restrict),
        primary_key: true

      add :producer_epoch, :text, primary_key: true
      add :sealed_at, :utc_datetime_usec, null: false
    end

    create table(:diagnostics_events) do
      add :source_id, references(:diagnostics_sources, type: :text, on_delete: :restrict),
        null: false

      add :event_id, :text, null: false
      add :producer_epoch, :text, null: false
      add :event_type, :text, null: false
      add :occurred_at, :utc_datetime_usec, null: false
      add :received_at, :utc_datetime_usec, null: false
      add :run_id, :text
      add :attempt_id, :text
      add :trace_id, :text
      add :git_sha, :text
      add :release, :text
      add :error_class, :text
      add :body, :map, null: false
    end

    create unique_index(:diagnostics_events, [:source_id, :event_id])
    create index(:diagnostics_events, [:source_id, :producer_epoch])
    create index(:diagnostics_events, [:source_id, :run_id, :attempt_id])
    create index(:diagnostics_events, [:received_at])
    create index(:diagnostics_events, [:occurred_at])
    create index(:diagnostics_events, [:trace_id], where: "trace_id IS NOT NULL")
    create index(:diagnostics_events, [:release, :error_class])
    create index(:diagnostics_events, [:git_sha], where: "git_sha IS NOT NULL")

    create table(:diagnostics_outbox, primary_key: false) do
      add :event_key, references(:diagnostics_events, on_delete: :restrict), primary_key: true
      add :available_at, :utc_datetime_usec, null: false
      add :attempts, :integer, null: false, default: 0
    end

    create index(:diagnostics_outbox, [:available_at, :event_key])
  end
end

defmodule Backplane.Repo.Migrations.CreateMemoryDistillations do
  use Ecto.Migration

  def change do
    create table(:memory_distillations, primary_key: false) do
      add :subject_id, :text, primary_key: true
      add :host_id, :text
      add :session_id, :text
      add :agent_id, :text
      add :integration, :text
      add :status, :text, null: false, default: "pending"
      add :mode, :text, null: false, default: "distill"
      add :attempts, :integer, null: false, default: 0
      add :due_at, :utc_datetime_usec
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec
      add :last_error, :text
      add :records_written, :integer, null: false, default: 0
      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:memory_distillations, :memory_distillations_status_check,
             check: "status IN ('pending','running','completed','failed','blocked')"
           )

    create constraint(:memory_distillations, :memory_distillations_mode_check,
             check: "mode IN ('distill','review')"
           )

    create index(:memory_distillations, [:status, :due_at])
  end
end

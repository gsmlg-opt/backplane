defmodule Backplane.Repo.Migrations.CreateAdminAuditEvents do
  use Ecto.Migration

  def change do
    create table(:admin_audit_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :actor, :text, null: false
      add :source, :text, null: false
      add :action, :text, null: false
      add :target_type, :text, null: false
      add :target_id, :text
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:admin_audit_events, [:inserted_at, :id])
    create index(:admin_audit_events, [:action, :inserted_at])
    create index(:admin_audit_events, [:target_type, :target_id, :inserted_at])
  end
end

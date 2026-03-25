defmodule Backplane.Repo.Migrations.CreateReindexState do
  use Ecto.Migration

  def change do
    create table(:reindex_state, primary_key: false) do
      add :project_id, references(:projects, type: :text, on_delete: :delete_all),
        primary_key: true

      add :commit_sha, :text
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :chunk_count, :integer
      add :status, :text, null: false, default: "pending"
    end
  end
end

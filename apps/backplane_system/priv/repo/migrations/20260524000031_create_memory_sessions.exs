defmodule Backplane.Repo.Migrations.CreateMemorySessions do
  use Ecto.Migration

  def change do
    create table(:memory_sessions, primary_key: false) do
      add(:session_id, :text, primary_key: true)
      add(:project, :text)
      add(:started_at, :utc_datetime_usec, null: false, default: fragment("now()"))
      add(:ended_at, :utc_datetime_usec)
      add(:consolidated_at, :utc_datetime_usec)
      add(:observation_count, :integer, null: false, default: 0)
    end

    create(index(:memory_sessions, [:project]))
    create(index(:memory_sessions, [:ended_at]))
  end
end

defmodule Backplane.Repo.Migrations.CreateMemorySummaries do
  use Ecto.Migration

  def change do
    create table(:memory_summaries, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:session_id, :text, null: false)
      add(:project, :text, default: "")
      add(:content, :text, null: false)
      add(:observation_count, :integer, default: 0)
      add(:created_at, :utc_datetime_usec, null: false)
    end

    create(index(:memory_summaries, [:session_id]))
    create(index(:memory_summaries, [:project]))
  end
end

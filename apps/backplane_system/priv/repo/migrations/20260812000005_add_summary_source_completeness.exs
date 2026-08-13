defmodule Backplane.Repo.Migrations.AddSummarySourceCompleteness do
  use Ecto.Migration

  def up do
    alter table(:memory_summaries) do
      add(:source_complete, :boolean, null: false, default: true)
      add(:source_gap_count, :integer, null: false, default: 0)
      add(:source_gaps, :map, null: false, default: %{"ranges" => []})
    end

    create(
      constraint(:memory_summaries, :memory_summaries_source_gap_count_check,
        check: "source_gap_count >= 0"
      )
    )
  end

  def down do
    drop(constraint(:memory_summaries, :memory_summaries_source_gap_count_check))

    alter table(:memory_summaries) do
      remove(:source_gaps)
      remove(:source_gap_count)
      remove(:source_complete)
    end
  end
end

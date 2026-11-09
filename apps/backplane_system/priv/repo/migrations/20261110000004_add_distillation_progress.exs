defmodule Backplane.Repo.Migrations.AddDistillationProgress do
  use Ecto.Migration

  # `heartbeat_at` is refreshed at claim and after every chunk; stale-running
  # recovery keys on it. `distilled_through_sequence` is the per-session watermark:
  # a run only processes observations with a higher `source_sequence`.
  def change do
    alter table(:memory_distillations) do
      add :heartbeat_at, :utc_datetime_usec
      add :distilled_through_sequence, :bigint, null: false, default: 0
    end
  end
end

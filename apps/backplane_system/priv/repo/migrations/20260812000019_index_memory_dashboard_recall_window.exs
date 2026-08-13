defmodule Backplane.Repo.Migrations.IndexMemoryDashboardRecallWindow do
  use Ecto.Migration

  def change do
    create(
      index(:memory_recall_runs, [:inserted_at], name: :memory_recall_runs_dashboard_window_idx)
    )
  end
end

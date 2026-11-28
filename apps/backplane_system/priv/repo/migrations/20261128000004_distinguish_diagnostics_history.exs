defmodule Backplane.Repo.Migrations.DistinguishDiagnosticsHistory do
  use Ecto.Migration

  def change do
    alter table(:diagnostics_events) do
      add :historical, :boolean, null: false, default: false
    end
  end
end

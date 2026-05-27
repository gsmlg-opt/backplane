defmodule Backplane.Repo.Migrations.CreateMonitorPlans do
  use Ecto.Migration

  def change do
    create table(:monitor_plans, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :name, :text, null: false
      add :provider, :text, null: false
      add :credential_name, :text, null: false
      add :config, :map, default: %{}
      add :active, :boolean, default: true

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:monitor_plans, [:name])
  end
end

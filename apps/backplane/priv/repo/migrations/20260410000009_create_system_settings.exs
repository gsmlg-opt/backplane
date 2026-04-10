defmodule Backplane.Repo.Migrations.CreateSystemSettings do
  use Ecto.Migration

  def change do
    create table(:system_settings, primary_key: false) do
      add :key, :text, primary_key: true
      add :value, :map
      add :value_type, :text, null: false, default: "string"
      add :description, :text

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("now()")
    end
  end
end

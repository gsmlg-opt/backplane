defmodule Backplane.Repo.Migrations.CreateBpmObservations do
  use Ecto.Migration

  def change do
    create table(:bpm_observations, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:session_id, :text, null: false)
      add(:tool_name, :text)
      add(:content, :text, null: false)
      add(:is_error, :boolean, null: false, default: false)
      add(:files, :map, default: %{})
      add(:created_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create(index(:bpm_observations, [:session_id]))
    create(index(:bpm_observations, [:created_at]))
  end
end

defmodule Backplane.Repo.Migrations.CreateSkillLoadLog do
  use Ecto.Migration

  def change do
    create table(:skill_load_log) do
      add :skill_name, :text, null: false
      add :client_id, references(:clients, type: :binary_id, on_delete: :nilify_all)
      add :client_name, :text
      add :loaded_deps, {:array, :text}, default: []

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("now()")
    end

    create index(:skill_load_log, [:skill_name])
    create index(:skill_load_log, [:inserted_at])
  end
end

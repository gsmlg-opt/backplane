defmodule Backplane.Repo.Migrations.AddAlwaysReturnToSkills do
  use Ecto.Migration

  def change do
    alter table(:skills) do
      add :always_return, :boolean, null: false, default: false
    end
  end
end

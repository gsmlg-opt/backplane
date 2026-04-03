defmodule Backplane.Repo.Migrations.CreateProjects do
  use Ecto.Migration

  def change do
    create table(:projects, primary_key: false) do
      add :id, :text, primary_key: true
      add :repo, :text, null: false
      add :ref, :text, null: false, default: "main"
      add :description, :text
      add :last_indexed_at, :utc_datetime_usec
      add :index_hash, :text

      timestamps(type: :utc_datetime_usec)
    end
  end
end

defmodule Backplane.Repo.Migrations.CreateAuthRbac do
  use Ecto.Migration

  def change do
    create table(:auth_roles, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :name, :text, null: false
      add :label, :text
      add :description, :text
      add :system, :boolean, default: false, null: false
      add :metadata, :map, default: %{}, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:auth_roles, [:name])
    create index(:auth_roles, [:system])

    create table(:auth_role_scopes, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :role_id, references(:auth_roles, type: :binary_id, on_delete: :delete_all), null: false
      add :scope_name, :text, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:auth_role_scopes, [:role_id, :scope_name])
    create index(:auth_role_scopes, [:scope_name])

    create table(:auth_user_roles, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :user_id, references(:auth_users, type: :binary_id, on_delete: :delete_all), null: false
      add :role_id, references(:auth_roles, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:auth_user_roles, [:user_id, :role_id])
    create index(:auth_user_roles, [:role_id])
  end
end

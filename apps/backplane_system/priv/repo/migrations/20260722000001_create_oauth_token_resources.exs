defmodule Backplane.Repo.Migrations.CreateOauthTokenResources do
  use Ecto.Migration

  def change do
    create table(:oauth_token_resources, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")

      add :oauth_token_id,
          references(:oauth_tokens, type: :uuid, on_delete: :delete_all),
          null: false

      add :resource, :text, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:oauth_token_resources, [:oauth_token_id])

    create constraint(:oauth_token_resources, :oauth_token_resources_resource_check,
             check: "resource IN ('mcp', 'v1')"
           )
  end
end

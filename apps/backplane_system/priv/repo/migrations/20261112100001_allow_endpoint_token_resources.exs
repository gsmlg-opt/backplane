defmodule Backplane.Repo.Migrations.AllowEndpointTokenResources do
  use Ecto.Migration

  def up do
    drop(constraint(:oauth_token_resources, :oauth_token_resources_resource_check))

    create constraint(:oauth_token_resources, :oauth_token_resources_resource_check,
             check:
               "resource IN ('mcp','skill_protocol','v1') OR resource ~ '^endpoint:[a-z0-9][a-z0-9-]{0,62}:(mcp|v1)$'"
           )
  end

  def down do
    execute("DELETE FROM oauth_token_resources WHERE resource LIKE 'endpoint:%'")
    drop(constraint(:oauth_token_resources, :oauth_token_resources_resource_check))

    create constraint(:oauth_token_resources, :oauth_token_resources_resource_check,
             check: "resource IN ('mcp', 'skill_protocol', 'v1')"
           )
  end
end

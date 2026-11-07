defmodule Backplane.Repo.Migrations.AddOpenaiApiUsage do
  use Ecto.Migration

  def up do
    alter table(:monitor_api_accounts) do
      add :organization_id, :text
    end

    drop constraint(:monitor_api_accounts, :monitor_api_accounts_provider)

    create constraint(:monitor_api_accounts, :monitor_api_accounts_provider,
             check:
               "provider IN ('openrouter', 'deepseek', 'exa', 'tavily', 'firecrawl', 'openai')"
           )

    create constraint(:monitor_api_accounts, :monitor_api_accounts_openai_organization,
             check:
               "provider <> 'openai' OR (organization_id IS NOT NULL AND " <>
                 "organization_id ~ '^[A-Za-z0-9_-]+$' AND length(organization_id) <= 255)"
           )
  end

  def down do
    drop constraint(:monitor_api_accounts, :monitor_api_accounts_openai_organization)
    drop constraint(:monitor_api_accounts, :monitor_api_accounts_provider)

    create constraint(:monitor_api_accounts, :monitor_api_accounts_provider,
             check: "provider IN ('openrouter', 'deepseek', 'exa', 'tavily', 'firecrawl')"
           )

    alter table(:monitor_api_accounts) do
      remove :organization_id
    end
  end
end

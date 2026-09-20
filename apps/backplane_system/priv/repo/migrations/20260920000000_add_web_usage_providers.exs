defmodule Backplane.Repo.Migrations.AddWebUsageProviders do
  use Ecto.Migration

  def up do
    drop constraint(:monitor_api_accounts, :monitor_api_accounts_provider)
    drop constraint(:monitor_api_accounts, :monitor_api_accounts_management_provider)

    create constraint(:monitor_api_accounts, :monitor_api_accounts_provider,
             check: "provider IN ('openrouter', 'deepseek', 'exa', 'tavily', 'firecrawl')"
           )

    create constraint(:monitor_api_accounts, :monitor_api_accounts_management_provider,
             check: "management_credential_name IS NULL OR provider = 'openrouter'"
           )
  end

  def down do
    drop constraint(:monitor_api_accounts, :monitor_api_accounts_provider)
    drop constraint(:monitor_api_accounts, :monitor_api_accounts_management_provider)

    create constraint(:monitor_api_accounts, :monitor_api_accounts_provider,
             check: "provider IN ('openrouter', 'deepseek')"
           )

    create constraint(:monitor_api_accounts, :monitor_api_accounts_management_provider,
             check: "management_credential_name IS NULL OR provider = 'openrouter'"
           )
  end
end

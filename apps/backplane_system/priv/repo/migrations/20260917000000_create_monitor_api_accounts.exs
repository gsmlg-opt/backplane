defmodule Backplane.Repo.Migrations.CreateMonitorApiAccounts do
  use Ecto.Migration

  def change do
    create table(:monitor_api_accounts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :text, null: false
      add :provider, :text, null: false
      add :credential_name, :text, null: false
      add :management_credential_name, :text
      add :active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:monitor_api_accounts, [:name])

    create constraint(:monitor_api_accounts, :monitor_api_accounts_provider,
             check: "provider IN ('openrouter', 'deepseek')"
           )

    create constraint(:monitor_api_accounts, :monitor_api_accounts_management_provider,
             check: "management_credential_name IS NULL OR provider = 'openrouter'"
           )
  end
end

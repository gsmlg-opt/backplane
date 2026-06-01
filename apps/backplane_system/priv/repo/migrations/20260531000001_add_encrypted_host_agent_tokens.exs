defmodule Backplane.Repo.Migrations.AddEncryptedHostAgentTokens do
  use Ecto.Migration

  def up do
    alter table(:skill_host_auth_tokens) do
      add :encrypted_token, :binary
    end

    execute("DELETE FROM skill_host_agent_tokens")
    execute("DELETE FROM skill_host_auth_tokens WHERE encrypted_token IS NULL")

    alter table(:skill_host_auth_tokens) do
      modify :encrypted_token, :binary, null: false
    end
  end

  def down do
    alter table(:skill_host_auth_tokens) do
      remove :encrypted_token
    end
  end
end

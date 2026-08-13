defmodule Backplane.Repo.Migrations.AddEncryptedHostAgentTokens do
  use Ecto.Migration

  def up do
    alter table(:skill_host_auth_tokens) do
      add :encrypted_token, :binary
    end

    execute("DELETE FROM #{qualified("skill_host_agent_tokens")}")
    execute("DELETE FROM #{qualified("skill_host_auth_tokens")} WHERE encrypted_token IS NULL")

    alter table(:skill_host_auth_tokens) do
      modify :encrypted_token, :binary, null: false
    end
  end

  def down do
    alter table(:skill_host_auth_tokens) do
      remove :encrypted_token
    end
  end

  defp qualified(name) do
    [prefix(), name]
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join(".", fn identifier ->
      ~s("#{identifier |> to_string() |> String.replace("\"", "\"\"")}")
    end)
  end
end

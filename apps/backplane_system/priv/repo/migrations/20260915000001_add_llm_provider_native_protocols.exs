defmodule Backplane.Repo.Migrations.AddLlmProviderNativeProtocols do
  use Ecto.Migration

  def up do
    if provider_tables_exist?() do
      alter table(:llm_provider_apis) do
        add(:native_protocols, {:array, :string}, null: false, default: [])
      end

      execute("""
      UPDATE #{qualified("llm_provider_apis")} AS api
      SET native_protocols = CASE
        WHEN api.api_surface = 'anthropic' THEN ARRAY['anthropic_messages']
        WHEN provider.preset_key = 'openai-codex' THEN ARRAY['openai_responses']
        WHEN provider.preset_key = 'openai' THEN ARRAY['openai_chat_completions', 'openai_responses']
        WHEN provider.preset_key = 'custom' OR provider.preset_key IS NULL
          THEN ARRAY['openai_chat_completions', 'openai_responses']
        ELSE ARRAY['openai_chat_completions']
      END
      FROM #{qualified("llm_providers")} AS provider
      WHERE provider.id = api.provider_id
      """)
    end
  end

  def down do
    if provider_tables_exist?() do
      alter table(:llm_provider_apis) do
        remove(:native_protocols)
      end
    end
  end

  defp provider_tables_exist? do
    Enum.all?(["llm_provider_apis", "llm_providers"], fn table_name ->
      [[exists?]] =
        repo().query!("SELECT to_regclass($1) IS NOT NULL", [qualified(table_name)]).rows

      exists?
    end)
  end

  defp qualified(name) do
    [prefix(), name]
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join(".", &quote_identifier/1)
  end

  defp quote_identifier(identifier) do
    ~s("#{String.replace(identifier, "\"", "\"\"")}")
  end
end

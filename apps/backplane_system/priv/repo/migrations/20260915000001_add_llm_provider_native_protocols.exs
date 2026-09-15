defmodule Backplane.Repo.Migrations.AddLlmProviderNativeProtocols do
  use Ecto.Migration

  def up do
    alter table(:llm_provider_apis) do
      add(:native_protocols, {:array, :string}, null: false, default: [])
    end

    execute("""
    UPDATE llm_provider_apis AS api
    SET native_protocols = CASE
      WHEN api.api_surface = 'anthropic' THEN ARRAY['anthropic_messages']
      WHEN provider.preset_key = 'openai-codex' THEN ARRAY['openai_responses']
      WHEN provider.preset_key = 'openai' THEN ARRAY['openai_chat_completions', 'openai_responses']
      WHEN provider.preset_key = 'custom' OR provider.preset_key IS NULL
        THEN ARRAY['openai_chat_completions', 'openai_responses']
      ELSE ARRAY['openai_chat_completions']
    END
    FROM llm_providers AS provider
    WHERE provider.id = api.provider_id
    """)
  end

  def down do
    alter table(:llm_provider_apis) do
      remove(:native_protocols)
    end
  end
end

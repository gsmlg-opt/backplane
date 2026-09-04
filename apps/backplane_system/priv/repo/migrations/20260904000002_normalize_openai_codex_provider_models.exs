defmodule Backplane.Repo.Migrations.NormalizeOpenaiCodexProviderModels do
  @moduledoc "Idempotent data migration for existing OpenAI Codex providers and stale models."

  use Ecto.Migration

  @base_url "https://chatgpt.com/backend-api/codex"

  def up do
    provider_apis = qualified("llm_provider_apis")
    providers = qualified("llm_providers")
    provider_models = qualified("llm_provider_models")

    execute("""
    UPDATE #{provider_apis} AS api
    SET base_url = '#{@base_url}'
    FROM #{providers} AS provider
    WHERE provider.id = api.provider_id
      AND provider.preset_key = 'openai-codex'
      AND api.api_surface = 'openai'
      AND api.base_url IN ('', 'https://api.openai.com/v1')
    """)

    execute("""
    UPDATE #{provider_models} AS model
    SET metadata = model.metadata || '{"backplane_discovery_stale": true}'::jsonb
    FROM #{providers} AS provider
    WHERE provider.id = model.provider_id
      AND provider.preset_key = 'openai-codex'
      AND model.source = 'discovered'
      AND model.model IN (
        'gpt-5.5',
        'gpt-5.4',
        'gpt-5.4-mini',
        'gpt-5.3-codex',
        'gpt-5.3-codex-spark'
      )
      AND model.metadata->>'slug' IS DISTINCT FROM model.model
    """)
  end

  def down, do: :ok

  defp qualified(name) do
    [prefix(), name]
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join(".", &quote_identifier/1)
  end

  defp quote_identifier(identifier) do
    ~s("#{String.replace(identifier, "\"", "\"\"")}")
  end
end

defmodule Backplane.Repo.Migrations.BackfillOpenaiCodexDiscoveryStaleMarkers do
  @moduledoc "Repairs stale Codex model metadata after the initial data migration."

  use Ecto.Migration

  def up do
    provider_models = qualified("llm_provider_models")
    providers = qualified("llm_providers")

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

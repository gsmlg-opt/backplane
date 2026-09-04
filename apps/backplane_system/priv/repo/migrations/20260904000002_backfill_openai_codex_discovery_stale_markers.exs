defmodule Backplane.Repo.Migrations.BackfillOpenaiCodexDiscoveryStaleMarkers do
  @moduledoc "Repairs stale Codex model metadata after the initial data migration."

  use Ecto.Migration

  def up do
    execute("""
    UPDATE llm_provider_models AS model
    SET metadata = model.metadata || '{"backplane_discovery_stale": true}'::jsonb
    FROM llm_providers AS provider
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
end

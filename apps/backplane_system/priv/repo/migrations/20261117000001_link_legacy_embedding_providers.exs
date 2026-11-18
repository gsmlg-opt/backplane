defmodule Backplane.Repo.Migrations.LinkLegacyEmbeddingProviders do
  use Ecto.Migration

  def up do
    alter table(:embedding_providers) do
      add :llm_provider_id, references(:llm_providers, type: :binary_id, on_delete: :restrict)
    end

    create index(:embedding_providers, [:llm_provider_id])

    execute """
    DO $migration$
    DECLARE
      legacy record;
      target_id uuid;
      target_name text;
      allowed_models varchar[];
    BEGIN
      FOR legacy IN
        SELECT embedding.*
        FROM #{qualified("embedding_providers")} AS embedding
        JOIN #{qualified("credentials")} AS credential ON credential.name = embedding.credential
        WHERE embedding.deleted_at IS NULL AND embedding.host_service_id IS NULL
          AND credential.kind IN ('llm', 'service')
          AND COALESCE(credential.metadata->>'auth_type', 'api_key') = 'api_key'
        ORDER BY embedding.id
      LOOP
        target_id := NULL;

        SELECT provider.id INTO target_id
        FROM #{qualified("llm_providers")} AS provider
        JOIN #{qualified("llm_provider_apis")} AS api ON api.provider_id = provider.id
        WHERE provider.name = legacy.name AND provider.credential = legacy.credential
          AND provider.host_service_id IS NULL AND provider.deleted_at IS NULL
          AND provider.enabled = legacy.enabled AND api.enabled
          AND api.api_surface = 'openai'
          AND RTRIM(api.base_url, '/') = RTRIM(legacy.base_url, '/')
          AND (provider.default_headers || api.default_headers) = legacy.default_headers
          AND NOT EXISTS (
            SELECT 1 FROM #{qualified("llm_openai_services")} AS service
            WHERE service.provider_id = provider.id AND service.kind = 'embeddings'
          );

        IF target_id IS NULL THEN
          target_id := gen_random_uuid();
          target_name := legacy.name;

          IF EXISTS (
            SELECT 1 FROM #{qualified("llm_providers")}
            WHERE name = target_name AND deleted_at IS NULL
          ) THEN
            target_name := legacy.name || '-embedding-' || REPLACE(target_id::text, '-', '');
          END IF;

          INSERT INTO #{qualified("llm_providers")}
            (id, name, preset_key, credential, default_headers, enabled, inserted_at, updated_at)
          VALUES
            (target_id, target_name, 'custom', legacy.credential, legacy.default_headers,
             legacy.enabled, now(), now());

          INSERT INTO #{qualified("llm_provider_apis")}
            (id, provider_id, api_surface, base_url, native_protocols, enabled,
             model_discovery_enabled, inserted_at, updated_at)
          VALUES
            (gen_random_uuid(), target_id, 'openai', RTRIM(legacy.base_url, '/'),
             ARRAY[]::varchar[], true, false, now(), now());
        END IF;

        SELECT COALESCE(array_agg(model ORDER BY model), ARRAY[]::varchar[])
        INTO allowed_models
        FROM #{qualified("embedding_models")}
        WHERE provider_id = legacy.id AND enabled;

        INSERT INTO #{qualified("llm_openai_services")}
          (id, provider_id, kind, enabled, models, model_policy, inserted_at, updated_at)
        VALUES
          (gen_random_uuid(), target_id, 'embeddings',
           legacy.enabled AND cardinality(allowed_models) > 0, allowed_models,
           CASE WHEN cardinality(allowed_models) > 0 THEN 'allowlist' ELSE 'passthrough' END,
           now(), now());

        UPDATE #{qualified("embedding_providers")}
        SET llm_provider_id = target_id WHERE id = legacy.id;
      END LOOP;
    END
    $migration$;
    """
  end

  def down do
    drop index(:embedding_providers, [:llm_provider_id])

    alter table(:embedding_providers) do
      remove :llm_provider_id
    end
  end

  defp qualified(name) do
    [prefix(), name]
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join(".", fn identifier ->
      ~s("#{String.replace(to_string(identifier), "\"", "\"\"")}")
    end)
  end
end

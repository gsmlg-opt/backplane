defmodule Backplane.Repo.Migrations.UnifyProviderCapabilities do
  use Ecto.Migration

  def up do
    alter table(:llm_openai_services) do
      add :model_policy, :string, null: false, default: "passthrough"
      add :image_generation_enabled, :boolean, null: false, default: true
      add :image_edit_enabled, :boolean, null: false, default: true
    end

    execute "UPDATE #{qualified("llm_openai_services")} SET model_policy = 'allowlist' WHERE cardinality(models) > 0"

    execute """
    UPDATE #{qualified("llm_openai_services")} AS service
    SET models = ARRAY['gpt-6-luna']::varchar[],
        default_model = 'gpt-6-luna', model_policy = 'allowlist'
    FROM #{qualified("llm_providers")} AS provider
    WHERE service.provider_id = provider.id AND provider.preset_key = 'openai'
      AND service.kind = 'decisions' AND cardinality(service.models) = 0
      AND service.default_model IS NULL
    """

    drop constraint(:llm_openai_services, :llm_openai_services_kind_check)

    create constraint(:llm_openai_services, :llm_openai_services_kind_check,
             check:
               "kind IN ('decisions', 'images', 'embeddings', 'speech', 'transcription', 'realtime')"
           )

    create constraint(:llm_openai_services, :llm_openai_services_model_policy_check,
             check:
               "model_policy IN ('passthrough', 'allowlist') AND (model_policy <> 'allowlist' OR cardinality(models) > 0)"
           )
  end

  def down do
    execute """
    DO $migration$
    BEGIN
      IF EXISTS (SELECT 1 FROM #{qualified("llm_openai_services")} WHERE kind = 'embeddings') THEN
        RAISE EXCEPTION 'Remove native Embeddings configurations before rolling back provider capabilities';
      END IF;
    END
    $migration$;
    """

    drop constraint(:llm_openai_services, :llm_openai_services_model_policy_check)
    drop constraint(:llm_openai_services, :llm_openai_services_kind_check)

    create constraint(:llm_openai_services, :llm_openai_services_kind_check,
             check: "kind IN ('decisions', 'images', 'speech', 'transcription', 'realtime')"
           )

    alter table(:llm_openai_services) do
      remove :model_policy
      remove :image_generation_enabled
      remove :image_edit_enabled
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

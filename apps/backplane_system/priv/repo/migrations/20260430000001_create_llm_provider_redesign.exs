defmodule Backplane.Repo.Migrations.CreateLlmProviderRedesign do
  use Ecto.Migration

  def up do
    drop_legacy_llm_tables()

    create table(:llm_providers, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :preset_key, :text
      add :name, :text, null: false
      add :credential, :text, null: false
      add :default_headers, :map, null: false, default: %{}
      add :rpm_limit, :integer
      add :enabled, :boolean, null: false, default: true
      add :deleted_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:llm_providers, [:name],
             where: "deleted_at IS NULL",
             name: :llm_providers_name_index
           )

    create index(:llm_providers, [:enabled])
    create index(:llm_providers, [:preset_key])

    create table(:llm_provider_apis, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :provider_id, references(:llm_providers, type: :binary_id, on_delete: :delete_all),
        null: false

      add :api_surface, :text, null: false
      add :base_url, :text, null: false
      add :enabled, :boolean, null: false, default: true
      add :default_headers, :map, null: false, default: %{}
      add :model_discovery_enabled, :boolean, null: false, default: true
      add :model_discovery_path, :text
      add :last_discovered_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:llm_provider_apis, [:provider_id, :api_surface])
    create index(:llm_provider_apis, [:api_surface, :enabled])

    create constraint(:llm_provider_apis, :llm_provider_apis_api_surface_check,
             check: "api_surface IN ('openai', 'anthropic')"
           )

    create table(:llm_provider_models, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :provider_id, references(:llm_providers, type: :binary_id, on_delete: :delete_all),
        null: false

      add :model, :text, null: false
      add :display_name, :text
      add :source, :text, null: false, default: "manual"
      add :enabled, :boolean, null: false, default: true
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:llm_provider_models, [:provider_id, :model])
    create index(:llm_provider_models, [:enabled])

    create constraint(:llm_provider_models, :llm_provider_models_source_check,
             check: "source IN ('discovered', 'manual')"
           )

    create table(:llm_provider_model_surfaces, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :provider_model_id,
          references(:llm_provider_models, type: :binary_id, on_delete: :delete_all),
          null: false

      add :provider_api_id,
          references(:llm_provider_apis, type: :binary_id, on_delete: :delete_all),
          null: false

      add :enabled, :boolean, null: false, default: true
      add :last_seen_at, :utc_datetime_usec
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:llm_provider_model_surfaces, [
             :provider_model_id,
             :provider_api_id
           ])

    create index(:llm_provider_model_surfaces, [:provider_api_id, :enabled])

    create table(:llm_auto_models, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :name, :text, null: false
      add :description, :text
      add :enabled, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:llm_auto_models, [:name])

    create table(:llm_auto_model_routes, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :auto_model_id, references(:llm_auto_models, type: :binary_id, on_delete: :delete_all),
        null: false

      add :api_surface, :text, null: false
      add :strategy, :text, null: false, default: "first_available"
      add :enabled, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:llm_auto_model_routes, [:auto_model_id, :api_surface])

    create constraint(:llm_auto_model_routes, :llm_auto_model_routes_api_surface_check,
             check: "api_surface IN ('openai', 'anthropic')"
           )

    create constraint(:llm_auto_model_routes, :llm_auto_model_routes_strategy_check,
             check: "strategy IN ('first_available')"
           )

    create table(:llm_auto_model_targets, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :auto_model_route_id,
          references(:llm_auto_model_routes, type: :binary_id, on_delete: :delete_all),
          null: false

      add :provider_model_surface_id,
          references(:llm_provider_model_surfaces, type: :binary_id, on_delete: :delete_all),
          null: false

      add :priority, :integer, null: false, default: 0
      add :enabled, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:llm_auto_model_targets, [
             :auto_model_route_id,
             :provider_model_surface_id
           ])

    create index(:llm_auto_model_targets, [:auto_model_route_id, :priority])

    create table(:llm_logs, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :request_id, :text
      add :client_id, :binary_id
      add :client_ip, :text
      add :api_surface, :text

      add :provider_id, references(:llm_providers, type: :binary_id, on_delete: :nilify_all)

      add :provider_name, :text

      add :provider_api_id,
          references(:llm_provider_apis, type: :binary_id, on_delete: :nilify_all)

      add :provider_model_id,
          references(:llm_provider_models, type: :binary_id, on_delete: :nilify_all)

      add :provider_model_surface_id,
          references(:llm_provider_model_surfaces, type: :binary_id, on_delete: :nilify_all)

      add :requested_model, :text
      add :resolved_model, :text
      add :status, :integer
      add :error_reason, :text
      add :stream, :boolean, null: false, default: false
      add :duration_ms, :integer
      add :request_bytes, :integer
      add :response_bytes, :integer
      add :input_tokens, :integer
      add :output_tokens, :integer
      add :total_tokens, :integer
      add :raw_request, :text
      add :raw_response, :text
      add :raw_request_truncated, :boolean, null: false, default: false
      add :raw_response_truncated, :boolean, null: false, default: false
      add :metadata, :map, null: false, default: %{}

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("now()")
    end

    create index(:llm_logs, [:inserted_at])
    create index(:llm_logs, [:provider_id, :inserted_at])
    create index(:llm_logs, [:requested_model, :inserted_at])
    create index(:llm_logs, [:resolved_model, :inserted_at])
    create index(:llm_logs, [:api_surface, :inserted_at])
    create index(:llm_logs, [:status, :inserted_at])

    seed_auto_models()
  end

  def down do
    drop_if_exists table(:llm_logs)
    drop_if_exists table(:llm_auto_model_targets)
    drop_if_exists table(:llm_auto_model_routes)
    drop_if_exists table(:llm_auto_models)
    drop_if_exists table(:llm_provider_model_surfaces)
    drop_if_exists table(:llm_provider_models)
    drop_if_exists table(:llm_provider_apis)
    drop_if_exists table(:llm_providers)
  end

  defp seed_auto_models do
    execute("""
    WITH inserted_auto_models AS (
      INSERT INTO llm_auto_models (id, name, description, enabled, inserted_at, updated_at)
      VALUES
        (gen_random_uuid(), 'fast', 'Low-latency default model', true, now(), now()),
        (gen_random_uuid(), 'smart', 'Balanced reasoning default model', true, now(), now()),
        (gen_random_uuid(), 'expert', 'Highest-capability default model', true, now(), now())
      ON CONFLICT (name) DO NOTHING
      RETURNING id, name
    ),
    all_auto_models AS (
      SELECT id, name FROM inserted_auto_models
      UNION
      SELECT id, name FROM llm_auto_models WHERE name IN ('fast', 'smart', 'expert')
    )
    INSERT INTO llm_auto_model_routes (
      id,
      auto_model_id,
      api_surface,
      strategy,
      enabled,
      inserted_at,
      updated_at
    )
    SELECT
      gen_random_uuid(),
      all_auto_models.id,
      surfaces.api_surface,
      'first_available',
      true,
      now(),
      now()
    FROM all_auto_models
    CROSS JOIN (VALUES ('openai'), ('anthropic')) AS surfaces(api_surface)
    ON CONFLICT (auto_model_id, api_surface) DO NOTHING
    """)
  end

  defp drop_legacy_llm_tables do
    # This redesign intentionally replaces the old provider/alias/usage model.
    # Existing LLM rows are discarded so upgraded databases match the new schema
    # instead of keeping incompatible columns such as `api_type` and `api_url`.
    drop_if_exists table(:llm_logs)
    drop_if_exists table(:llm_auto_model_targets)
    drop_if_exists table(:llm_auto_model_routes)
    drop_if_exists table(:llm_auto_models)
    drop_if_exists table(:llm_provider_model_surfaces)
    drop_if_exists table(:llm_provider_models)
    drop_if_exists table(:llm_provider_apis)
    drop_if_exists table(:llm_usage_logs)
    drop_if_exists table(:llm_model_aliases)
    drop_if_exists table(:llm_providers)
  end
end

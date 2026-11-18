defmodule Backplane.LLM.ProviderCapabilityMigrationsTest do
  use BackplaneLlama.DataCase, async: false

  alias Backplane.Repo.Migrations.{LinkLegacyEmbeddingProviders, UnifyProviderCapabilities}

  setup do
    for file <- [
          "20261117000000_unify_provider_capabilities.exs",
          "20261117000001_link_legacy_embedding_providers.exs",
          "20261119000000_add_provider_base_url.exs"
        ] do
      Code.require_file(Application.app_dir(:backplane_system, "priv/repo/migrations/#{file}"))
    end

    prefix = "provider_capabilities_#{System.unique_integer([:positive])}"
    Repo.query!(~s|CREATE SCHEMA "#{prefix}"|)

    for table <-
          ~w(llm_providers llm_provider_apis llm_openai_services embedding_providers embedding_models) do
      Repo.query!(~s|CREATE TABLE "#{prefix}"."#{table}" (LIKE "#{table}" INCLUDING ALL)|)
    end

    Repo.query!(~s|ALTER TABLE "#{prefix}".embedding_providers DROP COLUMN llm_provider_id|)

    Repo.query!("""
    ALTER TABLE "#{prefix}".llm_openai_services
      DROP COLUMN model_policy, DROP COLUMN image_generation_enabled, DROP COLUMN image_edit_enabled
    """)

    Repo.query!(~s|CREATE TABLE "#{prefix}".credentials (name text, kind text, metadata jsonb)|)
    %{prefix: prefix}
  end

  test "capability migration preserves restrictions and state and repairs empty Decisions", %{
    prefix: prefix
  } do
    platform = provider(prefix, "platform", "key", "openai")
    custom = provider(prefix, "custom", "key", "custom")

    Repo.query!(
      """
      INSERT INTO "#{prefix}".llm_openai_services
        (id, provider_id, kind, enabled, models, default_model, request_timeout_ms, inserted_at, updated_at)
      VALUES
        (gen_random_uuid(), $1, 'decisions', false, '{}', NULL, 45000, now(), now()),
        (gen_random_uuid(), $1, 'images', false, ARRAY['custom-image'], 'custom-image', 33000, now(), now()),
        (gen_random_uuid(), $2, 'decisions', true, '{}', NULL, 22000, now(), now())
      """,
      [platform, custom]
    )

    migrate(prefix, UnifyProviderCapabilities, 20_261_117_000_000)

    assert [
             ["custom", "decisions", true, [], nil, "passthrough", 22_000],
             ["platform", "decisions", false, ["gpt-6-luna"], "gpt-6-luna", "allowlist", 45_000],
             ["platform", "images", false, ["custom-image"], "custom-image", "allowlist", 33_000]
           ] =
             Repo.query!("""
             SELECT provider.name, service.kind, service.enabled, service.models,
                    service.default_model, service.model_policy, service.request_timeout_ms
             FROM "#{prefix}".llm_openai_services service
             JOIN "#{prefix}".llm_providers provider ON provider.id = service.provider_id
             ORDER BY provider.name, service.kind
             """).rows
  end

  test "legacy embedding migration preserves aliases, disabled models and separate connections",
       %{
         prefix: prefix
       } do
    migrate(prefix, UnifyProviderCapabilities, 20_261_117_000_000)

    Repo.query!("""
    INSERT INTO "#{prefix}".credentials (name, kind, metadata)
    VALUES ('key', 'llm', '{}'), ('oauth', 'llm', '{"auth_type":"openai_oauth"}')
    """)

    existing = provider(prefix, "collision", "other-key", "custom")
    matched = provider(prefix, "matched", "key", "custom")
    api(prefix, matched, "https://embeddings.example/v1")

    collision = legacy(prefix, "collision", "key", true)
    reuse = legacy(prefix, "matched", "key", true)
    disabled = legacy(prefix, "disabled", "key", false)
    empty = legacy(prefix, "empty", "key", true)
    oauth = legacy(prefix, "oauth", "oauth", true)

    for id <- [collision, reuse, disabled] do
      Repo.query!(
        """
        INSERT INTO "#{prefix}".embedding_models
          (id, provider_id, model, enabled, inserted_at, updated_at)
        VALUES (gen_random_uuid(), $1, 'allowed', true, now(), now()),
               (gen_random_uuid(), $1, 'disabled-model', false, now(), now())
        """,
        [id]
      )
    end

    migrate(prefix, LinkLegacyEmbeddingProviders, 20_261_117_000_001)

    assert [[^matched]] =
             Repo.query!(
               ~s|SELECT llm_provider_id FROM "#{prefix}".embedding_providers WHERE id = $1|,
               [reuse]
             ).rows

    [[collision_target]] =
      Repo.query!(~s|SELECT llm_provider_id FROM "#{prefix}".embedding_providers WHERE id = $1|, [
        collision
      ]).rows

    assert collision_target != existing

    assert [["https://embeddings.example/v1", [], "key"]] =
             Repo.query!(
               """
               SELECT api.base_url, api.native_protocols, provider.credential
               FROM "#{prefix}".llm_providers provider
               JOIN "#{prefix}".llm_provider_apis api ON api.provider_id = provider.id
               WHERE provider.id = $1
               """,
               [collision_target]
             ).rows

    assert [
             ["collision", true, ["allowed"], "allowlist"],
             ["disabled", false, ["allowed"], "allowlist"],
             ["empty", false, [], "passthrough"],
             ["matched", true, ["allowed"], "allowlist"]
           ] =
             Repo.query!("""
             SELECT legacy.name, service.enabled, service.models, service.model_policy
             FROM "#{prefix}".embedding_providers legacy
             JOIN "#{prefix}".llm_openai_services service
               ON service.provider_id = legacy.llm_provider_id AND service.kind = 'embeddings'
             ORDER BY legacy.name
             """).rows

    assert [[nil]] =
             Repo.query!(
               ~s|SELECT llm_provider_id FROM "#{prefix}".embedding_providers WHERE id = $1|,
               [oauth]
             ).rows

    assert [[true]] =
             Repo.query!(~s|SELECT enabled FROM "#{prefix}".embedding_providers WHERE id = $1|, [
               empty
             ]).rows
  end

  test "provider URL migration preserves protocol URLs, headers and disabled policy", %{
    prefix: prefix
  } do
    Repo.query!(~s|ALTER TABLE "#{prefix}".llm_providers DROP COLUMN base_url|)
    id = provider(prefix, "single-base", "key", "minimax")
    api(prefix, id, "https://example.test/v1")

    Repo.query!(
      """
      INSERT INTO "#{prefix}".llm_provider_apis
        (id, provider_id, api_surface, base_url, default_headers, enabled, native_protocols, inserted_at, updated_at)
      VALUES (gen_random_uuid(), $1, 'anthropic', 'https://other.example/anthropic',
        '{"x-existing":"keep"}', false, ARRAY['anthropic_messages'], now(), now())
      """,
      [id]
    )

    before =
      Repo.query!(
        ~s|SELECT api_surface, base_url, default_headers, enabled, native_protocols FROM "#{prefix}".llm_provider_apis ORDER BY api_surface|
      ).rows

    migrate(prefix, Backplane.Repo.Migrations.AddProviderBaseUrl, 20_261_119_000_000)

    assert [["https://example.test/v1"]] =
             Repo.query!(~s|SELECT base_url FROM "#{prefix}".llm_providers|).rows

    assert Repo.query!(
             ~s|SELECT api_surface, base_url, default_headers, enabled, native_protocols FROM "#{prefix}".llm_provider_apis ORDER BY api_surface|
           ).rows == before
  end

  defp provider(prefix, name, credential, preset) do
    [[id]] =
      Repo.query!(
        """
        INSERT INTO "#{prefix}".llm_providers
          (id, name, credential, preset_key, inserted_at, updated_at)
        VALUES (gen_random_uuid(), $1, $2, $3, now(), now()) RETURNING id
        """,
        [name, credential, preset]
      ).rows

    id
  end

  defp api(prefix, provider_id, url) do
    Repo.query!(
      """
      INSERT INTO "#{prefix}".llm_provider_apis
        (id, provider_id, api_surface, base_url, native_protocols, inserted_at, updated_at)
      VALUES (gen_random_uuid(), $1, 'openai', $2, ARRAY['openai_chat_completions'], now(), now())
      """,
      [provider_id, url]
    )
  end

  defp legacy(prefix, name, credential, enabled) do
    [[id]] =
      Repo.query!(
        """
        INSERT INTO "#{prefix}".embedding_providers
          (id, name, credential, base_url, enabled, inserted_at, updated_at)
        VALUES (gen_random_uuid(), $1, $2, 'https://embeddings.example/v1', $3, now(), now())
        RETURNING id
        """,
        [name, credential, enabled]
      ).rows

    id
  end

  defp migrate(prefix, module, version) do
    Ecto.Migration.Runner.run(Repo, Repo.config(), version, module, :forward, :up, :up,
      prefix: prefix,
      log: false
    )
  end
end

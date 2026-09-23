defmodule Backplane.Repo.Migrations.ExpandLlmGoogleApiSurfaceTestRepo do
  use Ecto.Repo, otp_app: :backplane_system, adapter: Ecto.Adapters.Postgres
end

defmodule Backplane.Repo.Migrations.ExpandLlmGoogleApiSurfaceTest do
  use BackplaneSystem.DataCase, async: false

  alias Backplane.Repo.Migrations.ExpandLlmGoogleApiSurface, as: Migration

  @migration_path Path.expand(
                    "../../../../priv/repo/migrations/20260923000000_expand_llm_google_api_surface.exs",
                    __DIR__
                  )
  @migration_version 20_260_923_000_000

  setup do
    Code.require_file(@migration_path)
    %{migration_repo: start_migration_repo()}
  end

  test "up preserves existing rows, admits Google, and seeds Google auto routes", %{
    migration_repo: repo
  } do
    with_isolated_schema(repo, fn prefix ->
      create_prerequisites(repo, prefix)
      provider_id = insert_provider(repo, prefix, "existing")
      insert_provider_api(repo, prefix, provider_id, "openai")

      assert :ok = migrate_up(repo, prefix)
      insert_provider_api(repo, prefix, provider_id, "google")

      assert [[["google", "openai"]]] =
               repo.query!(
                 ~s|SELECT array_agg(api_surface ORDER BY api_surface) FROM "#{prefix}".llm_provider_apis|
               ).rows

      assert [[3]] =
               repo.query!(
                 ~s|SELECT count(*) FROM "#{prefix}".llm_auto_model_routes WHERE api_surface = 'google'|
               ).rows
    end)
  end

  test "down removes seeded Google routes and restores the old SQL constraints", %{
    migration_repo: repo
  } do
    with_isolated_schema(repo, fn prefix ->
      create_prerequisites(repo, prefix)
      provider_id = insert_provider(repo, prefix, "existing")

      assert :ok = migrate_up(repo, prefix)
      assert :ok = migrate_down(repo, prefix)

      assert [[0]] =
               repo.query!(
                 ~s|SELECT count(*) FROM "#{prefix}".llm_auto_model_routes WHERE api_surface = 'google'|
               ).rows

      assert_raise Postgrex.Error, ~r/llm_provider_apis_api_surface_check/, fn ->
        insert_provider_api(repo, prefix, provider_id, "google")
      end
    end)
  end

  test "down refuses to discard configured Google provider APIs", %{migration_repo: repo} do
    with_isolated_schema(repo, fn prefix ->
      create_prerequisites(repo, prefix)
      provider_id = insert_provider(repo, prefix, "configured")

      assert :ok = migrate_up(repo, prefix)
      insert_provider_api(repo, prefix, provider_id, "google")

      assert_raise Ecto.MigrationError, ~r/remove Google provider APIs before rollback/, fn ->
        migrate_down(repo, prefix)
      end

      assert [[1]] =
               repo.query!(
                 ~s|SELECT count(*) FROM "#{prefix}".llm_provider_apis WHERE api_surface = 'google'|
               ).rows
    end)
  end

  defp with_isolated_schema(repo, fun) do
    prefix = "llm_google_surface_#{System.unique_integer([:positive])}"
    repo.query!(~s|CREATE SCHEMA "#{prefix}"|)

    try do
      fun.(prefix)
    after
      repo.query!(~s|DROP SCHEMA IF EXISTS "#{prefix}" CASCADE|)
    end
  end

  defp create_prerequisites(repo, prefix) do
    repo.query!("""
    CREATE TABLE "#{prefix}".llm_providers (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      name text NOT NULL
    )
    """)

    repo.query!("""
    CREATE TABLE "#{prefix}".llm_provider_apis (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      provider_id uuid NOT NULL REFERENCES "#{prefix}".llm_providers(id),
      api_surface text NOT NULL,
      base_url text NOT NULL,
      native_protocols text[] NOT NULL DEFAULT '{}',
      inserted_at timestamp(6) with time zone NOT NULL,
      updated_at timestamp(6) with time zone NOT NULL,
      CONSTRAINT llm_provider_apis_api_surface_check
        CHECK (api_surface IN ('openai', 'anthropic'))
    )
    """)

    repo.query!("""
    CREATE TABLE "#{prefix}".llm_auto_models (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      name text NOT NULL UNIQUE
    )
    """)

    repo.query!("""
    CREATE TABLE "#{prefix}".llm_auto_model_routes (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      auto_model_id uuid NOT NULL REFERENCES "#{prefix}".llm_auto_models(id),
      api_surface text NOT NULL,
      strategy text NOT NULL DEFAULT 'first_available',
      enabled boolean NOT NULL DEFAULT true,
      inserted_at timestamp(6) with time zone NOT NULL,
      updated_at timestamp(6) with time zone NOT NULL,
      UNIQUE (auto_model_id, api_surface),
      CONSTRAINT llm_auto_model_routes_api_surface_check
        CHECK (api_surface IN ('openai', 'anthropic'))
    )
    """)

    repo.query!(
      ~s|INSERT INTO "#{prefix}".llm_auto_models (name) VALUES ('fast'), ('smart'), ('expert')|
    )
  end

  defp insert_provider(repo, prefix, name) do
    [[id]] =
      repo.query!(
        ~s|INSERT INTO "#{prefix}".llm_providers (name) VALUES ($1) RETURNING id|,
        [name]
      ).rows

    id
  end

  defp insert_provider_api(repo, prefix, provider_id, api_surface) do
    native_protocol =
      if api_surface == "google", do: "google_generate_content", else: "openai_chat_completions"

    repo.query!(
      """
      INSERT INTO "#{prefix}".llm_provider_apis
        (provider_id, api_surface, base_url, native_protocols, inserted_at, updated_at)
      VALUES ($1, $2, 'https://example.test', ARRAY[$3], now(), now())
      """,
      [provider_id, api_surface, native_protocol]
    )
  end

  defp migrate_up(repo, prefix) do
    Ecto.Migrator.up(repo, @migration_version, Migration, prefix: prefix, log: false)
  end

  defp migrate_down(repo, prefix) do
    Ecto.Migrator.down(repo, @migration_version, Migration, prefix: prefix, log: false)
  end

  defp start_migration_repo do
    config =
      Backplane.Repo.config()
      |> Keyword.delete(:pool)
      |> Keyword.put(:pool_size, 2)

    start_supervised!({Backplane.Repo.Migrations.ExpandLlmGoogleApiSurfaceTestRepo, config})
    Backplane.Repo.Migrations.ExpandLlmGoogleApiSurfaceTestRepo
  end
end

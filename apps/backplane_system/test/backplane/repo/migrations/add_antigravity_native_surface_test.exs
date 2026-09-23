defmodule Backplane.Repo.Migrations.AddAntigravityNativeSurfaceTestRepo do
  use Ecto.Repo, otp_app: :backplane_system, adapter: Ecto.Adapters.Postgres
end

defmodule Backplane.Repo.Migrations.AddAntigravityNativeSurfaceTest do
  use BackplaneSystem.DataCase, async: false

  alias Backplane.Repo.Migrations.AddAntigravityNativeSurface, as: Migration

  @path Path.expand(
          "../../../../priv/repo/migrations/20260923000001_add_antigravity_native_surface.exs",
          __DIR__
        )
  @version 20_260_923_000_001

  setup do
    Code.require_file(@path)
    %{migration_repo: start_migration_repo()}
  end

  test "up preserves old rows and adds bounded Antigravity storage", %{migration_repo: repo} do
    with_schema(repo, fn prefix ->
      create_tables(repo, prefix)
      provider_id = insert_provider(repo, prefix)
      insert_api(repo, prefix, provider_id, "openai")

      assert :ok = migrate(repo, prefix, :up)
      insert_api(repo, prefix, provider_id, "antigravity", %{"project_id" => "managed"})

      assert [["antigravity"]] =
               repo.query!(~s|SELECT api_surface FROM "#{prefix}".llm_auto_model_routes|).rows

      assert [[%{"project_id" => "managed"}, "antigravity"], [%{}, "openai"]] =
               repo.query!(
                 ~s|SELECT backend_config, api_surface FROM "#{prefix}".llm_provider_apis ORDER BY api_surface|
               ).rows
    end)
  end

  test "down refuses configured Antigravity rows and succeeds after removal", %{
    migration_repo: repo
  } do
    with_schema(repo, fn prefix ->
      create_tables(repo, prefix)
      provider_id = insert_provider(repo, prefix)
      assert :ok = migrate(repo, prefix, :up)
      insert_api(repo, prefix, provider_id, "antigravity", %{})

      assert_raise Ecto.MigrationError,
                   ~r/remove Antigravity provider APIs before rollback/,
                   fn ->
                     migrate(repo, prefix, :down)
                   end

      repo.query!(~s|DELETE FROM "#{prefix}".llm_provider_apis WHERE api_surface = 'antigravity'|)
      assert :ok = migrate(repo, prefix, :down)

      assert_raise Postgrex.Error, ~r/llm_provider_apis_api_surface_check/, fn ->
        insert_api(repo, prefix, provider_id, "antigravity")
      end
    end)
  end

  defp create_tables(repo, prefix) do
    repo.query!(
      ~s|CREATE TABLE "#{prefix}".llm_providers (id uuid PRIMARY KEY DEFAULT gen_random_uuid())|
    )

    repo.query!(
      ~s|CREATE TABLE "#{prefix}".llm_auto_models (id uuid PRIMARY KEY DEFAULT gen_random_uuid())|
    )

    repo.query!(~s|INSERT INTO "#{prefix}".llm_auto_models DEFAULT VALUES|)

    repo.query!("""
    CREATE TABLE "#{prefix}".llm_auto_model_routes (
      id uuid PRIMARY KEY,
      auto_model_id uuid REFERENCES "#{prefix}".llm_auto_models(id),
      api_surface text NOT NULL,
      strategy text NOT NULL,
      enabled boolean NOT NULL,
      inserted_at timestamp NOT NULL,
      updated_at timestamp NOT NULL,
      UNIQUE (auto_model_id, api_surface),
      CONSTRAINT llm_auto_model_routes_api_surface_check CHECK (api_surface IN ('openai', 'anthropic', 'google'))
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
        CHECK (api_surface IN ('openai', 'anthropic', 'google'))
    )
    """)
  end

  defp insert_provider(repo, prefix) do
    [[id]] =
      repo.query!(~s|INSERT INTO "#{prefix}".llm_providers DEFAULT VALUES RETURNING id|).rows

    id
  end

  defp insert_api(repo, prefix, provider_id, surface, config \\ nil) do
    columns = if is_nil(config), do: "", else: ", backend_config"
    values = if is_nil(config), do: "", else: ", $3"
    params = if is_nil(config), do: [provider_id, surface], else: [provider_id, surface, config]

    repo.query!(
      """
      INSERT INTO "#{prefix}".llm_provider_apis
        (provider_id, api_surface, base_url, inserted_at, updated_at#{columns})
      VALUES ($1, $2, 'https://example.test', now(), now()#{values})
      """,
      params
    )
  end

  defp with_schema(repo, fun) do
    prefix = "antigravity_surface_#{System.unique_integer([:positive])}"
    repo.query!(~s|CREATE SCHEMA "#{prefix}"|)

    try do
      fun.(prefix)
    after
      repo.query!(~s|DROP SCHEMA IF EXISTS "#{prefix}" CASCADE|)
    end
  end

  defp migrate(repo, prefix, :up),
    do: Ecto.Migrator.up(repo, @version, Migration, prefix: prefix, log: false)

  defp migrate(repo, prefix, :down),
    do: Ecto.Migrator.down(repo, @version, Migration, prefix: prefix, log: false)

  defp start_migration_repo do
    config = Backplane.Repo.config() |> Keyword.delete(:pool) |> Keyword.put(:pool_size, 2)

    start_supervised!({Backplane.Repo.Migrations.AddAntigravityNativeSurfaceTestRepo, config})
    Backplane.Repo.Migrations.AddAntigravityNativeSurfaceTestRepo
  end
end

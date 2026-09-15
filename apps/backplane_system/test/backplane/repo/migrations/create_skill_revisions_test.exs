defmodule Backplane.Repo.Migrations.CreateSkillRevisionsTestRepo do
  use Ecto.Repo, otp_app: :backplane_system, adapter: Ecto.Adapters.Postgres
end

defmodule Backplane.Repo.Migrations.CreateSkillRevisionsTest do
  use BackplaneSystem.DataCase, async: false

  alias Backplane.Repo.Migrations.CreateSkillRevisions

  @migration_path Path.expand(
                    "../../../../priv/repo/migrations/20260911000001_create_skill_revisions.exs",
                    __DIR__
                  )
  @migration_version 20_260_911_000_001

  setup do
    Code.require_file(@migration_path)
    %{migration_repo: start_migration_repo()}
  end

  test "refuses rollback before mutating a schema with retained revisions", %{
    migration_repo: repo
  } do
    with_isolated_schema(repo, fn prefix ->
      assert :ok = migrate_up(repo, prefix)
      insert_retained_revision(repo, prefix)

      assert_raise Ecto.MigrationError,
                   ~r/refusing destructive rollback.*retained immutable publications/i,
                   fn -> migrate_down(repo, prefix) end

      assert table_exists?(repo, prefix, "skill_revisions")
      assert column_exists?(repo, prefix, "skills", "current_revision")
      assert constraint_exists?(repo, prefix, "skills", "skills_current_revision_fkey")
      assert trigger_exists?(repo, prefix, "skill_revisions", "skill_revisions_immutable")
      assert function_exists?(repo, prefix, "prevent_skill_revision_update")
      assert retained_revision_count(repo, prefix) == 1
      assert current_revision(repo, prefix) == revision()
    end)
  end

  test "rolls an empty schema down and reapplies cleanly", %{
    migration_repo: repo
  } do
    with_isolated_schema(repo, fn prefix ->
      assert :ok = migrate_up(repo, prefix)
      assert :ok = migrate_down(repo, prefix)

      refute table_exists?(repo, prefix, "skill_revisions")
      refute column_exists?(repo, prefix, "skills", "current_revision")
      refute function_exists?(repo, prefix, "prevent_skill_revision_update")

      assert :ok = migrate_up(repo, prefix)
      assert table_exists?(repo, prefix, "skill_revisions")
      assert column_exists?(repo, prefix, "skills", "current_revision")
      assert function_exists?(repo, prefix, "prevent_skill_revision_update")
    end)
  end

  defp with_isolated_schema(repo, fun) do
    prefix = "skill_revisions_#{System.unique_integer([:positive])}"
    repo.query!(~s|CREATE SCHEMA "#{prefix}"|)

    try do
      create_prerequisites(repo, prefix)
      fun.(prefix)
    after
      repo.query!(~s|DROP SCHEMA IF EXISTS "#{prefix}" CASCADE|)
    end
  end

  defp create_prerequisites(repo, prefix) do
    repo.query!("""
    CREATE TABLE "#{prefix}".oauth_token_resources (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      resource text NOT NULL,
      CONSTRAINT oauth_token_resources_resource_check CHECK (resource IN ('mcp', 'v1'))
    )
    """)

    repo.query!("""
    CREATE TABLE "#{prefix}".skills (
      id text PRIMARY KEY,
      name text NOT NULL,
      content text NOT NULL,
      inserted_at timestamp(6) with time zone NOT NULL,
      updated_at timestamp(6) with time zone NOT NULL
    )
    """)
  end

  defp insert_retained_revision(repo, prefix) do
    repo.query!("""
    INSERT INTO "#{prefix}".skills (id, name, content, inserted_at, updated_at)
    VALUES ('generated/test', 'Test', '# Test', now(), now())
    """)

    repo.query!(
      """
      INSERT INTO "#{prefix}".skill_revisions
        (skill_id, revision, artifact_digest, manifest, blob_ref, published_at, inserted_at)
      VALUES ($1, $2, $3, '{}'::jsonb, $4, now(), now())
      """,
      ["generated/test", revision(), artifact_digest(), blob_ref()]
    )

    repo.query!(
      ~s|UPDATE "#{prefix}".skills SET current_revision = $1 WHERE id = 'generated/test'|,
      [revision()]
    )
  end

  defp migrate_up(repo, prefix) do
    Ecto.Migrator.up(repo, @migration_version, CreateSkillRevisions,
      prefix: prefix,
      log: false
    )
  end

  defp migrate_down(repo, prefix) do
    Ecto.Migrator.down(repo, @migration_version, CreateSkillRevisions,
      prefix: prefix,
      log: false
    )
  end

  defp start_migration_repo do
    config =
      Backplane.Repo.config()
      |> Keyword.delete(:pool)
      |> Keyword.put(:pool_size, 2)

    start_supervised!({Backplane.Repo.Migrations.CreateSkillRevisionsTestRepo, config})
    Backplane.Repo.Migrations.CreateSkillRevisionsTestRepo
  end

  defp table_exists?(repo, prefix, table) do
    repo.query!("SELECT to_regclass($1) IS NOT NULL", ["#{prefix}.#{table}"]).rows == [[true]]
  end

  defp column_exists?(repo, prefix, table, column) do
    repo.query!(
      """
      SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = $1 AND table_name = $2 AND column_name = $3
      )
      """,
      [prefix, table, column]
    ).rows == [[true]]
  end

  defp constraint_exists?(repo, prefix, table, constraint) do
    repo.query!(
      """
      SELECT EXISTS (
        SELECT 1 FROM information_schema.table_constraints
        WHERE table_schema = $1 AND table_name = $2 AND constraint_name = $3
      )
      """,
      [prefix, table, constraint]
    ).rows == [[true]]
  end

  defp trigger_exists?(repo, prefix, table, trigger) do
    repo.query!(
      """
      SELECT EXISTS (
        SELECT 1
        FROM information_schema.triggers
        WHERE trigger_schema = $1 AND event_object_table = $2 AND trigger_name = $3
      )
      """,
      [prefix, table, trigger]
    ).rows == [[true]]
  end

  defp function_exists?(repo, prefix, function) do
    repo.query!("SELECT to_regprocedure($1) IS NOT NULL", ["#{prefix}.#{function}()"]).rows ==
      [[true]]
  end

  defp retained_revision_count(repo, prefix) do
    [[count]] = repo.query!(~s|SELECT count(*) FROM "#{prefix}".skill_revisions|).rows
    count
  end

  defp current_revision(repo, prefix) do
    [[current_revision]] =
      repo.query!(~s|SELECT current_revision FROM "#{prefix}".skills|).rows

    current_revision
  end

  defp revision, do: "r-" <> String.duplicate("a", 64)
  defp artifact_digest, do: "sha256:" <> String.duplicate("a", 64)
  defp blob_ref, do: "sha256/" <> String.duplicate("a", 64) <> ".tar.gz"
end

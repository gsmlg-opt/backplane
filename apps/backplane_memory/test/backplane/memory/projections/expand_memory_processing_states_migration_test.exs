defmodule Backplane.Memory.ExpandProcessingStatesMigrationTestRepo do
  use Ecto.Repo,
    otp_app: :backplane_system,
    adapter: Ecto.Adapters.Postgres
end

defmodule Backplane.Memory.Projections.ExpandMemoryProcessingStatesMigrationTest do
  use Backplane.Memory.DataCase, async: false

  @migration_version 20_260_905_000_009
  @migration_module Backplane.Repo.Migrations.ExpandMemoryProcessingStates

  test "classifies historical skips and preserves the precise contract across down and up" do
    prefix = "processing_states_#{System.unique_integer([:positive])}"
    migration_repo = start_migration_repo()

    with_isolated_schema(migration_repo, prefix, fn ->
      create_fixture(migration_repo, prefix)
      load_migration()

      assert :ok = migrate(migration_repo, prefix, :up)

      assert [
               [1, "skipped_no_model", "no_model"],
               [2, "skipped_disabled", "feature_disabled"],
               [3, "failed", "historical_custom_reason"]
             ] == states(migration_repo, prefix)

      assert_constraint_rejects(migration_repo, prefix, 4, "skipped", "no_llm")

      assert :ok = migrate(migration_repo, prefix, :down)

      assert [
               [1, "skipped", "no_model"],
               [2, "skipped", "feature_disabled"],
               [3, "failed", "historical_custom_reason"]
             ] == states(migration_repo, prefix)

      insert_state!(migration_repo, prefix, 4, "skipped", "model_not_configured")
      assert_constraint_rejects(migration_repo, prefix, 5, "skipped_no_model", "no_model")

      assert :ok = migrate(migration_repo, prefix, :up)

      assert [
               [1, "skipped_no_model", "no_model"],
               [2, "skipped_disabled", "feature_disabled"],
               [3, "failed", "historical_custom_reason"],
               [4, "skipped_no_model", "model_not_configured"]
             ] == states(migration_repo, prefix)

      assert_constraint_rejects(migration_repo, prefix, 5, "skipped", "disabled")
    end)
  end

  defp create_fixture(repo, prefix) do
    repo.query!("""
    CREATE TABLE "#{prefix}".bpm_projection_states (
      id bigint PRIMARY KEY,
      status text NOT NULL,
      last_error text
    )
    """)

    repo.query!("""
    ALTER TABLE "#{prefix}".bpm_projection_states
    ADD CONSTRAINT bpm_projection_states_status_check
    CHECK (status IN ('pending', 'enqueued', 'running', 'complete', 'skipped', 'failed', 'dead_letter'))
    """)

    insert_state!(repo, prefix, 1, "skipped", "no_model")
    insert_state!(repo, prefix, 2, "skipped", "feature_disabled")
    insert_state!(repo, prefix, 3, "skipped", "historical_custom_reason")
  end

  defp states(repo, prefix) do
    repo.query!("""
    SELECT id, status, last_error
    FROM "#{prefix}".bpm_projection_states
    ORDER BY id
    """).rows
  end

  defp insert_state!(repo, prefix, id, status, last_error) do
    repo.query!(
      """
      INSERT INTO "#{prefix}".bpm_projection_states (id, status, last_error)
      VALUES ($1, $2, $3)
      """,
      [id, status, last_error]
    )
  end

  defp assert_constraint_rejects(repo, prefix, id, status, last_error) do
    assert_raise Postgrex.Error, ~r/bpm_projection_states_status_check/, fn ->
      insert_state!(repo, prefix, id, status, last_error)
    end
  end

  defp migrate(repo, prefix, :up) do
    Ecto.Migrator.up(repo, @migration_version, @migration_module, prefix: prefix, log: false)
  end

  defp migrate(repo, prefix, :down) do
    Ecto.Migrator.down(repo, @migration_version, @migration_module,
      prefix: prefix,
      log: false
    )
  end

  defp load_migration do
    :backplane_system
    |> Application.app_dir(
      "priv/repo/migrations/20260905000009_expand_memory_processing_states.exs"
    )
    |> Code.require_file()
  end

  defp start_migration_repo do
    config = repo().config() |> Keyword.delete(:pool) |> Keyword.put(:pool_size, 2)

    start_supervised!({Backplane.Memory.ExpandProcessingStatesMigrationTestRepo, config})

    Backplane.Memory.ExpandProcessingStatesMigrationTestRepo
  end

  defp with_isolated_schema(repo, prefix, fun) do
    repo.query!(~s|CREATE SCHEMA "#{prefix}"|)

    try do
      fun.()
    after
      repo.query!(~s|DROP SCHEMA IF EXISTS "#{prefix}" CASCADE|)
    end
  end
end

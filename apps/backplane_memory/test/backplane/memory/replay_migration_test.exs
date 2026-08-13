defmodule Backplane.Memory.ReplayMigrationTestRepo do
  use Ecto.Repo, otp_app: :backplane_system, adapter: Ecto.Adapters.Postgres
end

defmodule Backplane.Memory.ReplayMigrationTest do
  use Backplane.Memory.DataCase, async: false

  @version 20_260_812_000_018
  @migration Backplane.Repo.Migrations.CreateMemoryReplayEvents

  test "replay migrations are prefix-safe, immutable, expandable, and reversible" do
    prefix = "replay_migration_#{System.unique_integer([:positive])}"
    migration_repo = start_migration_repo()
    migration_repo.query!(~s|CREATE SCHEMA "#{prefix}"|)

    try do
      migration_repo.query!(~s|CREATE TABLE "#{prefix}".bpm_events (id uuid PRIMARY KEY)|)
      load_migration()

      assert :ok =
               Ecto.Migrator.up(migration_repo, @version, @migration,
                 prefix: prefix,
                 log: false
               )

      event_id = Ecto.UUID.generate()

      migration_repo.query!(~s|INSERT INTO "#{prefix}".bpm_events (id) VALUES ($1)|, [
        Ecto.UUID.dump!(event_id)
      ])

      insert_replay!(migration_repo, prefix, event_id)
      insert_replay!(migration_repo, prefix, event_id, 2, "session_boundary")

      assert [[2]] =
               migration_repo.query!(
                 ~s|SELECT count(*) FROM "#{prefix}".memory_replay_events WHERE event_id = $1|,
                 [Ecto.UUID.dump!(event_id)]
               ).rows

      assert immutable_error(fn ->
               migration_repo.query!(
                 ~s|UPDATE "#{prefix}".memory_replay_events SET detail = '{}'|
               )
             end)

      assert immutable_error(fn ->
               migration_repo.query!(~s|DELETE FROM "#{prefix}".memory_replay_events|)
             end)

      assert :ok =
               Ecto.Migrator.down(migration_repo, @version, @migration,
                 prefix: prefix,
                 log: false
               )

      assert [[nil]] =
               migration_repo.query!("SELECT to_regclass($1)", ["#{prefix}.memory_replay_events"]).rows
    after
      migration_repo.query!(~s|DROP SCHEMA IF EXISTS "#{prefix}" CASCADE|)
    end
  end

  defp insert_replay!(repo, prefix, event_id, position \\ 1, kind \\ "prompt") do
    repo.query!(
      ~s|INSERT INTO "#{prefix}".memory_replay_events
      (subject_id, input_revision, position, event_id, host_id, client_id, scope,
       namespace, session_id, kind, event_type, occurred_at, detail,
       processing_version, inserted_at, updated_at)
      VALUES ('subject', 'revision', $2, $1, 'host', 'client', 'scope', 'private',
              'session', $3, 'agent.run.failed', now(), '{}',
              'replay-v1', now(), now())|,
      [Ecto.UUID.dump!(event_id), position, kind]
    )
  end

  defp immutable_error(fun) do
    error = assert_raise Postgrex.Error, fun
    assert error.postgres.constraint == "memory_replay_immutable"
  end

  defp load_migration do
    :backplane_system
    |> Application.app_dir("priv/repo/migrations/20260812000018_create_memory_replay_events.exs")
    |> Code.require_file()
  end

  defp start_migration_repo do
    config = repo().config() |> Keyword.delete(:pool) |> Keyword.put(:pool_size, 2)
    start_supervised!({Backplane.Memory.ReplayMigrationTestRepo, config})
    Backplane.Memory.ReplayMigrationTestRepo
  end
end

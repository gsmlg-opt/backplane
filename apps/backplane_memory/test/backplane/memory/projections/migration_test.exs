defmodule Backplane.Memory.Projections.MigrationTestRepo do
  use Ecto.Repo,
    otp_app: :backplane_system,
    adapter: Ecto.Adapters.Postgres
end

defmodule Backplane.Memory.Projections.MigrationTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.Events.{Event, Store}
  alias Backplane.Memory.Ingest
  import Backplane.Memory.IngestFixtures

  @processing_version_migration 20_260_811_000_002
  @processing_version_module Backplane.Repo.Migrations.AddProcessingVersionToProjectionStates
  @observation_rows_migration 20_260_812_000_001
  @observation_rows_module Backplane.Repo.Migrations.CreateProjectedMemoryObservations

  test "projected-observation migration honors prefixes, creates indexes, and rolls back" do
    prefix = "projected_observations_#{System.unique_integer([:positive])}"
    migration_repo = start_migration_repo()

    with_isolated_schema(migration_repo, prefix, fn ->
      load_observation_rows_migration()

      assert :ok =
               Ecto.Migrator.up(
                 migration_repo,
                 @observation_rows_migration,
                 @observation_rows_module,
                 prefix: prefix,
                 log: false
               )

      assert [["bpm_projected_observations"]] =
               migration_repo.query!(
                 "SELECT table_name FROM information_schema.tables WHERE table_schema = $1 AND table_name = 'bpm_projected_observations'",
                 [prefix]
               ).rows

      index_names =
        migration_repo.query!(
          "SELECT indexname FROM pg_indexes WHERE schemaname = $1 AND tablename = 'bpm_projected_observations' ORDER BY indexname",
          [prefix]
        ).rows
        |> Enum.map(&hd/1)

      assert "bpm_projected_observations_pkey" in index_names
      assert "bpm_projected_observations_subject_sequence_idx" in index_names
      assert "bpm_projected_observations_host_session_time_idx" in index_names
      assert "bpm_projected_observations_file_paths_gin" in index_names

      assert :ok =
               Ecto.Migrator.down(
                 migration_repo,
                 @observation_rows_migration,
                 @observation_rows_module,
                 prefix: prefix,
                 log: false
               )

      assert [] ==
               migration_repo.query!(
                 "SELECT table_name FROM information_schema.tables WHERE table_schema = $1 AND table_name = 'bpm_projected_observations'",
                 [prefix]
               ).rows
    end)
  end

  test "processing-version migration backfills legacy states, drops its default, and rolls back" do
    prefix = "projection_processing_version_#{System.unique_integer([:positive])}"
    migration_repo = start_migration_repo()

    with_isolated_schema(migration_repo, prefix, fn ->
      migration_repo.query!("""
      CREATE TABLE "#{prefix}".bpm_projection_states (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        projector text NOT NULL,
        subject_type text NOT NULL,
        subject_id text NOT NULL
      )
      """)

      migration_repo.query!("""
      INSERT INTO "#{prefix}".bpm_projection_states
        (projector, subject_type, subject_id)
      VALUES
        ('session', 'captured_session', 'legacy-a'),
        ('activity', 'captured_session', 'legacy-b')
      """)

      load_processing_version_migration()

      assert :ok =
               Ecto.Migrator.up(
                 migration_repo,
                 @processing_version_migration,
                 @processing_version_module,
                 prefix: prefix,
                 log: false
               )

      assert [["activity", "legacy-v0"], ["session", "legacy-v0"]] ==
               migration_repo.query!("""
               SELECT projector, processing_version
               FROM "#{prefix}".bpm_projection_states
               ORDER BY projector
               """).rows

      assert [["NO", nil]] ==
               migration_repo.query!(
                 """
                 SELECT is_nullable, column_default
                 FROM information_schema.columns
                 WHERE table_schema = $1
                   AND table_name = 'bpm_projection_states'
                   AND column_name = 'processing_version'
                 """,
                 [prefix]
               ).rows

      error =
        assert_raise Postgrex.Error, fn ->
          migration_repo.query!("""
          INSERT INTO "#{prefix}".bpm_projection_states
            (projector, subject_type, subject_id)
          VALUES ('observations', 'captured_session', 'new-without-version')
          """)
        end

      assert error.postgres.code == :not_null_violation
      assert error.postgres.column == "processing_version"

      assert :ok =
               Ecto.Migrator.down(
                 migration_repo,
                 @processing_version_migration,
                 @processing_version_module,
                 prefix: prefix,
                 log: false
               )

      assert [] ==
               migration_repo.query!(
                 """
                 SELECT column_name
                 FROM information_schema.columns
                 WHERE table_schema = $1
                   AND table_name = 'bpm_projection_states'
                   AND column_name = 'processing_version'
                 """,
                 [prefix]
               ).rows
    end)
  end

  test "projection tables expose unique subjects and constrained state" do
    indexes =
      repo().query!("""
      SELECT indexname
      FROM pg_indexes
      WHERE schemaname = current_schema()
        AND indexname IN (
          'bpm_projection_states_subject_uniq',
          'bpm_projection_snapshots_subject_uniq',
          'bpm_projection_states_status_updated_at_index'
        )
      ORDER BY indexname
      """).rows

    assert Enum.map(indexes, &hd/1) ==
             Enum.sort([
               "bpm_projection_snapshots_subject_uniq",
               "bpm_projection_states_status_updated_at_index",
               "bpm_projection_states_subject_uniq"
             ])

    constraints =
      repo().query!("""
      SELECT conname
      FROM pg_constraint
      WHERE connamespace = current_schema()::regnamespace
        AND conname IN (
          'bpm_projection_states_status_check',
          'bpm_projection_states_attempt_count_check'
        )
      ORDER BY conname
      """).rows

    assert Enum.map(constraints, &hd/1) == [
             "bpm_projection_states_attempt_count_check",
             "bpm_projection_states_status_check"
           ]

    assert [["NO", nil]] ==
             repo().query!("""
             SELECT is_nullable, column_default
             FROM information_schema.columns
             WHERE table_schema = current_schema()
               AND table_name = 'bpm_projection_states'
               AND column_name = 'processing_version'
             """).rows

    subject_id = "constraint-#{System.unique_integer([:positive])}"

    assert %{num_rows: 1} =
             repo().query!(
               """
               INSERT INTO bpm_projection_states
                 (projector, subject_type, subject_id, processing_version, status, attempt_count,
                  inserted_at, updated_at)
               VALUES ('session', 'captured_session', $1, 'session-v1', 'complete', 0, now(), now())
               """,
               [subject_id]
             )

    assert_sql_error(:unique_violation, fn ->
      repo().query!(
        """
        INSERT INTO bpm_projection_states
          (projector, subject_type, subject_id, processing_version, status, attempt_count,
           inserted_at, updated_at)
        VALUES ('session', 'captured_session', $1, 'session-v1', 'complete', 0, now(), now())
        """,
        [subject_id]
      )
    end)

    assert_sql_error(:check_violation, fn ->
      repo().query!("""
      INSERT INTO bpm_projection_states
        (projector, subject_type, subject_id, processing_version, status, attempt_count,
         inserted_at, updated_at)
      VALUES ('session', 'captured_session', 'invalid-status', 'session-v1', 'queued', 0, now(), now())
      """)
    end)

    assert %{num_rows: 1} =
             repo().query!(
               """
               INSERT INTO bpm_projection_snapshots
                 (projector, subject_type, subject_id, input_revision, output_revision,
                  read_model, inserted_at, updated_at)
               VALUES
                 ('session', 'captured_session', $1, 'input', 'output', '{}', now(), now())
               """,
               [subject_id]
             )

    assert_sql_error(:unique_violation, fn ->
      repo().query!(
        """
        INSERT INTO bpm_projection_snapshots
          (projector, subject_type, subject_id, input_revision, output_revision,
           read_model, inserted_at, updated_at)
        VALUES
          ('session', 'captured_session', $1, 'input-2', 'output-2', '{}', now(), now())
        """,
        [subject_id]
      )
    end)

    assert_sql_error(:check_violation, fn ->
      repo().query!("""
      INSERT INTO bpm_projection_states
        (projector, subject_type, subject_id, processing_version, status, attempt_count,
         inserted_at, updated_at)
      VALUES ('session', 'captured_session', 'invalid-attempt', 'session-v1', 'failed', -1, now(), now())
      """)
    end)
  end

  test "captured events reject updates and deletes without changing the raw event" do
    event = valid_event()

    assert {:ok, %{"results" => [%{"status" => "accepted", "server_event_id" => id}]}} =
             Ingest.ingest_batch(
               ingest_auth_context("host-1", %{
                 auth_token_id: "token-1",
                 partition: %{scope: event["scope"]}
               }),
               %{"batch_id" => "immutable", "host_id" => "host-1", "events" => [event]}
             )

    original = repo().get!(Event, id)

    assert [[mutation_trigger]] =
             repo().query!("""
             SELECT pg_get_triggerdef(oid)
             FROM pg_trigger
             WHERE tgrelid = 'bpm_events'::regclass
               AND tgname = 'bpm_events_captured_immutable'
               AND NOT tgisinternal
               AND tgenabled != 'D'
             """).rows

    assert mutation_trigger =~ "BEFORE DELETE OR UPDATE ON"
    assert mutation_trigger =~ "bpm_events"
    assert mutation_trigger =~ "bpm_reject_captured_event_mutation()"

    update_error =
      assert_raise Postgrex.Error, fn ->
        repo().transaction(fn ->
          repo().query!("UPDATE bpm_events SET content = 'changed' WHERE id::text = $1", [id])
        end)
      end

    assert {update_error.postgres.code, update_error.postgres.message} ==
             {:object_not_in_prerequisite_state, "captured memory events are immutable"}

    delete_error =
      assert_raise Postgrex.Error, fn ->
        repo().transaction(fn ->
          repo().query!("DELETE FROM bpm_events WHERE id::text = $1", [id])
        end)
      end

    assert {delete_error.postgres.code, delete_error.postgres.message} ==
             {:object_not_in_prerequisite_state, "captured memory events are immutable"}

    assert [[truncate_trigger]] =
             repo().query!("""
             SELECT pg_get_triggerdef(oid)
             FROM pg_trigger
             WHERE tgrelid = 'bpm_events'::regclass
               AND tgname = 'bpm_events_captured_truncate_immutable'
               AND NOT tgisinternal
               AND tgenabled != 'D'
             """).rows

    assert truncate_trigger =~ "BEFORE TRUNCATE ON"
    assert truncate_trigger =~ "bpm_events"
    assert truncate_trigger =~ "bpm_reject_captured_event_truncate()"

    truncate_error =
      assert_raise Postgrex.Error, fn ->
        repo().transaction(fn -> repo().query!("TRUNCATE bpm_events") end)
      end

    assert {truncate_error.postgres.code, truncate_error.postgres.message} in [
             {:object_not_in_prerequisite_state, "captured memory events are immutable"},
             {:feature_not_supported,
              ~s(cannot TRUNCATE "bpm_events" because it has pending trigger events)},
             {:feature_not_supported,
              "cannot truncate a table referenced in a foreign key constraint"}
           ]

    stored = repo().get!(Event, id)
    assert stored.content == original.content
    assert stored.raw_envelope == original.raw_envelope
    assert stored.payload_hash == original.payload_hash
  end

  test "legacy events remain mutable during the compatibility period" do
    stream_id = "legacy-#{System.unique_integer([:positive])}"

    assert {:ok, {:inserted, event}} =
             Store.append_tagged(%{
               stream_id: stream_id,
               session_id: stream_id,
               event_type: "legacy.observation",
               content: "before",
               occurred_at: ~U[2026-08-05 00:00:00.000000Z]
             })

    assert %{num_rows: 1} =
             repo().query!("UPDATE bpm_events SET content = 'after' WHERE id::text = $1", [
               event.id
             ])

    assert repo().get!(Event, event.id).content == "after"

    assert %{num_rows: 1} =
             repo().query!("DELETE FROM bpm_events WHERE id::text = $1", [event.id])

    refute repo().get(Event, event.id)
  end

  defp assert_sql_error(code, fun) do
    error =
      assert_raise Postgrex.Error, fn ->
        repo().transaction(fun)
      end

    assert error.postgres.code == code
  end

  defp load_processing_version_migration do
    :backplane_system
    |> Application.app_dir(
      "priv/repo/migrations/20260811000002_add_processing_version_to_projection_states.exs"
    )
    |> Code.require_file()
  end

  defp load_observation_rows_migration do
    :backplane_system
    |> Application.app_dir(
      "priv/repo/migrations/20260812000001_create_projected_memory_observations.exs"
    )
    |> Code.require_file()
  end

  defp start_migration_repo do
    config =
      repo().config()
      |> Keyword.delete(:pool)
      |> Keyword.put(:pool_size, 2)

    start_supervised!({Backplane.Memory.Projections.MigrationTestRepo, config})
    Backplane.Memory.Projections.MigrationTestRepo
  end

  defp with_isolated_schema(migration_repo, prefix, fun) do
    migration_repo.query!(~s(CREATE SCHEMA "#{prefix}"))

    try do
      fun.()
    after
      migration_repo.query!(~s(DROP SCHEMA IF EXISTS "#{prefix}" CASCADE))
    end
  end
end

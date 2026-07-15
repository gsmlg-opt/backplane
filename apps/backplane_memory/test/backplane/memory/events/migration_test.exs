defmodule Backplane.Memory.Events.MigrationTestRepo do
  use Ecto.Repo,
    otp_app: :backplane_system,
    adapter: Ecto.Adapters.Postgres
end

defmodule Backplane.Memory.Events.MigrationTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.Events.{Event, Stream}

  @migration_version 20_260_716_000_001
  @migration_module Backplane.Repo.Migrations.MakeMemoryEventIdempotencyKeyGlobal

  test "preflight reports cross-stream collisions before replacing the legacy index" do
    prefix = "event_migration_#{System.unique_integer([:positive])}"
    qualified_events = ~s("#{prefix}".bpm_events)
    migration_repo = start_migration_repo()

    with_isolated_schema(migration_repo, prefix, fn ->
      migration_repo.query!("""
      CREATE TABLE #{qualified_events} (
        stream_id text NOT NULL,
        idempotency_key text
      )
      """)

      migration_repo.query!("""
      CREATE UNIQUE INDEX bpm_events_idempotency_key_uniq
      ON #{qualified_events} (stream_id, idempotency_key)
      WHERE idempotency_key IS NOT NULL
      """)

      migration_repo.query!("""
      INSERT INTO #{qualified_events} (stream_id, idempotency_key)
      VALUES ('stream-a', 'shared-key'), ('stream-b', 'shared-key')
      """)

      load_migration()

      error =
        assert_raise Postgrex.Error, fn ->
          Ecto.Migrator.up(migration_repo, @migration_version, @migration_module,
            prefix: prefix,
            log: false
          )
        end

      assert error.postgres.code == :unique_violation
      assert error.postgres.message =~ "Cannot make bpm_events.idempotency_key globally unique"
      assert error.postgres.hint =~ "SELECT idempotency_key"
      assert error.postgres.hint =~ "HAVING count(DISTINCT stream_id) > 1"
      assert error.postgres.hint =~ "Resolve each collision by operator review"
      assert error.postgres.hint =~ "retry this migration"

      assert [[index_definition]] =
               migration_repo.query!(
                 """
                 SELECT indexdef
                 FROM pg_indexes
                 WHERE schemaname = $1
                   AND tablename = 'bpm_events'
                   AND indexname = 'bpm_events_idempotency_key_uniq'
                 """,
                 [prefix]
               ).rows

      assert index_definition =~ "USING btree (stream_id, idempotency_key)"
    end)
  end

  test "global index rejects the same non-null key in different streams" do
    suffix = System.unique_integer([:positive])
    first_stream_id = "global-key-stream-a-#{suffix}"
    second_stream_id = "global-key-stream-b-#{suffix}"
    idempotency_key = "global-key-#{suffix}"

    assert {:ok, _stream} =
             repo().insert(Stream.changeset(%Stream{}, %{stream_id: first_stream_id}))

    assert {:ok, _stream} =
             repo().insert(Stream.changeset(%Stream{}, %{stream_id: second_stream_id}))

    assert {:ok, _event} =
             first_stream_id
             |> event_changeset(idempotency_key)
             |> repo().insert()

    assert {:error, changeset} =
             second_stream_id
             |> event_changeset(idempotency_key)
             |> repo().insert()

    assert %{idempotency_key: ["has already been taken"]} = errors_on(changeset)

    assert 1 ==
             repo().aggregate(
               from(event in Event, where: event.idempotency_key == ^idempotency_key),
               :count
             )
  end

  test "idempotency keys are globally unique when present" do
    result =
      repo().query!("""
      SELECT indexdef
      FROM pg_indexes
      WHERE schemaname = current_schema()
        AND tablename = 'bpm_events'
        AND indexname = 'bpm_events_idempotency_key_uniq'
      """)

    assert [[index_definition]] = result.rows
    assert index_definition =~ "UNIQUE INDEX bpm_events_idempotency_key_uniq"
    assert index_definition =~ "USING btree (idempotency_key)"
    assert index_definition =~ "WHERE (idempotency_key IS NOT NULL)"
  end

  defp event_changeset(stream_id, idempotency_key) do
    Event.changeset(%Event{}, %{
      id: Ecto.UUID.generate(),
      stream_id: stream_id,
      sequence: 1,
      event_type: "session.started",
      idempotency_key: idempotency_key,
      occurred_at: DateTime.utc_now()
    })
  end

  defp load_migration do
    :backplane_system
    |> Application.app_dir(
      "priv/repo/migrations/20260716000001_make_memory_event_idempotency_key_global.exs"
    )
    |> Code.require_file()
  end

  defp start_migration_repo do
    config =
      repo().config()
      |> Keyword.delete(:pool)
      |> Keyword.put(:pool_size, 2)

    start_supervised!({Backplane.Memory.Events.MigrationTestRepo, config})
    Backplane.Memory.Events.MigrationTestRepo
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

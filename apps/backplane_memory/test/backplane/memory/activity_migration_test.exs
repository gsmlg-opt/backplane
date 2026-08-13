defmodule Backplane.Memory.ActivityMigrationTestRepo do
  use Ecto.Repo,
    otp_app: :backplane_system,
    adapter: Ecto.Adapters.Postgres
end

defmodule Backplane.Memory.ActivityMigrationOban do
  use Ecto.Migration

  def up, do: Oban.Migration.up(version: 12, prefix: prefix(), create_schema: false)
  def down, do: Oban.Migration.down(version: 1, prefix: prefix())
end

defmodule Backplane.Memory.ActivityMigrationTest do
  use Backplane.Memory.DataCase, async: false

  @migration_version 20_260_812_000_008
  @migration_module Backplane.Repo.Migrations.CreateMemoryActivityDaily
  @oban_version 20_260_410_000_002
  @oban_module Backplane.Memory.ActivityMigrationOban
  @marker %{"backplane_migration" => "20260812000008_activity_projection_repair"}

  test "00008 prefix migration backfills aligned activity and queues only stale history across down/up" do
    prefix = "activity_migration_#{System.unique_integer([:positive])}"
    migration_repo = start_migration_repo()

    with_schema(migration_repo, prefix, fn ->
      create_old_schema(migration_repo, prefix)
      seed_aligned(migration_repo, prefix)
      stale_event_id = seed_stale(migration_repo, prefix)
      load_migration()

      assert :ok = migrate(migration_repo, prefix, :up)

      assert [
               [
                 ~D[2026-08-01],
                 "",
                 "",
                 "host-a",
                 "client-a",
                 "scope:a",
                 "private",
                 "agent.session.started",
                 3,
                 3,
                 0,
                 0,
                 0,
                 0,
                 0,
                 0
               ],
               [
                 ~D[2026-08-01],
                 "project-a",
                 "agent-a",
                 "host-a",
                 "client-a",
                 "scope:a",
                 "private",
                 "memory.recalled",
                 2,
                 1,
                 0,
                 0,
                 0,
                 2,
                 0,
                 0
               ]
             ] = activity_rows(migration_repo, prefix)

      assert [["available", "memory", %{"event_id" => ^stale_event_id}, 5, @marker]] =
               migration_repo.query!("""
               SELECT state, queue, args, max_attempts, meta
               FROM #{table(prefix, "oban_jobs")}
               WHERE worker = 'Backplane.Memory.Workers.ProjectionRepairWorker'
                 AND meta @> '{"backplane_migration":"20260812000008_activity_projection_repair"}'::jsonb
               """).rows

      assert :ok = migrate(migration_repo, prefix, :down)
      refute table?(migration_repo, prefix, "memory_activity_daily")
      refute table?(migration_repo, prefix, "memory_activity_subject_contributions")

      assert :ok = migrate(migration_repo, prefix, :up)
      assert length(activity_rows(migration_repo, prefix)) == 2

      assert [[1]] =
               migration_repo.query!("""
               SELECT count(*) FROM #{table(prefix, "oban_jobs")}
               WHERE meta @> '{"backplane_migration":"20260812000008_activity_projection_repair"}'::jsonb
               """).rows
    end)
  end

  defp create_old_schema(repo, prefix) do
    assert :ok =
             Ecto.Migrator.up(repo, @oban_version, @oban_module,
               prefix: prefix,
               log: false
             )

    repo.query!("""
    CREATE TABLE #{table(prefix, "bpm_events")} (
      id uuid PRIMARY KEY, host_id text, client_id text, scope text, namespace text,
      session_id text, project text, agent_id text, event_type text NOT NULL,
      source_sequence bigint, occurred_at timestamptz NOT NULL, schema_version integer
    )
    """)

    repo.query!("""
    CREATE TABLE #{table(prefix, "bpm_projected_sessions")} (
      subject_id text PRIMARY KEY, host_id text NOT NULL, client_id text, scope text,
      namespace text, session_id text NOT NULL, last_event_at timestamptz NOT NULL,
      source_sequence_max bigint, input_revision text NOT NULL
    )
    """)

    repo.query!("""
    CREATE TABLE #{table(prefix, "bpm_projection_snapshots")} (
      id uuid PRIMARY KEY, projector text NOT NULL, subject_type text NOT NULL,
      subject_id text NOT NULL, input_revision text NOT NULL, output_revision text NOT NULL,
      read_model jsonb NOT NULL, inserted_at timestamptz NOT NULL, updated_at timestamptz NOT NULL
    )
    """)

    repo.query!("""
    CREATE TABLE #{table(prefix, "bpm_projection_states")} (
      id uuid PRIMARY KEY, projector text NOT NULL, subject_type text NOT NULL,
      subject_id text NOT NULL, processing_version text NOT NULL, input_revision text,
      output_revision text, status text NOT NULL, inserted_at timestamptz NOT NULL,
      updated_at timestamptz NOT NULL
    )
    """)
  end

  defp seed_aligned(repo, prefix) do
    event_id = uuid()
    now = ~U[2026-08-01 01:00:00.000000Z]
    insert_event(repo, prefix, event_id, "subject-a", "host-a", "session-a", 1, now)

    repo.query!(
      """
      INSERT INTO #{table(prefix, "bpm_projected_sessions")}
        (subject_id, host_id, client_id, scope, namespace, session_id, last_event_at,
         source_sequence_max, input_revision)
      VALUES ('subject-a', 'host-a', 'client-a', 'scope:a', 'private', 'session-a', $1, 1, 'rev-a')
      """,
      [now]
    )

    activity = %{
      "activity" => [
        %{
          "date" => "2026-08-01",
          "project" => "project-a",
          "agent_id" => "agent-a",
          "host_id" => "host-a",
          "event_type" => "memory.recalled",
          "event_count" => 2,
          "session_count" => 1,
          "error_count" => 0
        },
        %{
          "date" => "2026-08-01",
          "project" => nil,
          "agent_id" => nil,
          "host_id" => "host-a",
          "event_type" => "agent.session.started",
          "event_count" => 1,
          "session_count" => 1,
          "error_count" => 0
        },
        %{
          "date" => "2026-08-01",
          "project" => "",
          "agent_id" => "",
          "host_id" => "host-a",
          "event_type" => "agent.session.started",
          "event_count" => 2,
          "session_count" => 2,
          "error_count" => 0
        }
      ]
    }

    insert_projection(repo, prefix, "subject-a", "rev-a", "out-a", activity)
  end

  defp seed_stale(repo, prefix) do
    first = uuid()
    latest = uuid()

    insert_event(
      repo,
      prefix,
      first,
      "subject-b",
      "host-b",
      "session-b",
      1,
      ~U[2026-08-02 01:00:00Z]
    )

    insert_event(
      repo,
      prefix,
      latest,
      "subject-b",
      "host-b",
      "session-b",
      2,
      ~U[2026-08-02 02:00:00Z]
    )

    repo.query!("""
    INSERT INTO #{table(prefix, "bpm_projected_sessions")}
      (subject_id, host_id, client_id, scope, namespace, session_id, last_event_at,
       source_sequence_max, input_revision)
    VALUES ('subject-b', 'host-b', 'client-b', 'scope:b', 'private', 'session-b',
            '2026-08-02 01:00:00Z', 1, 'rev-old')
    """)

    Ecto.UUID.load!(latest)
  end

  defp insert_event(repo, prefix, id, _subject, host, session, sequence, occurred_at) do
    repo.query!(
      """
      INSERT INTO #{table(prefix, "bpm_events")}
        (id, host_id, client_id, scope, namespace, session_id, project, agent_id,
         event_type, source_sequence, occurred_at, schema_version)
      VALUES ($1, $2, $3, $4, 'private', $5, $6, $7, 'memory.recalled', $8, $9, 1)
      """,
      [
        id,
        host,
        "client-#{String.last(host)}",
        "scope:#{String.last(host)}",
        session,
        "project-#{String.last(host)}",
        "agent-#{String.last(host)}",
        sequence,
        occurred_at
      ]
    )
  end

  defp insert_projection(repo, prefix, subject, input, output, read_model) do
    now = ~U[2026-08-01 02:00:00Z]

    repo.query!(
      """
      INSERT INTO #{table(prefix, "bpm_projection_snapshots")}
        (id, projector, subject_type, subject_id, input_revision, output_revision,
         read_model, inserted_at, updated_at)
      VALUES ($1, 'activity', 'captured_session', $2, $3, $4, $5, $6, $6)
      """,
      [uuid(), subject, input, output, read_model, now]
    )

    repo.query!(
      """
      INSERT INTO #{table(prefix, "bpm_projection_states")}
        (id, projector, subject_type, subject_id, processing_version, input_revision,
         output_revision, status, inserted_at, updated_at)
      VALUES ($1, 'activity', 'captured_session', $2, 'activity-v1', $3, $4,
              'complete', $5, $5)
      """,
      [uuid(), subject, input, output, now]
    )
  end

  defp activity_rows(repo, prefix) do
    repo.query!("""
    SELECT date, project, agent_id, host_id, client_id, scope, namespace, event_type,
           event_count, session_count, memory_count, lesson_count, crystal_count,
           recall_count, action_count, error_count
    FROM #{table(prefix, "memory_activity_daily")}
    ORDER BY date, host_id, event_type
    """).rows
  end

  defp migrate(repo, prefix, direction) do
    apply(Ecto.Migrator, direction, [
      repo,
      @migration_version,
      @migration_module,
      [prefix: prefix, log: false]
    ])
  end

  defp load_migration do
    :backplane_system
    |> Application.app_dir("priv/repo/migrations/20260812000008_create_memory_activity_daily.exs")
    |> Code.require_file()
  end

  defp start_migration_repo do
    config = repo().config() |> Keyword.delete(:pool) |> Keyword.put(:pool_size, 2)
    start_supervised!({Backplane.Memory.ActivityMigrationTestRepo, config})
    Backplane.Memory.ActivityMigrationTestRepo
  end

  defp with_schema(repo, prefix, fun) do
    repo.query!("CREATE SCHEMA #{quote_identifier(prefix)}")

    try do
      fun.()
    after
      repo.query!("DROP SCHEMA IF EXISTS #{quote_identifier(prefix)} CASCADE")
    end
  end

  defp table(prefix, name), do: "#{quote_identifier(prefix)}.#{quote_identifier(name)}"
  defp quote_identifier(value), do: ~s("#{String.replace(value, "\"", "\"\"")}")
  defp uuid, do: Ecto.UUID.generate() |> Ecto.UUID.dump!()

  defp table?(repo, prefix, name) do
    [[exists?]] = repo.query!("SELECT to_regclass($1) IS NOT NULL", ["#{prefix}.#{name}"]).rows
    exists?
  end
end

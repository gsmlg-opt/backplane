defmodule Backplane.Memory.ProjectedSessionMigrationTestRepo do
  use Ecto.Repo,
    otp_app: :backplane_system,
    adapter: Ecto.Adapters.Postgres
end

defmodule Backplane.Memory.ProjectedSessionMigrationOban do
  use Ecto.Migration

  def up, do: Oban.Migration.up(version: 12, prefix: prefix(), create_schema: false)
  def down, do: Oban.Migration.down(version: 1, prefix: prefix())
end

defmodule Backplane.Memory.ProjectedSessionMigrationTest do
  use Backplane.Memory.DataCase, async: false

  @migration_version 20_260_812_000_004
  @migration_module Backplane.Repo.Migrations.CreateProjectedMemorySessions
  @oban_migration_version 20_260_410_000_001
  @oban_migration_module Backplane.Memory.ProjectedSessionMigrationOban
  @repair_worker "Backplane.Memory.Workers.ProjectionRepairWorker"
  @migration_marker %{"backplane_migration" => "20260812000004_projected_session_repair"}

  test "00004 backfills aligned old snapshots in bounded batches and survives down/up" do
    prefix = "projected_session_migration_#{System.unique_integer([:positive])}"
    migration_repo = start_migration_repo()

    with_isolated_schema(migration_repo, prefix, fn ->
      create_pre_00004_schema(migration_repo, prefix)
      seed_old_projection(migration_repo, prefix, "subject-a", "host-a", "shared", "rev-a")
      seed_old_projection(migration_repo, prefix, "subject-b", "host-b", "shared", "rev-b")
      load_migration()

      assert :ok = migrate_up(migration_repo, prefix)
      assert_backfill(migration_repo, prefix)
      assert_migration_jobs(migration_repo, prefix, 2)

      assert :ok =
               Ecto.Migrator.down(migration_repo, @migration_version, @migration_module,
                 prefix: prefix,
                 log: false
               )

      refute table_exists?(migration_repo, prefix, "bpm_projected_sessions")

      assert :ok = migrate_up(migration_repo, prefix)
      assert_backfill(migration_repo, prefix)
      assert_migration_jobs(migration_repo, prefix, 2)
    end)
  end

  test "00004 never combines an R1 snapshot revision with newer R2 event fields" do
    prefix = "projected_session_revision_#{System.unique_integer([:positive])}"
    migration_repo = start_migration_repo()

    with_isolated_schema(migration_repo, prefix, fn ->
      create_pre_00004_schema(migration_repo, prefix)

      %{latest_event_id: latest_event_id} =
        seed_stale_projection(migration_repo, prefix, "subject-stale", "host-stale", "session")

      load_migration()
      assert :ok = migrate_up(migration_repo, prefix)

      assert [
               [
                 "revision-r1",
                 "completed",
                 ~N[2026-08-12 01:01:00.000000],
                 2,
                 0,
                 nil
               ]
             ] =
               migration_repo.query!("""
               SELECT input_revision, status, last_event_at, source_sequence_max,
                      gap_count, integration
               FROM #{table(prefix, "bpm_projected_sessions")}
               WHERE subject_id = 'subject-stale'
               """).rows

      # R1's complete summary cannot suppress R2 forever: cutover always adds a
      # fresh durable repair for the latest authoritative event, even when an
      # older repair attempt is retryable/failed.
      assert [
               [
                 "available",
                 "memory",
                 @repair_worker,
                 %{"event_id" => ^latest_event_id},
                 5,
                 @migration_marker
               ]
             ] =
               migration_repo.query!("""
               SELECT state, queue, worker, args, max_attempts, meta
               FROM #{table(prefix, "oban_jobs")}
               WHERE meta @> '{"backplane_migration":"20260812000004_projected_session_repair"}'::jsonb
               """).rows

      assert [[2]] =
               migration_repo.query!("""
               SELECT count(*)
               FROM #{table(prefix, "oban_jobs")}
               WHERE worker = '#{@repair_worker}'
               """).rows

      assert :ok = migrate_down(migration_repo, prefix)
      assert :ok = migrate_up(migration_repo, prefix)
      assert_migration_jobs(migration_repo, prefix, 1)
    end)
  end

  test "00004 migration repair identity is isolated by prefix" do
    first_prefix = "projected_session_prefix_a_#{System.unique_integer([:positive])}"
    second_prefix = "projected_session_prefix_b_#{System.unique_integer([:positive])}"
    migration_repo = start_migration_repo()

    with_isolated_schema(migration_repo, first_prefix, fn ->
      with_isolated_schema(migration_repo, second_prefix, fn ->
        for prefix <- [first_prefix, second_prefix] do
          create_pre_00004_schema(migration_repo, prefix)

          seed_old_projection(
            migration_repo,
            prefix,
            "same-subject",
            "same-host",
            "same-session",
            "same-rev"
          )
        end

        load_migration()
        assert :ok = migrate_up(migration_repo, first_prefix)
        assert :ok = migrate_up(migration_repo, second_prefix)
        assert_migration_jobs(migration_repo, first_prefix, 1)
        assert_migration_jobs(migration_repo, second_prefix, 1)
      end)
    end)
  end

  defp assert_backfill(repo, prefix) do
    rows =
      repo.query!("""
      SELECT subject_id, host_id, session_id, project, agent_id, integration,
             status, started_at, ended_at, last_event_at, source_sequence_max,
             gap_count, processing_version, input_revision
      FROM #{table(prefix, "bpm_projected_sessions")}
      ORDER BY host_id
      """).rows

    assert [first, second] = rows

    for {row, subject_id, host_id, revision} <- [
          {first, "subject-a", "host-a", "rev-a"},
          {second, "subject-b", "host-b", "rev-b"}
        ] do
      assert [
               ^subject_id,
               ^host_id,
               "shared",
               "canonical-project",
               "canonical-agent",
               "codex",
               "completed",
               ~N[2026-08-12 01:00:00.000000],
               ~N[2026-08-12 01:02:00.000000],
               ~N[2026-08-12 01:02:00.000000],
               3,
               1,
               "session-v1",
               ^revision
             ] = row
    end

    # These are the exact indexed predicates used by the fallback candidate read.
    assert [[2]] =
             repo.query!("""
             SELECT count(*)
             FROM #{table(prefix, "bpm_projected_sessions")}
             WHERE status IN ('stopped', 'completed', 'abandoned')
               AND last_event_at <= '2026-08-12 02:00:00Z'
             """).rows
  end

  defp create_pre_00004_schema(repo, prefix) do
    assert :ok =
             Ecto.Migrator.up(repo, @oban_migration_version, @oban_migration_module,
               prefix: prefix,
               log: false
             )

    repo.query!("""
    CREATE TABLE #{table(prefix, "bpm_events")} (
      id uuid PRIMARY KEY,
      host_id text,
      session_id text,
      project text,
      agent_id text,
      integration text,
      event_type text NOT NULL,
      source_sequence bigint,
      occurred_at timestamptz NOT NULL,
      schema_version integer
    )
    """)

    repo.query!("""
    CREATE INDEX bpm_events_host_session_source_sequence_idx
    ON #{table(prefix, "bpm_events")} (host_id, session_id, source_sequence)
    """)

    repo.query!("""
    CREATE TABLE #{table(prefix, "bpm_projection_snapshots")} (
      id uuid PRIMARY KEY,
      projector text NOT NULL,
      subject_type text NOT NULL,
      subject_id text NOT NULL,
      input_revision text NOT NULL,
      output_revision text NOT NULL,
      read_model jsonb NOT NULL,
      inserted_at timestamptz NOT NULL,
      updated_at timestamptz NOT NULL
    )
    """)

    repo.query!("""
    CREATE TABLE #{table(prefix, "bpm_projection_states")} (
      id uuid PRIMARY KEY,
      projector text NOT NULL,
      subject_type text NOT NULL,
      subject_id text NOT NULL,
      processing_version text,
      input_revision text,
      output_revision text,
      status text NOT NULL,
      inserted_at timestamptz NOT NULL,
      updated_at timestamptz NOT NULL
    )
    """)
  end

  defp seed_old_projection(repo, prefix, subject_id, host_id, session_id, revision) do
    output_revision = "output-#{revision}"
    now = ~U[2026-08-12 01:03:00.000000Z]

    events = [
      [uuid(), 1, "agent.session.started", ~U[2026-08-12 01:00:00.000000Z]],
      [uuid(), 3, "agent.session.ended", ~U[2026-08-12 01:02:00.000000Z]]
    ]

    Enum.each(events, fn [id, sequence, event_type, occurred_at] ->
      insert_event(repo, prefix, id, host_id, session_id,
        event_type: event_type,
        sequence: sequence,
        occurred_at: occurred_at,
        integration: "codex"
      )
    end)

    # Old shape lacks the new indexed lifecycle fields but still records the
    # exact event IDs that produced this revision.
    read_model = %{
      "host_id" => host_id,
      "session_id" => session_id,
      "status" => "active",
      "started_at" => "not-a-time",
      "source_event_ids" => Enum.map(events, fn [id | _rest] -> Ecto.UUID.load!(id) end)
    }

    repo.query!(
      """
      INSERT INTO #{table(prefix, "bpm_projection_snapshots")}
        (id, projector, subject_type, subject_id, input_revision, output_revision,
         read_model, inserted_at, updated_at)
      VALUES ($1, 'session', 'captured_session', $2, $3, $4, $5, $6, $6)
      """,
      [uuid(), subject_id, revision, output_revision, read_model, now]
    )

    repo.query!(
      """
      INSERT INTO #{table(prefix, "bpm_projection_states")}
        (id, projector, subject_type, subject_id, processing_version,
         input_revision, output_revision, status, inserted_at, updated_at)
      VALUES ($1, 'session', 'captured_session', $2, 'session-v1',
              $3, $4, 'pending', $5, $5)
      """,
      [uuid(), subject_id, revision, output_revision, now]
    )
  end

  defp seed_stale_projection(repo, prefix, subject_id, host_id, session_id) do
    first = uuid()
    terminal = uuid()
    newer = uuid()

    insert_event(repo, prefix, first, host_id, session_id,
      event_type: "agent.session.started",
      sequence: 1,
      occurred_at: ~U[2026-08-12 01:00:00.000000Z],
      integration: nil
    )

    insert_event(repo, prefix, terminal, host_id, session_id,
      event_type: "agent.session.ended",
      sequence: 2,
      occurred_at: ~U[2026-08-12 01:01:00.000000Z],
      integration: "codex"
    )

    insert_event(repo, prefix, newer, host_id, session_id,
      event_type: "agent.tool.completed",
      sequence: 3,
      occurred_at: ~U[2026-08-12 01:02:00.000000Z],
      integration: "codex"
    )

    now = ~U[2026-08-12 01:03:00.000000Z]

    read_model = %{
      "host_id" => host_id,
      "session_id" => session_id,
      "source_event_ids" => [Ecto.UUID.load!(first), Ecto.UUID.load!(terminal)]
    }

    repo.query!(
      """
      INSERT INTO #{table(prefix, "bpm_projection_snapshots")}
        (id, projector, subject_type, subject_id, input_revision, output_revision,
         read_model, inserted_at, updated_at)
      VALUES ($1, 'session', 'captured_session', $2, 'revision-r1',
              'output-r1', $3, $4, $4)
      """,
      [uuid(), subject_id, read_model, now]
    )

    for {projector, version, status} <- [
          {"session", "session-v1", "complete"},
          {"summary", "summary-v1", "complete"}
        ] do
      repo.query!(
        """
        INSERT INTO #{table(prefix, "bpm_projection_states")}
          (id, projector, subject_type, subject_id, processing_version,
           input_revision, output_revision, status, inserted_at, updated_at)
        VALUES ($1, $2, 'captured_session', $3, $4, 'revision-r1',
                'output-r1', $5, $6, $6)
        """,
        [uuid(), projector, subject_id, version, status, now]
      )
    end

    latest_event_id = Ecto.UUID.load!(newer)

    repo.query!(
      """
      INSERT INTO #{table(prefix, "oban_jobs")} (state, queue, worker, args)
      VALUES ('retryable', 'memory', 'Backplane.Memory.Workers.ProjectionRepairWorker',
              jsonb_build_object('event_id', $1::text))
      """,
      [latest_event_id]
    )

    %{latest_event_id: latest_event_id}
  end

  defp insert_event(repo, prefix, id, host_id, session_id, opts) do
    repo.query!(
      """
      INSERT INTO #{table(prefix, "bpm_events")}
        (id, host_id, session_id, project, agent_id, integration, event_type,
         source_sequence, occurred_at, schema_version)
      VALUES ($1, $2, $3, 'canonical-project', 'canonical-agent', $4,
              $5, $6, $7, 1)
      """,
      [
        id,
        host_id,
        session_id,
        Keyword.fetch!(opts, :integration),
        Keyword.fetch!(opts, :event_type),
        Keyword.fetch!(opts, :sequence),
        Keyword.fetch!(opts, :occurred_at)
      ]
    )
  end

  defp migrate_up(repo, prefix) do
    Ecto.Migrator.up(repo, @migration_version, @migration_module,
      prefix: prefix,
      log: false
    )
  end

  defp migrate_down(repo, prefix) do
    Ecto.Migrator.down(repo, @migration_version, @migration_module,
      prefix: prefix,
      log: false
    )
  end

  defp assert_migration_jobs(repo, prefix, expected_count) do
    assert [[^expected_count]] =
             repo.query!("""
             SELECT count(*)
             FROM #{table(prefix, "oban_jobs")}
             WHERE worker = '#{@repair_worker}'
               AND queue = 'memory'
               AND state = 'available'
               AND max_attempts = 5
               AND meta @> '{"backplane_migration":"20260812000004_projected_session_repair"}'::jsonb
             """).rows
  end

  defp table_exists?(repo, prefix, name) do
    [[exists?]] =
      repo.query!("SELECT to_regclass($1) IS NOT NULL", ["#{prefix}.#{name}"]).rows

    exists?
  end

  defp load_migration do
    :backplane_system
    |> Application.app_dir(
      "priv/repo/migrations/20260812000004_create_projected_memory_sessions.exs"
    )
    |> Code.require_file()
  end

  defp start_migration_repo do
    config =
      repo().config()
      |> Keyword.delete(:pool)
      |> Keyword.put(:pool_size, 2)

    start_supervised!({Backplane.Memory.ProjectedSessionMigrationTestRepo, config})
    Backplane.Memory.ProjectedSessionMigrationTestRepo
  end

  defp with_isolated_schema(repo, prefix, fun) do
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
end

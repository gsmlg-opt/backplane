defmodule Backplane.Repo.Migrations.DropRetiredMemoryTablesTestRepo do
  use Ecto.Repo, otp_app: :backplane_system, adapter: Ecto.Adapters.Postgres
end

defmodule Backplane.Repo.Migrations.DropRetiredMemoryTablesTest do
  use ExUnit.Case, async: false

  # Applies the full migration history to an isolated schema.
  @moduletag timeout: 300_000

  @repo Backplane.Repo.Migrations.DropRetiredMemoryTablesTestRepo
  @before_reset 20_261_109_000_002
  @drop_retired 20_261_109_000_004

  @capture_tables ~w(
    bpm_events bpm_streams bpm_projection_states bpm_projection_snapshots
    bpm_projection_repair_frontiers bpm_projected_sessions bpm_projected_observations
  )

  setup do
    config =
      Application.fetch_env!(:backplane_system, Backplane.Repo)
      |> Keyword.delete(:pool)
      |> Keyword.put(:pool_size, 2)

    start_supervised!({@repo, config})
    prefix = "drop_retired_memory_#{System.unique_integer([:positive])}"
    @repo.query!(~s|CREATE SCHEMA "#{prefix}"|)

    on_exit(fn ->
      {:ok, pid} = @repo.start_link(config)

      try do
        @repo.query!(~s|DROP SCHEMA IF EXISTS "#{prefix}" CASCADE|)
      after
        GenServer.stop(pid)
      end
    end)

    %{prefix: prefix}
  end

  test "populated capture data and retired tables are reset", %{prefix: prefix} do
    assert [_ | _] = migrate(prefix, to: @before_reset)

    space_id = Ecto.UUID.generate()
    event_id = Ecto.UUID.generate()
    record_id = seed!(prefix, space_id, event_id)

    assert [_ | _] = migrate(prefix, to: @drop_retired)
    assert @drop_retired in versions(prefix)

    for table <- @capture_tables do
      assert count(prefix, table) == 0, "#{table} should be empty"

      assert partition_columns(prefix, table) == [],
             "#{table} still has partition columns"
    end

    assert trigger_enabled?(prefix, "bpm_events", "bpm_events_captured_truncate_immutable")

    for table <-
          ~w(bpm_memories bpm_memory_spaces bpm_observations memory_sessions memory_replay_events
             memory_lessons memory_crystals bpm_memory_partition_revisions) do
      refute table_exists?(prefix, table), "#{table} should be dropped"
    end

    for function <- ~w(bpm_capture_memory_edge_change bpm_derive_memory_space_identity) do
      refute function_exists?(prefix, function), "#{function} should be dropped"
    end

    assert [[^record_id, "kept record"]] =
             @repo.query!(~s|SELECT id::text, content FROM "#{prefix}".memory_records|).rows

    assert table_exists?(prefix, "memory_audit_log")
  end

  defp seed!(prefix, space_id, event_id) do
    q = fn sql, params -> @repo.query!(sql, params) end

    q.(
      ~s|INSERT INTO "#{prefix}".bpm_memory_spaces (id, kind, status, inserted_at, updated_at) VALUES ($1, 'private', 'active', now(), now())|,
      [Ecto.UUID.dump!(space_id)]
    )

    q.(
      ~s|INSERT INTO "#{prefix}".bpm_streams (stream_id, memory_space_id, scope, namespace, session_id, next_sequence, last_window_sequence, inserted_at, updated_at) VALUES ('reset-stream', $1, 'global', 'private', 'reset-session', 2, 0, now(), now())|,
      [Ecto.UUID.dump!(space_id)]
    )

    q.(
      ~s|INSERT INTO "#{prefix}".bpm_events (id, stream_id, sequence, memory_space_id, scope, namespace, session_id, event_type, payload, schema_version, captured_at, occurred_at, inserted_at) VALUES ($1, 'reset-stream', 1, $2, 'global', 'private', 'reset-session', 'agent.prompt.submitted', '{}'::jsonb, 1, now(), now(), now())|,
      [Ecto.UUID.dump!(event_id), Ecto.UUID.dump!(space_id)]
    )

    q.(
      ~s|INSERT INTO "#{prefix}".memory_replay_events (subject_id, input_revision, position, event_id, host_id, client_id, scope, namespace, session_id, kind, event_type, occurred_at, processing_version, inserted_at, updated_at, memory_space_id) VALUES ('subject', 'rev', 1, $1, 'host', 'client', 'global', 'private', 'reset-session', 'prompt', 'agent.prompt.submitted', now(), 'v1', now(), now(), $2)|,
      [Ecto.UUID.dump!(event_id), Ecto.UUID.dump!(space_id)]
    )

    [[record_id]] =
      q.(
        ~s|INSERT INTO "#{prefix}".memory_records (kind, content, writer, inserted_at, updated_at, observed_at) VALUES ('note', 'kept record', 'user', now(), now(), now()) RETURNING id::text|,
        []
      ).rows

    record_id
  end

  defp migrate(prefix, opts) do
    Ecto.Migrator.run(@repo, migrations_path(), :up, [prefix: prefix, log: false] ++ opts)
  end

  defp migrations_path, do: Application.app_dir(:backplane_system, "priv/repo/migrations")

  defp versions(prefix),
    do: @repo.query!(~s|SELECT version FROM "#{prefix}".schema_migrations|).rows |> List.flatten()

  defp count(prefix, table),
    do: @repo.query!(~s|SELECT count(*) FROM "#{prefix}"."#{table}"|).rows |> hd() |> hd()

  defp partition_columns(prefix, table) do
    @repo.query!(
      """
      SELECT column_name FROM information_schema.columns
      WHERE table_schema = $1 AND table_name = $2
        AND column_name IN ('memory_space_id', 'scope', 'namespace')
      """,
      [prefix, table]
    ).rows
  end

  defp trigger_enabled?(prefix, table, trigger) do
    [[enabled]] =
      @repo.query!(
        """
        SELECT t.tgenabled::text FROM pg_trigger t
        JOIN pg_class c ON c.oid = t.tgrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = $1 AND c.relname = $2 AND t.tgname = $3
        """,
        [prefix, table, trigger]
      ).rows

    enabled == "O"
  end

  defp table_exists?(prefix, table) do
    [[exists?]] =
      @repo.query!("SELECT to_regclass($1) IS NOT NULL", [~s|"#{prefix}"."#{table}"|]).rows

    exists?
  end

  defp function_exists?(prefix, name) do
    @repo.query!(
      """
      SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = $1 AND p.proname = $2
      """,
      [prefix, name]
    ).rows != []
  end
end

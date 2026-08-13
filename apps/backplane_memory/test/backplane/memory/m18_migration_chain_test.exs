defmodule Backplane.Memory.M18MigrationChainTestRepo do
  use Ecto.Repo,
    otp_app: :backplane_system,
    adapter: Ecto.Adapters.Postgres
end

defmodule Backplane.Memory.M18MigrationChainTest do
  use Backplane.Memory.DataCase, async: false

  @last_pre_m18_version 20_260_811_000_002
  @first_m18_version 20_260_812_000_001
  @last_m18_version 20_260_812_000_022

  @public_guard_tables ~w(
    llm_auto_models
    llm_auto_model_routes
    system_settings
    skills
    skill_hosts
    skill_host_agent_tokens
    skill_host_auth_tokens
    memory_facet_dimensions
  )

  @public_guard_indexes ~w(
    bpm_streams_last_event_stream_idx
    bpm_events_occurred_id_idx
    bpm_events_host_session_source_sequence_idx
    bpm_events_capture_source_identity_uniq
  )

  test "fresh schema applies the complete 00001 through 00022 M18 sequence" do
    prefix = unique_prefix("fresh")
    decoy = unique_prefix("fresh_decoy")

    with_isolated_schemas([prefix, decoy], decoy, fn migration_repo ->
      public_before = public_snapshot(migration_repo)

      assert [_ | _] = migrate(migration_repo, prefix, all: true)

      versions = migrated_versions(migration_repo, prefix)

      assert Enum.filter(versions, &(&1 in @first_m18_version..@last_m18_version)) ==
               Enum.to_list(@first_m18_version..@last_m18_version)

      assert table_exists?(migration_repo, prefix, "memory_lessons")
      assert table_exists?(migration_repo, prefix, "memory_import_batches")
      assert index_exists?(migration_repo, prefix, "bpm_memories_eviction_scan_idx")
      assert public_snapshot(migration_repo) == public_before
    end)
  end

  test "upgrade accepts capture throughout cutover and restore replays every exported canonical event" do
    prefix = unique_prefix("upgrade")
    restored_prefix = unique_prefix("restored")
    decoy = unique_prefix("upgrade_decoy")

    with_isolated_schemas([prefix, restored_prefix, decoy], decoy, fn migration_repo ->
      public_before = public_snapshot(migration_repo)

      assert [_ | _] = migrate(migration_repo, prefix, to: @last_pre_m18_version)
      seed_compatible_projection_inputs(migration_repo, prefix)

      before_id = insert_event!(migration_repo, prefix, 1)
      test_process = self()

      blocker =
        Task.async(fn ->
          migration_repo.transaction(
            fn ->
              migration_repo.query!(
                "LOCK TABLE #{table(prefix, "bpm_memories")} IN ACCESS EXCLUSIVE MODE"
              )

              send(test_process, :eviction_table_lock_held)

              receive do
                :release_eviction_table_lock -> :ok
              after
                10_000 -> raise "timed out waiting to release migration barrier"
              end
            end,
            timeout: :infinity
          )
        end)

      assert_receive :eviction_table_lock_held, 5_000
      migration = Task.async(fn -> migrate(migration_repo, prefix, all: true) end)

      try do
        assert_eventually(fn -> migration_waiting_at_eviction_index?(migration_repo, prefix) end)
        during_id = insert_event!(migration_repo, prefix, 2)
        send(blocker.pid, :release_eviction_table_lock)

        assert {:ok, :ok} = Task.await(blocker, 10_000)
        assert [_ | _] = Task.await(migration, 30_000)

        after_id = insert_event!(migration_repo, prefix, 3)
        captured_ids = [before_id, during_id, after_id]

        assert cutover_consistent?(migration_repo, prefix)
        exported_events = export_events(migration_repo, prefix, captured_ids)
        assert length(exported_events) == length(captured_ids)
        exported_streams = export_streams(migration_repo, prefix, exported_events)
        assert length(exported_streams) == 1

        # 00006/00007 are intentionally irreversible. Operational rollback restores
        # a pre-upgrade schema and then replays the exported immutable event rows;
        # it never pretends that their `down/0` callbacks are safe.
        assert [_ | _] = migrate(migration_repo, restored_prefix, to: @last_pre_m18_version)
        assert export_streams(migration_repo, restored_prefix, exported_events) == []
        replay_streams!(migration_repo, restored_prefix, exported_streams)
        replay_events!(migration_repo, restored_prefix, exported_events)
        replay_streams!(migration_repo, restored_prefix, exported_streams)
        replay_events!(migration_repo, restored_prefix, exported_events)

        assert export_streams(migration_repo, restored_prefix, exported_events) ==
                 exported_streams

        assert export_events(migration_repo, restored_prefix, captured_ids) == exported_events
        assert public_snapshot(migration_repo) == public_before
      after
        send(blocker.pid, :release_eviction_table_lock)
      end
    end)
  end

  defp migrate(repo, prefix, opts) do
    Ecto.Migrator.run(
      repo,
      migrations_path(),
      :up,
      Keyword.merge([prefix: prefix, log: false], opts)
    )
  end

  defp seed_compatible_projection_inputs(repo, prefix) do
    repo.query!("""
    INSERT INTO #{table(prefix, "bpm_streams")}
      (stream_id, project, host_id, client_id, session_id, inserted_at, updated_at)
    VALUES ('m18-live-stream', 'm18', 'host-m18', 'client-m18', 'session-m18', now(), now())
    """)
  end

  defp insert_event!(repo, prefix, sequence) do
    event_id = Ecto.UUID.dump!(Ecto.UUID.generate())
    stream_id = "m18-live-stream"

    repo.query!(
      """
      INSERT INTO #{table(prefix, "bpm_events")}
        (id, stream_id, sequence, project, namespace, host_id, client_id, session_id,
         event_type, payload, schema_version, integration, scope, source_sequence,
         captured_at, occurred_at, inserted_at)
      VALUES ($1, $2, $3, 'm18', 'private', 'host-m18', 'client-m18', 'session-m18',
              'agent.prompt.submitted', $4, 1, 'claude_code', 'memory.write', $3,
              now(), now(), now())
      """,
      [event_id, stream_id, sequence, %{"sequence" => sequence}]
    )

    repo.query!(
      """
      UPDATE #{table(prefix, "bpm_streams")}
      SET next_sequence = GREATEST(next_sequence, $2 + 1),
          last_event_at = now(),
          updated_at = now()
      WHERE stream_id = $1
      """,
      [stream_id, sequence]
    )

    event_id
  end

  defp export_events(repo, prefix, ids) do
    repo.query!(
      """
      SELECT id, stream_id, sequence, project, namespace, host_id, client_id, session_id,
             event_type, payload, schema_version, integration, scope, source_sequence,
             captured_at, occurred_at, inserted_at
      FROM #{table(prefix, "bpm_events")}
      WHERE id = ANY($1)
      ORDER BY sequence
      """,
      [ids]
    ).rows
  end

  defp export_streams(repo, prefix, event_rows) do
    stream_ids = event_rows |> Enum.map(&Enum.at(&1, 1)) |> Enum.uniq()

    repo.query!(
      """
      SELECT stream_id, project, agent_id, host_id, client_id, session_id, run_id,
             next_sequence, last_window_sequence, last_event_at, closed_at, inserted_at, updated_at
      FROM #{table(prefix, "bpm_streams")}
      WHERE stream_id = ANY($1)
      ORDER BY stream_id
      """,
      [stream_ids]
    ).rows
  end

  defp replay_streams!(repo, prefix, rows) do
    Enum.each(rows, fn row ->
      repo.query!(
        """
        INSERT INTO #{table(prefix, "bpm_streams")} AS current_stream
          (stream_id, project, agent_id, host_id, client_id, session_id, run_id,
           next_sequence, last_window_sequence, last_event_at, closed_at, inserted_at, updated_at)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)
        ON CONFLICT (stream_id) DO UPDATE SET
          next_sequence = GREATEST(current_stream.next_sequence, EXCLUDED.next_sequence),
          last_window_sequence = GREATEST(current_stream.last_window_sequence, EXCLUDED.last_window_sequence),
          last_event_at = GREATEST(current_stream.last_event_at, EXCLUDED.last_event_at),
          closed_at = GREATEST(current_stream.closed_at, EXCLUDED.closed_at),
          updated_at = GREATEST(current_stream.updated_at, EXCLUDED.updated_at)
        """,
        row
      )
    end)
  end

  defp replay_events!(repo, prefix, rows) do
    Enum.each(rows, fn row ->
      repo.query!(
        """
        INSERT INTO #{table(prefix, "bpm_events")}
          (id, stream_id, sequence, project, namespace, host_id, client_id, session_id,
           event_type, payload, schema_version, integration, scope, source_sequence,
           captured_at, occurred_at, inserted_at)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14,
                $15, $16, $17)
        ON CONFLICT (id) DO NOTHING
        """,
        row
      )
    end)
  end

  defp cutover_consistent?(repo, prefix) do
    [[events]] = repo.query!("SELECT count(*) FROM #{table(prefix, "bpm_events")}").rows

    [[immutable]] =
      repo.query!(
        "SELECT count(*) FROM #{table(prefix, "bpm_events")} WHERE schema_version IS NOT NULL"
      ).rows

    events == immutable and events > 0
  end

  defp migrated_versions(repo, prefix) do
    repo.query!("SELECT version FROM #{table(prefix, "schema_migrations")} ORDER BY version").rows
    |> List.flatten()
  end

  defp migration_waiting_at_eviction_index?(repo, prefix) do
    versions = migrated_versions(repo, prefix)

    @first_m18_version in versions and
      (@first_m18_version + 1) in versions and
      (@first_m18_version + 2) not in versions
  end

  defp migrations_path,
    do: Application.app_dir(:backplane_system, "priv/repo/migrations")

  defp start_migration_repo(search_path) do
    config =
      repo().config()
      |> Keyword.delete(:pool)
      |> Keyword.put(:pool_size, 4)
      |> Keyword.put(:parameters, search_path: search_path)

    start_supervised!({Backplane.Memory.M18MigrationChainTestRepo, config})
    Backplane.Memory.M18MigrationChainTestRepo
  end

  defp with_isolated_schemas(prefixes, search_path, fun) do
    schema_repo = start_migration_repo("public")
    Enum.each(prefixes, &schema_repo.query!("CREATE SCHEMA #{quote_identifier(&1)}"))
    stop_supervised(Backplane.Memory.M18MigrationChainTestRepo)

    migration_repo = start_migration_repo(search_path)

    try do
      fun.(migration_repo)
    after
      stop_supervised(Backplane.Memory.M18MigrationChainTestRepo)
      cleanup_repo = start_migration_repo("public")

      Enum.each(prefixes, fn prefix ->
        cleanup_repo.query!("DROP SCHEMA IF EXISTS #{quote_identifier(prefix)} CASCADE")
      end)
    end
  end

  defp table_exists?(repo, prefix, name) do
    [[exists?]] = repo.query!("SELECT to_regclass($1) IS NOT NULL", ["#{prefix}.#{name}"]).rows
    exists?
  end

  defp index_exists?(repo, prefix, name), do: table_exists?(repo, prefix, name)

  defp public_snapshot(repo) do
    tables =
      Map.new(@public_guard_tables, fn name ->
        exists? = table_exists?(repo, "public", name)

        fingerprint =
          if exists? do
            [[count, digest]] =
              repo.query!("""
              SELECT count(*),
                     md5(coalesce(string_agg(to_jsonb(row_data)::text, E'\\n'
                         ORDER BY to_jsonb(row_data)::text), ''))
              FROM #{table("public", name)} AS row_data
              """).rows

            {count, digest}
          end

        {name, {exists?, fingerprint}}
      end)

    indexes =
      repo.query!(
        """
        SELECT indexname, indexdef
        FROM pg_indexes
        WHERE schemaname = 'public' AND indexname = ANY($1)
        ORDER BY indexname
        """,
        [@public_guard_indexes]
      ).rows

    %{tables: tables, indexes: indexes}
  end

  defp assert_eventually(fun, attempts \\ 100)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition did not become true")

  defp unique_prefix(label), do: "m18_chain_#{label}_#{System.unique_integer([:positive])}"
  defp table(prefix, name), do: "#{quote_identifier(prefix)}.#{quote_identifier(name)}"

  defp quote_identifier(value),
    do: ~s("#{value |> to_string() |> String.replace("\"", "\"\"")}")
end

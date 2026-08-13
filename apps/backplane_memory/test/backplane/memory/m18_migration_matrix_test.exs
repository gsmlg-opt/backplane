defmodule Backplane.Memory.M18MigrationMatrixTestRepo do
  use Ecto.Repo,
    otp_app: :backplane_system,
    adapter: Ecto.Adapters.Postgres
end

defmodule Backplane.Memory.M18MigrationMatrixTest do
  use Backplane.Memory.DataCase, async: false

  @lessons_version 20_260_812_000_013
  @lessons_migration Backplane.Repo.Migrations.CreateMemoryLessons
  @enqueued_version 20_260_812_000_015
  @enqueued_migration Backplane.Repo.Migrations.AddEnqueuedProjectionState
  @eviction_version 20_260_812_000_003
  @eviction_migration Backplane.Repo.Migrations.IndexMemoryEvictionBatches
  @summary_source_version 20_260_812_000_005
  @summary_source_migration Backplane.Repo.Migrations.AddSummarySourceCompleteness
  @imports_version 20_260_812_000_021
  @imports_migration Backplane.Repo.Migrations.CreateMemoryImportBatches
  @config_defaults_version 20_260_812_000_022
  @config_defaults_migration Backplane.Repo.Migrations.AlignMemoryV2ConfigurationDefaults

  test "00013 installs and reverses lesson invariants entirely inside its migration prefix" do
    prefix = unique_prefix("lessons")
    decoy = unique_prefix("lessons_decoy")
    migration_repo = start_migration_repo()

    with_schemas(migration_repo, [prefix, decoy], fn ->
      Enum.each([prefix, decoy], &create_lesson_parents(migration_repo, &1))
      memory_id = Ecto.UUID.generate()
      dumped_memory_id = Ecto.UUID.dump!(memory_id)

      migration_repo.query!(
        "INSERT INTO #{table(prefix, "bpm_memories")} (id, memory_type) VALUES ($1, 'procedural')",
        [dumped_memory_id]
      )

      public_function_count =
        function_count(migration_repo, "public", "memory_active_lesson_requires_evidence")

      load_migration("20260812000013_create_memory_lessons.exs")

      assert :ok =
               Ecto.Migrator.up(migration_repo, @lessons_version, @lessons_migration,
                 prefix: prefix,
                 log: false
               )

      assert table_exists?(migration_repo, prefix, "memory_lessons")
      refute table_exists?(migration_repo, decoy, "memory_lessons")
      assert function_exists?(migration_repo, prefix, "memory_active_lesson_requires_evidence")

      assert function_count(
               migration_repo,
               "public",
               "memory_active_lesson_requires_evidence"
             ) == public_function_count

      assert_raise Postgrex.Error, ~r/requires evidence/, fn ->
        insert_lesson(migration_repo, prefix, dumped_memory_id, "active")
      end

      migration_repo.query!(
        "INSERT INTO #{table(prefix, "bpm_memory_evidence")} (memory_id) VALUES ($1)",
        [dumped_memory_id]
      )

      insert_lesson(migration_repo, prefix, dumped_memory_id, "active")

      assert_raise Postgrex.Error, ~r/requires procedural memory parent/, fn ->
        migration_repo.query!(
          "UPDATE #{table(prefix, "bpm_memories")} SET memory_type = 'semantic' WHERE id = $1",
          [dumped_memory_id]
        )
      end

      assert :ok =
               Ecto.Migrator.down(migration_repo, @lessons_version, @lessons_migration,
                 prefix: prefix,
                 log: false
               )

      refute table_exists?(migration_repo, prefix, "memory_lessons")
      refute function_exists?(migration_repo, prefix, "memory_active_lesson_requires_evidence")
      refute function_exists?(migration_repo, prefix, "memory_lesson_requires_procedural_parent")
    end)
  end

  test "00015 maps live enqueued projections back to pending without changing accepted events" do
    prefix = unique_prefix("enqueued")
    migration_repo = start_migration_repo()

    with_schemas(migration_repo, [prefix], fn ->
      migration_repo.query!("""
      CREATE TABLE #{table(prefix, "bpm_projection_states")} (
        id bigserial PRIMARY KEY,
        status text NOT NULL,
        CONSTRAINT bpm_projection_states_status_check
          CHECK (status IN ('pending', 'running', 'complete', 'skipped', 'failed', 'dead_letter'))
      )
      """)

      migration_repo.query!("""
      CREATE TABLE #{table(prefix, "bpm_events")} (
        id uuid PRIMARY KEY,
        payload jsonb NOT NULL
      )
      """)

      event_id = Ecto.UUID.generate()
      dumped_event_id = Ecto.UUID.dump!(event_id)

      migration_repo.query!(
        "INSERT INTO #{table(prefix, "bpm_events")} (id, payload) VALUES ($1, '{\"accepted\":true}')",
        [dumped_event_id]
      )

      load_migration("20260812000015_add_enqueued_projection_state.exs")

      assert :ok =
               Ecto.Migrator.up(migration_repo, @enqueued_version, @enqueued_migration,
                 prefix: prefix,
                 log: false
               )

      migration_repo.query!(
        "INSERT INTO #{table(prefix, "bpm_projection_states")} (status) VALUES ('enqueued')"
      )

      assert :ok =
               Ecto.Migrator.down(migration_repo, @enqueued_version, @enqueued_migration,
                 prefix: prefix,
                 log: false
               )

      assert [["pending"]] =
               migration_repo.query!(
                 "SELECT status FROM #{table(prefix, "bpm_projection_states")}"
               ).rows

      assert [[^dumped_event_id, %{"accepted" => true}]] =
               migration_repo.query!(
                 "SELECT id, payload FROM #{table(prefix, "bpm_events")} WHERE id = $1",
                 [dumped_event_id]
               ).rows

      assert :ok =
               Ecto.Migrator.up(migration_repo, @enqueued_version, @enqueued_migration,
                 prefix: prefix,
                 log: false
               )
    end)
  end

  test "00003 creates and reverses the concurrent eviction index inside its prefix" do
    prefix = unique_prefix("eviction")
    migration_repo = start_migration_repo()

    with_schemas(migration_repo, [prefix], fn ->
      migration_repo.query!("""
      CREATE TABLE #{table(prefix, "bpm_memories")} (
        id uuid PRIMARY KEY,
        inserted_at timestamptz NOT NULL,
        deleted_at timestamptz
      )
      """)

      migration_repo.query!(
        "INSERT INTO #{table(prefix, "bpm_memories")} (id, inserted_at) VALUES ($1, now())",
        [Ecto.UUID.dump!(Ecto.UUID.generate())]
      )

      load_migration("20260812000003_index_memory_eviction_batches.exs")

      assert :ok =
               Ecto.Migrator.up(migration_repo, @eviction_version, @eviction_migration,
                 prefix: prefix,
                 log: false
               )

      assert index_exists?(migration_repo, prefix, "bpm_memories_eviction_scan_idx")

      assert :ok =
               Ecto.Migrator.down(migration_repo, @eviction_version, @eviction_migration,
                 prefix: prefix,
                 log: false
               )

      refute index_exists?(migration_repo, prefix, "bpm_memories_eviction_scan_idx")
    end)
  end

  test "00005 backfills populated summaries and reverses only its prefixed columns" do
    prefix = unique_prefix("summary_source")
    migration_repo = start_migration_repo()

    with_schemas(migration_repo, [prefix], fn ->
      migration_repo.query!(
        "CREATE TABLE #{table(prefix, "memory_summaries")} (id bigserial PRIMARY KEY)"
      )

      migration_repo.query!("INSERT INTO #{table(prefix, "memory_summaries")} DEFAULT VALUES")
      load_migration("20260812000005_add_summary_source_completeness.exs")

      assert :ok =
               Ecto.Migrator.up(
                 migration_repo,
                 @summary_source_version,
                 @summary_source_migration,
                 prefix: prefix,
                 log: false
               )

      assert [[true, 0, %{"ranges" => []}]] =
               migration_repo.query!(
                 "SELECT source_complete, source_gap_count, source_gaps FROM #{table(prefix, "memory_summaries")}"
               ).rows

      assert_raise Postgrex.Error, fn ->
        migration_repo.query!(
          "UPDATE #{table(prefix, "memory_summaries")} SET source_gap_count = -1"
        )
      end

      assert :ok =
               Ecto.Migrator.down(
                 migration_repo,
                 @summary_source_version,
                 @summary_source_migration,
                 prefix: prefix,
                 log: false
               )

      refute column_exists?(migration_repo, prefix, "memory_summaries", "source_complete")
    end)
  end

  test "00021 creates constrained populated import batches and reverses inside its prefix" do
    prefix = unique_prefix("imports")
    migration_repo = start_migration_repo()

    with_schemas(migration_repo, [prefix], fn ->
      migration_repo.query!("CREATE TABLE #{table(prefix, "skill_hosts")} (id uuid PRIMARY KEY)")
      host_id = Ecto.UUID.dump!(Ecto.UUID.generate())

      migration_repo.query!("INSERT INTO #{table(prefix, "skill_hosts")} (id) VALUES ($1)", [
        host_id
      ])

      load_migration("20260812000021_create_memory_import_batches.exs")

      assert :ok =
               Ecto.Migrator.up(migration_repo, @imports_version, @imports_migration,
                 prefix: prefix,
                 log: false
               )

      migration_repo.query!(
        """
        INSERT INTO #{table(prefix, "memory_import_batches")}
          (id, host_id, integration, source_format, source_path_fingerprint, status,
           started_at, inserted_at, updated_at)
        VALUES ($1, $2, 'claude_code', 'jsonl', 'fingerprint', 'completed', now(), now(), now())
        """,
        [Ecto.UUID.dump!(Ecto.UUID.generate()), host_id]
      )

      assert_raise Postgrex.Error, fn ->
        migration_repo.query!(
          """
          INSERT INTO #{table(prefix, "memory_import_batches")}
            (id, host_id, integration, source_format, source_path_fingerprint, status,
             discovered_count, started_at, inserted_at, updated_at)
          VALUES ($1, $2, 'claude_code', 'jsonl', 'bad', 'started', -1, now(), now(), now())
          """,
          [Ecto.UUID.dump!(Ecto.UUID.generate()), host_id]
        )
      end

      assert :ok =
               Ecto.Migrator.down(migration_repo, @imports_version, @imports_migration,
                 prefix: prefix,
                 log: false
               )

      refute table_exists?(migration_repo, prefix, "memory_import_batches")
      assert table_exists?(migration_repo, prefix, "skill_hosts")
    end)
  end

  test "00022 aligns former defaults inside its prefix and preserves operator overrides" do
    prefix = unique_prefix("config_defaults")
    decoy = unique_prefix("config_defaults_decoy")
    migration_repo = start_migration_repo()

    with_schemas(migration_repo, [prefix, decoy], fn ->
      Enum.each([prefix, decoy], fn schema ->
        migration_repo.query!("""
        CREATE TABLE #{table(schema, "system_settings")} (
          key text PRIMARY KEY,
          value jsonb NOT NULL,
          description text
        )
        """)
      end)

      migration_repo.query!("""
      INSERT INTO #{table(prefix, "system_settings")} (key, value, description) VALUES
        ('memory.replay_import_max_files', '{"v":100}', 'old files default'),
        ('memory.replay_import_max_bytes', '{"v":555}', 'operator override')
      """)

      migration_repo.query!("""
      INSERT INTO #{table(decoy, "system_settings")} (key, value, description) VALUES
        ('memory.replay_import_max_files', '{"v":100}', 'decoy')
      """)

      load_migration("20260812000022_align_memory_v2_configuration_defaults.exs")

      assert :ok =
               Ecto.Migrator.up(
                 migration_repo,
                 @config_defaults_version,
                 @config_defaults_migration,
                 prefix: prefix,
                 log: false
               )

      assert [[%{"v" => 200}], [%{"v" => 555}]] =
               migration_repo.query!("""
               SELECT value FROM #{table(prefix, "system_settings")}
               ORDER BY key DESC
               """).rows

      assert [[%{"v" => 100}]] =
               migration_repo.query!("SELECT value FROM #{table(decoy, "system_settings")}").rows

      assert :ok =
               Ecto.Migrator.down(
                 migration_repo,
                 @config_defaults_version,
                 @config_defaults_migration,
                 prefix: prefix,
                 log: false
               )

      assert [[%{"v" => 100}], [%{"v" => 555}]] =
               migration_repo.query!("""
               SELECT value FROM #{table(prefix, "system_settings")}
               ORDER BY key DESC
               """).rows
    end)
  end

  defp insert_lesson(repo, prefix, memory_id, status) do
    repo.query!(
      """
      INSERT INTO #{table(prefix, "memory_lessons")}
        (memory_id, status, source_kind, created_at, updated_at)
      VALUES ($1, $2, 'manual', now(), now())
      """,
      [memory_id, status]
    )
  end

  defp create_lesson_parents(repo, prefix) do
    repo.query!("""
    CREATE TABLE #{table(prefix, "bpm_memories")} (
      id uuid PRIMARY KEY,
      memory_type text NOT NULL
    )
    """)

    repo.query!("""
    CREATE TABLE #{table(prefix, "bpm_memory_evidence")} (
      id bigserial PRIMARY KEY,
      memory_id uuid NOT NULL REFERENCES #{table(prefix, "bpm_memories")}(id) ON DELETE CASCADE
    )
    """)
  end

  defp load_migration(filename) do
    :backplane_system
    |> Application.app_dir("priv/repo/migrations/#{filename}")
    |> Code.require_file()
  end

  defp start_migration_repo do
    config =
      repo().config()
      |> Keyword.delete(:pool)
      |> Keyword.put(:pool_size, 2)

    start_supervised!({Backplane.Memory.M18MigrationMatrixTestRepo, config})
    Backplane.Memory.M18MigrationMatrixTestRepo
  end

  defp with_schemas(repo, prefixes, fun) do
    Enum.each(prefixes, &repo.query!("CREATE SCHEMA #{quote_identifier(&1)}"))

    try do
      fun.()
    after
      Enum.each(prefixes, &repo.query!("DROP SCHEMA IF EXISTS #{quote_identifier(&1)} CASCADE"))
    end
  end

  defp table_exists?(repo, prefix, name) do
    [[exists?]] =
      repo.query!("SELECT to_regclass($1) IS NOT NULL", ["#{prefix}.#{name}"]).rows

    exists?
  end

  defp index_exists?(repo, prefix, name) do
    [[exists?]] = repo.query!("SELECT to_regclass($1) IS NOT NULL", ["#{prefix}.#{name}"]).rows
    exists?
  end

  defp column_exists?(repo, prefix, table_name, column_name) do
    [[exists?]] =
      repo.query!(
        """
        SELECT EXISTS (
          SELECT 1 FROM information_schema.columns
          WHERE table_schema = $1 AND table_name = $2 AND column_name = $3
        )
        """,
        [prefix, table_name, column_name]
      ).rows

    exists?
  end

  defp function_exists?(repo, prefix, name) do
    function_count(repo, prefix, name) > 0
  end

  defp function_count(repo, prefix, name) do
    [[count]] =
      repo.query!(
        """
        SELECT count(*)
        FROM pg_proc AS function
        JOIN pg_namespace AS namespace ON namespace.oid = function.pronamespace
        WHERE namespace.nspname = $1 AND function.proname = $2
        """,
        [prefix, name]
      ).rows

    count
  end

  defp unique_prefix(label),
    do: "m18_#{label}_#{System.unique_integer([:positive])}"

  defp table(prefix, name),
    do: "#{quote_identifier(prefix)}.#{quote_identifier(name)}"

  defp quote_identifier(value),
    do: ~s("#{value |> to_string() |> String.replace("\"", "\"\"")}")
end

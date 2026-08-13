defmodule Backplane.Memory.SecurityPartitionMigrationTestRepo do
  use Ecto.Repo,
    otp_app: :backplane_system,
    adapter: Ecto.Adapters.Postgres
end

defmodule Backplane.Memory.SecurityPartitionMigrationsTest do
  use Backplane.Memory.DataCase, async: false
  import ExUnit.CaptureLog

  @derived_version 20_260_812_000_006
  @derived_migration Backplane.Repo.Migrations.PartitionMemoryDerivedModels
  @projected_version 20_260_812_000_007
  @projected_migration Backplane.Repo.Migrations.PartitionProjectedMemoryReadModels

  test "00006 derives profile identity from the canonical metadata project" do
    prefix = unique_prefix("derived_profile")
    migration_repo = start_migration_repo(prefix)
    migration_repo.query!("CREATE SCHEMA #{quote_identifier(prefix)}")

    try do
      create_derived_fixture_tables(migration_repo, prefix)

      partition = {"host-a", "client-a", "scope-a", "private"}
      insert_memory(migration_repo, prefix, "project-a", partition)
      insert_memory(migration_repo, prefix, "project-a", partition)

      migration_repo.query!("""
      INSERT INTO #{table(prefix, "memory_profiles")} (project)
      VALUES ('project-a')
      """)

      load_migration("20260812000006_partition_memory_derived_models.exs")

      assert :ok =
               Ecto.Migrator.up(migration_repo, @derived_version, @derived_migration,
                 prefix: prefix,
                 log: false
               )

      assert [["host-a", "client-a", "scope-a", "private"]] ==
               migration_repo.query!("""
               SELECT host_id, client_id, scope, namespace
               FROM #{table(prefix, "memory_profiles")}
               WHERE project = 'project-a'
               """).rows
    after
      migration_repo.query!("DROP SCHEMA IF EXISTS #{quote_identifier(prefix)} CASCADE")
      stop_supervised(Backplane.Memory.SecurityPartitionMigrationTestRepo)
    end
  end

  test "00006 isolates its prefix, reports denied legacy rows, and rejects rollback" do
    target = unique_prefix("derived_target")
    decoy = unique_prefix("derived_decoy")
    migration_repo = start_migration_repo(decoy)
    migration_repo.query!("CREATE SCHEMA #{quote_identifier(target)}")
    migration_repo.query!("CREATE SCHEMA #{quote_identifier(decoy)}")

    try do
      create_derived_fixture_tables(migration_repo, target)
      create_derived_fixture_tables(migration_repo, decoy)

      trusted = {"host-a", "client-a", "scope-a", "private"}
      foreign = {"host-b", "client-b", "scope-b", "private"}
      trusted_memory = insert_memory(migration_repo, target, "project-a", trusted)
      foreign_memory = insert_memory(migration_repo, target, "project-a", foreign)

      migration_repo.query!(
        "INSERT INTO #{table(target, "memory_profiles")} (project) VALUES ('project-a')"
      )

      migration_repo.query!(
        "INSERT INTO #{table(target, "memory_slots")} (name) VALUES ('persona')"
      )

      migration_repo.query!("INSERT INTO #{table(target, "memory_signals")} DEFAULT VALUES")

      safe_action = Ecto.UUID.generate()
      ambiguous_action = Ecto.UUID.generate()

      migration_repo.query!(
        """
        INSERT INTO #{table(target, "memory_actions")} (id, source_memory_ids)
        VALUES ($1, ARRAY[$2]::uuid[]), ($3, ARRAY[$2, $4]::uuid[])
        """,
        [
          Ecto.UUID.dump!(safe_action),
          Ecto.UUID.dump!(trusted_memory),
          Ecto.UUID.dump!(ambiguous_action),
          Ecto.UUID.dump!(foreign_memory)
        ]
      )

      migration_repo.query!(
        """
        INSERT INTO #{table(target, "memory_leases")} (action_id)
        VALUES ($1), ($2)
        """,
        [Ecto.UUID.dump!(safe_action), Ecto.UUID.dump!(ambiguous_action)]
      )

      source = Ecto.UUID.generate()
      target_node = Ecto.UUID.generate()

      migration_repo.query!(
        """
        INSERT INTO #{table(target, "memory_graph_nodes")} (id, type, name)
        VALUES ($1, 'concept', 'source'), ($2, 'concept', 'target')
        """,
        [Ecto.UUID.dump!(source), Ecto.UUID.dump!(target_node)]
      )

      migration_repo.query!(
        """
        INSERT INTO #{table(target, "memory_graph_edges")} (source_id, target_id, relation)
        VALUES ($1, $2, 'related')
        """,
        [Ecto.UUID.dump!(source), Ecto.UUID.dump!(target_node)]
      )

      load_migration("20260812000006_partition_memory_derived_models.exs")

      log =
        capture_log(fn ->
          assert :ok =
                   Ecto.Migrator.up(migration_repo, @derived_version, @derived_migration,
                     prefix: target,
                     log: false
                   )
        end)

      assert log =~ "table=memory_graph_nodes partitioned=0 denied=2"
      assert log =~ "table=memory_slots partitioned=0 denied=1"
      assert log =~ "table=memory_signals partitioned=0 denied=1"

      # The profile is ambiguous across two canonical memory partitions.
      assert [[nil, nil, nil, nil]] == partition_rows(migration_repo, target, "memory_profiles")

      assert [["host-a", "client-a", "scope-a", "private"], [nil, nil, nil, nil]] ==
               migration_repo.query!(
                 """
                 SELECT host_id, client_id, scope, namespace
                 FROM #{table(target, "memory_actions")}
                 ORDER BY id = $1 DESC
                 """,
                 [Ecto.UUID.dump!(safe_action)]
               ).rows

      assert [["host-a", "client-a", "scope-a", "private"], [nil, nil, nil, nil]] ==
               migration_repo.query!(
                 """
                 SELECT lease.host_id, lease.client_id, lease.scope, lease.namespace
                 FROM #{table(target, "memory_leases")} AS lease
                 ORDER BY lease.action_id = $1 DESC
                 """,
                 [Ecto.UUID.dump!(safe_action)]
               ).rows

      for legacy_table <- ~w(memory_graph_nodes memory_graph_edges memory_slots memory_signals) do
        assert Enum.all?(partition_rows(migration_repo, target, legacy_table), fn row ->
                 row == [nil, nil, nil, nil]
               end)
      end

      # An unrelated schema on the connection search path is untouched.
      refute column_exists?(migration_repo, decoy, "memory_profiles", "host_id")

      assert_raise Ecto.MigrationError, ~r/irreversible migration/, fn ->
        Ecto.Migrator.down(migration_repo, @derived_version, @derived_migration,
          prefix: target,
          log: false
        )
      end

      assert column_exists?(migration_repo, target, "memory_profiles", "host_id")
    after
      migration_repo.query!("DROP SCHEMA IF EXISTS #{quote_identifier(target)} CASCADE")
      migration_repo.query!("DROP SCHEMA IF EXISTS #{quote_identifier(decoy)} CASCADE")
      stop_supervised(Backplane.Memory.SecurityPartitionMigrationTestRepo)
    end
  end

  test "00007 partitions only attributable projections inside the migration prefix" do
    target = unique_prefix("projected_target")
    decoy = unique_prefix("projected_decoy")
    migration_repo = start_migration_repo(decoy)
    migration_repo.query!("CREATE SCHEMA #{quote_identifier(target)}")
    migration_repo.query!("CREATE SCHEMA #{quote_identifier(decoy)}")

    try do
      create_projected_fixture_tables(migration_repo, target)
      create_projected_fixture_tables(migration_repo, decoy)

      trusted_event = insert_event(migration_repo, target, "host-a", "session-a", "client-a")
      denied_event = insert_event(migration_repo, target, "host-b", "session-b", nil)

      insert_projected_observation(migration_repo, target, trusted_event, "host-a")
      insert_projected_observation(migration_repo, target, denied_event, "host-b")

      insert_projected_session(migration_repo, target, "subject-a", "host-a", "session-a")
      insert_projected_session(migration_repo, target, "subject-b", "host-b", "session-b")
      insert_event(migration_repo, target, "host-b", "session-b", "client-c")
      insert_event(migration_repo, target, "host-b", "session-b", "client-d")

      for subject <- ["subject-a", "subject-b"] do
        migration_repo.query!(
          """
          INSERT INTO #{table(target, "bpm_projection_snapshots")}
            (projector, subject_type, subject_id, read_model)
          VALUES ('session', 'captured_session', $1, '{}')
          """,
          [subject]
        )
      end

      load_migration("20260812000007_partition_projected_memory_read_models.exs")

      log =
        capture_log(fn ->
          assert :ok =
                   Ecto.Migrator.up(migration_repo, @projected_version, @projected_migration,
                     prefix: target,
                     log: false
                   )
        end)

      assert log =~
               "table=bpm_projected_observations partitioned=1 denied=1"

      assert log =~ "table=bpm_projected_sessions partitioned=1 denied=1"

      assert [
               ["host-a", "client-a", "scope-client-a", "private"],
               ["host-b", nil, nil, nil]
             ] ==
               migration_repo.query!("""
               SELECT host_id, client_id, scope, namespace
               FROM #{table(target, "bpm_projected_observations")}
               ORDER BY host_id
               """).rows

      assert [
               ["subject-a", "client-a", "scope-client-a", "private"],
               ["subject-b", nil, nil, nil]
             ] ==
               migration_repo.query!("""
               SELECT subject_id, client_id, scope, namespace
               FROM #{table(target, "bpm_projected_sessions")}
               ORDER BY subject_id
               """).rows

      assert [
               [
                 "subject-a",
                 %{
                   "client_id" => "client-a",
                   "namespace" => "private",
                   "scope" => "scope-client-a"
                 }
               ],
               ["subject-b", %{}]
             ] ==
               migration_repo.query!("""
               SELECT subject_id, read_model
               FROM #{table(target, "bpm_projection_snapshots")}
               ORDER BY subject_id
               """).rows

      refute column_exists?(
               migration_repo,
               decoy,
               "bpm_projected_observations",
               "client_id"
             )

      assert_raise Ecto.MigrationError, ~r/irreversible migration/, fn ->
        Ecto.Migrator.down(migration_repo, @projected_version, @projected_migration,
          prefix: target,
          log: false
        )
      end
    after
      migration_repo.query!("DROP SCHEMA IF EXISTS #{quote_identifier(target)} CASCADE")
      migration_repo.query!("DROP SCHEMA IF EXISTS #{quote_identifier(decoy)} CASCADE")
      stop_supervised(Backplane.Memory.SecurityPartitionMigrationTestRepo)
    end
  end

  defp create_derived_fixture_tables(repo, prefix) do
    repo.query!("""
    CREATE TABLE #{table(prefix, "memory_profiles")} (
      project text PRIMARY KEY,
      top_concepts jsonb NOT NULL DEFAULT '{}',
      top_files jsonb NOT NULL DEFAULT '{}',
      patterns jsonb NOT NULL DEFAULT '{}',
      session_count integer NOT NULL DEFAULT 0,
      total_observations integer NOT NULL DEFAULT 0,
      updated_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    repo.query!("""
    CREATE TABLE #{table(prefix, "bpm_memories")} (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      host_id text,
      client_id text,
      scope text,
      namespace text,
      metadata jsonb NOT NULL DEFAULT '{}'
    )
    """)

    repo.query!("""
    CREATE TABLE #{table(prefix, "memory_graph_nodes")} (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      type text NOT NULL,
      name text NOT NULL,
      properties jsonb NOT NULL DEFAULT '{}',
      source_observation_ids uuid[] NOT NULL DEFAULT '{}',
      created_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    repo.query!("""
    CREATE TABLE #{table(prefix, "memory_graph_edges")} (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      source_id uuid NOT NULL,
      target_id uuid NOT NULL,
      relation text NOT NULL,
      weight double precision NOT NULL DEFAULT 1.0,
      created_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    repo.query!("""
    CREATE TABLE #{table(prefix, "memory_slots")} (
      name text PRIMARY KEY,
      content text NOT NULL DEFAULT '',
      updated_at timestamptz NOT NULL DEFAULT now(),
      updated_by text,
      size_limit_chars integer NOT NULL DEFAULT 2000
    )
    """)

    repo.query!("""
    CREATE TABLE #{table(prefix, "memory_actions")} (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      source_memory_ids uuid[] NOT NULL DEFAULT '{}'
    )
    """)

    repo.query!("""
    CREATE TABLE #{table(prefix, "memory_leases")} (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      action_id uuid NOT NULL
    )
    """)

    repo.query!("""
    CREATE TABLE #{table(prefix, "memory_signals")} (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid()
    )
    """)
  end

  defp create_projected_fixture_tables(repo, prefix) do
    repo.query!("""
    CREATE TABLE #{table(prefix, "bpm_events")} (
      id uuid PRIMARY KEY,
      host_id text,
      session_id text,
      schema_version integer,
      client_id text,
      scope text,
      namespace text
    )
    """)

    repo.query!("""
    CREATE TABLE #{table(prefix, "bpm_projected_observations")} (
      event_id uuid PRIMARY KEY,
      subject_id text NOT NULL,
      host_id text NOT NULL,
      session_id text NOT NULL
    )
    """)

    repo.query!("""
    CREATE TABLE #{table(prefix, "bpm_projected_sessions")} (
      subject_id text PRIMARY KEY,
      host_id text NOT NULL,
      session_id text NOT NULL
    )
    """)

    repo.query!("""
    CREATE TABLE #{table(prefix, "bpm_projection_snapshots")} (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      projector text NOT NULL,
      subject_type text NOT NULL,
      subject_id text NOT NULL,
      read_model jsonb NOT NULL
    )
    """)
  end

  defp insert_event(repo, prefix, host_id, session_id, client_id) do
    event_id = Ecto.UUID.generate()

    repo.query!(
      """
      INSERT INTO #{table(prefix, "bpm_events")}
        (id, host_id, session_id, schema_version, client_id, scope, namespace)
      VALUES ($1, $2, $3, 1, $4, $5, $6)
      """,
      [
        Ecto.UUID.dump!(event_id),
        host_id,
        session_id,
        client_id,
        client_id && "scope-#{client_id}",
        client_id && "private"
      ]
    )

    event_id
  end

  defp insert_projected_observation(repo, prefix, event_id, host_id) do
    repo.query!(
      """
      INSERT INTO #{table(prefix, "bpm_projected_observations")}
        (event_id, subject_id, host_id, session_id)
      VALUES ($1, $2, $3, $4)
      """,
      [
        Ecto.UUID.dump!(event_id),
        "observation-#{host_id}",
        host_id,
        "session-#{String.last(host_id)}"
      ]
    )
  end

  defp insert_projected_session(repo, prefix, subject_id, host_id, session_id) do
    repo.query!(
      """
      INSERT INTO #{table(prefix, "bpm_projected_sessions")} (subject_id, host_id, session_id)
      VALUES ($1, $2, $3)
      """,
      [subject_id, host_id, session_id]
    )
  end

  defp insert_memory(repo, prefix, project, {host_id, client_id, scope, namespace}) do
    id = Ecto.UUID.generate()

    repo.query!(
      """
      INSERT INTO #{table(prefix, "bpm_memories")}
        (id, host_id, client_id, scope, namespace, metadata)
      VALUES ($1, $2, $3, $4, $5, jsonb_build_object('project', $6::text))
      """,
      [Ecto.UUID.dump!(id), host_id, client_id, scope, namespace, project]
    )

    id
  end

  defp partition_rows(repo, prefix, table_name) do
    repo.query!("""
    SELECT host_id, client_id, scope, namespace
    FROM #{table(prefix, table_name)}
    """).rows
  end

  defp column_exists?(repo, prefix, table_name, column_name) do
    [[exists?]] =
      repo.query!(
        """
        SELECT EXISTS (
          SELECT 1
          FROM information_schema.columns
          WHERE table_schema = $1 AND table_name = $2 AND column_name = $3
        )
        """,
        [prefix, table_name, column_name]
      ).rows

    exists?
  end

  defp load_migration(file) do
    :backplane_system
    |> Application.app_dir("priv/repo/migrations/#{file}")
    |> Code.require_file()
  end

  defp start_migration_repo(prefix) do
    config =
      repo().config()
      |> Keyword.delete(:pool)
      |> Keyword.put(:pool_size, 2)
      |> Keyword.put(:parameters, search_path: prefix)

    start_supervised!({Backplane.Memory.SecurityPartitionMigrationTestRepo, config})
    Backplane.Memory.SecurityPartitionMigrationTestRepo
  end

  defp unique_prefix(label),
    do: "#{label}_#{System.unique_integer([:positive])}"

  defp table(prefix, name), do: "#{quote_identifier(prefix)}.#{quote_identifier(name)}"
  defp quote_identifier(identifier), do: ~s("#{String.replace(identifier, ~s("), ~s(\"\"))}")
end

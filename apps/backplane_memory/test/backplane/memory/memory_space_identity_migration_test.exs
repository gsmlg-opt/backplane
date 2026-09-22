defmodule Backplane.Memory.MemorySpaceIdentityMigrationTestRepo do
  use Ecto.Repo,
    otp_app: :backplane_system,
    adapter: Ecto.Adapters.Postgres
end

defmodule Backplane.Memory.MemorySpaceIdentityMigrationTest do
  use Backplane.Memory.DataCase, async: false

  @columns_version 20_260_905_000_002
  @columns_migration Backplane.Repo.Migrations.AddMemorySpaceIdentity
  @backfill_version 20_260_905_000_003
  @backfill_migration Backplane.Repo.Migrations.BackfillMemorySpaceIdentity
  @action_edge_version 20_260_905_000_011
  @action_edge_migration Backplane.Repo.Migrations.OptimizeMemoryActionEdgePartitionGuard

  @roots [
    {"bpm_events", ~w(host_id client_id scope namespace)},
    {"bpm_streams", ~w(host_id client_id)},
    {"bpm_memories", ~w(host_id client_id scope namespace)},
    {"bpm_observations", []},
    {"memory_sessions", []},
    {"bpm_projected_observations", ~w(host_id client_id scope namespace)},
    {"bpm_projected_sessions", ~w(host_id client_id scope namespace)},
    {"memory_summaries", ~w(host_id)},
    {"memory_crystals", ~w(host_id client_id scope namespace)},
    {"memory_profiles", ~w(host_id client_id scope namespace)},
    {"memory_graph_nodes", ~w(host_id client_id scope namespace)},
    {"memory_graph_edges", ~w(host_id client_id scope namespace)},
    {"memory_activity_daily", ~w(host_id client_id scope namespace)},
    {"memory_activity_subject_contributions", ~w(host_id client_id scope namespace)},
    {"memory_replay_events", ~w(host_id client_id scope namespace)},
    {"memory_recall_runs", ~w(host_id client_id scope namespace)},
    {"memory_actions", ~w(host_id client_id scope namespace)},
    {"memory_leases", ~w(host_id client_id scope namespace)},
    {"memory_signals", ~w(host_id client_id scope namespace)},
    {"memory_slots", ~w(host_id client_id scope namespace)},
    {"memory_import_batches", ~w(host_id)},
    {"bpm_projection_states", []},
    {"bpm_projection_snapshots", []},
    {"bpm_host_memory_revocations", ~w(host_id scope)}
  ]

  test "action-edge guard upgrade checks exact parent partitions without scanning child rows" do
    prefix = "memory_action_edge_guard_#{System.unique_integer([:positive])}"
    migration_repo = start_migration_repo()

    with_isolated_schema(migration_repo, prefix, fn ->
      migration_repo.query!("""
      CREATE TABLE "#{prefix}".memory_actions (
        id uuid PRIMARY KEY, memory_space_id uuid, scope text, namespace text
      )
      """)

      migration_repo.query!("""
      CREATE TABLE "#{prefix}".memory_action_edges (
        id uuid PRIMARY KEY, source_id uuid NOT NULL, target_id uuid NOT NULL
      )
      """)

      migration_repo.query!("""
      CREATE FUNCTION "#{prefix}".bpm_assert_memory_action_edges_canonical_partition()
      RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NEW; END; $$
      """)

      migration_repo.query!("""
      CREATE CONSTRAINT TRIGGER bpm_memory_space_child_partition_guard
      AFTER INSERT OR UPDATE ON "#{prefix}".memory_action_edges
      DEFERRABLE INITIALLY IMMEDIATE FOR EACH ROW
      EXECUTE FUNCTION "#{prefix}".bpm_assert_memory_action_edges_canonical_partition()
      """)

      space_id = Ecto.UUID.generate()
      foreign_space_id = Ecto.UUID.generate()

      [source_id, target_id, foreign_id, missing_id] =
        Enum.map(1..4, fn _ -> Ecto.UUID.generate() end)

      for {id, space} <- [
            {source_id, space_id},
            {target_id, space_id},
            {foreign_id, foreign_space_id}
          ] do
        migration_repo.query!(
          ~s|INSERT INTO "#{prefix}".memory_actions VALUES ($1, $2, 'team', 'project')|,
          [Ecto.UUID.dump!(id), Ecto.UUID.dump!(space)]
        )
      end

      existing_edge_id = Ecto.UUID.generate()

      migration_repo.query!(
        ~s|INSERT INTO "#{prefix}".memory_action_edges VALUES ($1, $2, $3)|,
        [
          Ecto.UUID.dump!(existing_edge_id),
          Ecto.UUID.dump!(source_id),
          Ecto.UUID.dump!(target_id)
        ]
      )

      load_migration("20260905000011_optimize_memory_action_edge_partition_guard.exs")

      assert :ok =
               Ecto.Migrator.up(migration_repo, @action_edge_version, @action_edge_migration,
                 prefix: prefix,
                 log: false
               )

      assert [[trigger_definition, true, false]] =
               migration_repo.query!("""
               SELECT pg_get_triggerdef(oid), tgdeferrable, tginitdeferred
               FROM pg_trigger
               WHERE tgrelid = '"#{prefix}".memory_action_edges'::regclass
                 AND tgname = 'bpm_memory_space_child_partition_guard'
               """).rows

      assert trigger_definition =~ "AFTER INSERT OR UPDATE"
      assert trigger_definition =~ "DEFERRABLE INITIALLY IMMEDIATE"

      assert [[1]] =
               migration_repo.query!(
                 ~s|SELECT count(*) FROM "#{prefix}".memory_action_edges WHERE id = $1 AND source_id = $2 AND target_id = $3|,
                 [
                   Ecto.UUID.dump!(existing_edge_id),
                   Ecto.UUID.dump!(source_id),
                   Ecto.UUID.dump!(target_id)
                 ]
               ).rows

      edge_id = Ecto.UUID.generate()

      migration_repo.query!(
        ~s|INSERT INTO "#{prefix}".memory_action_edges VALUES ($1, $2, $3)|,
        [Ecto.UUID.dump!(edge_id), Ecto.UUID.dump!(source_id), Ecto.UUID.dump!(target_id)]
      )

      for {bad_source, bad_target} <- [
            {source_id, foreign_id},
            {foreign_id, target_id},
            {missing_id, target_id},
            {source_id, missing_id}
          ] do
        error =
          assert_raise Postgrex.Error, fn ->
            migration_repo.query!(
              ~s|INSERT INTO "#{prefix}".memory_action_edges VALUES ($1, $2, $3)|,
              [
                Ecto.UUID.dump!(Ecto.UUID.generate()),
                Ecto.UUID.dump!(bad_source),
                Ecto.UUID.dump!(bad_target)
              ]
            )
          end

        assert error.postgres.code == :check_violation
        assert error.postgres.constraint == "memory_action_edges_canonical_partition"
      end

      error =
        assert_raise Postgrex.Error, fn ->
          migration_repo.query!(
            ~s|UPDATE "#{prefix}".memory_action_edges SET target_id = $1 WHERE id = $2|,
            [Ecto.UUID.dump!(foreign_id), Ecto.UUID.dump!(edge_id)]
          )
        end

      assert error.postgres.constraint == "memory_action_edges_canonical_partition"
    end)
  end

  test "adds complete nullable physical identity with NOT VALID new-write enforcement in an isolated prefix" do
    prefix = "memory_space_identity_columns_#{System.unique_integer([:positive])}"
    migration_repo = start_migration_repo()

    with_isolated_schema(migration_repo, prefix, fn ->
      create_registry_tables(migration_repo, prefix)
      create_root_tables(migration_repo, prefix)
      load_migration("20260905000002_add_memory_space_identity.exs")

      assert :ok =
               Ecto.Migrator.up(migration_repo, @columns_version, @columns_migration,
                 prefix: prefix,
                 log: false
               )

      Enum.each(@roots, fn {table, _legacy_columns} ->
        columns =
          migration_repo.query!(
            """
            SELECT column_name, is_nullable
            FROM information_schema.columns
            WHERE table_schema = $1 AND table_name = $2
            """,
            [prefix, table]
          ).rows
          |> Map.new(fn [name, nullable] -> {name, nullable} end)

        assert columns["memory_space_id"] == "YES", table
        assert columns["host_id"] == "YES", table
        assert columns["source_client_id"] == "YES", table
        assert columns["scope"] == "YES", table
        assert columns["namespace"] == "YES", table

        constraints =
          migration_repo.query!(
            """
            SELECT conname, convalidated
            FROM pg_constraint
            WHERE conrelid = ($1 || '.' || $2)::regclass
              AND conname LIKE $2 || '_canonical_%'
            ORDER BY conname
            """,
            [prefix, table]
          ).rows

        assert length(constraints) == 3, table
        assert Enum.all?(constraints, fn [_name, validated] -> validated == false end), table

        assert_raise Postgrex.Error, fn ->
          migration_repo.query!(
            ~s|INSERT INTO "#{prefix}"."#{table}" (fixture_id) VALUES ('invalid')|
          )
        end

        space_id = Ecto.UUID.dump!(Ecto.UUID.generate())

        migration_repo.query!(
          ~s|INSERT INTO "#{prefix}".bpm_memory_spaces (id, kind, status) VALUES ($1, 'private', 'active')|,
          [space_id]
        )

        for missing <- ["scope", "namespace"] do
          present = if missing == "scope", do: "namespace", else: "scope"

          assert_raise Postgrex.Error, fn ->
            migration_repo.query!(
              ~s|INSERT INTO "#{prefix}"."#{table}" (fixture_id, memory_space_id, #{present}) VALUES ('missing-#{missing}', $1, 'default')|,
              [space_id]
            )
          end
        end

        migration_repo.query!(
          ~s|INSERT INTO "#{prefix}"."#{table}" (fixture_id, memory_space_id, scope, namespace) VALUES ('valid-owner', $1, 'scope:shared', 'default')|,
          [space_id]
        )

        for missing <- ["scope", "namespace"] do
          assert_raise Postgrex.Error, fn ->
            migration_repo.query!(
              ~s|UPDATE "#{prefix}"."#{table}" SET #{missing} = NULL WHERE fixture_id = 'valid-owner'|
            )
          end
        end
      end)
    end)
  end

  test "backfills only exact aliases, preserves scope and namespace, and records stable issues" do
    prefix = "memory_space_identity_backfill_#{System.unique_integer([:positive])}"
    migration_repo = start_migration_repo()

    with_isolated_schema(migration_repo, prefix, fn ->
      create_registry_tables(migration_repo, prefix)
      create_root_tables(migration_repo, prefix)

      fixtures = seed_registry(migration_repo, prefix)
      seeded_tables = seed_legacy_roots(migration_repo, prefix, fixtures)

      load_migration("20260905000002_add_memory_space_identity.exs")

      assert :ok =
               Ecto.Migrator.up(migration_repo, @columns_version, @columns_migration,
                 prefix: prefix,
                 log: false
               )

      Enum.each(seeded_tables, fn table ->
        migration_repo.query!(
          ~s|UPDATE "#{prefix}"."#{table}" SET memory_space_id = $1, scope = 'scope:shared', namespace = 'team:backend' WHERE fixture_id = 'mismatch'|,
          [Ecto.UUID.dump!(fixtures.wrong_space_id)]
        )
      end)

      load_migration("20260905000003_backfill_memory_space_identity.exs")

      assert :ok =
               Ecto.Migrator.up(migration_repo, @backfill_version, @backfill_migration,
                 prefix: prefix,
                 log: false
               )

      Enum.each(seeded_tables, fn table ->
        {_table, legacy_columns} = Enum.find(@roots, fn {root, _columns} -> root == table end)
        unresolved_scope = if "scope" in legacy_columns, do: "scope:shared"
        unresolved_namespace = if "namespace" in legacy_columns, do: "team:backend"

        actual =
          migration_repo.query!("""
          SELECT fixture_id, memory_space_id::text, scope, namespace, source_client_id
          FROM "#{prefix}"."#{table}"
          ORDER BY fixture_id
          """).rows

        assert {table, actual} ==
                 {table,
                  [
                    ["ambiguous", nil, unresolved_scope, unresolved_namespace, nil],
                    [
                      "mismatch",
                      fixtures.wrong_space_id,
                      "scope:shared",
                      "team:backend",
                      nil
                    ],
                    ["missing", nil, unresolved_scope, unresolved_namespace, nil],
                    ["trusted", fixtures.trusted_space_id, "scope:shared", "team:backend", nil]
                  ]}
      end)

      issues_before =
        migration_repo.query!("""
        SELECT id::text, source_table, source_id, reason, disposition, details
        FROM "#{prefix}".bpm_memory_space_backfill_issues
        ORDER BY source_table, source_id
        """).rows

      assert length(issues_before) == length(seeded_tables) * 3

      assert Enum.all?(issues_before, fn [_id, _table, _source_id, reason, "pending", _details] ->
               reason in ["ambiguous_partition", "missing_mapping", "partition_mismatch"]
             end)

      assert :ok = apply(@backfill_migration, :backfill, [migration_repo, prefix])

      assert issues_before ==
               migration_repo.query!("""
               SELECT id::text, source_table, source_id, reason, disposition, details
               FROM "#{prefix}".bpm_memory_space_backfill_issues
               ORDER BY source_table, source_id
               """).rows

      assert_raise Ecto.MigrationError, ~r/forward-only/, fn ->
        Ecto.Migrator.down(migration_repo, @backfill_version, @backfill_migration,
          prefix: prefix,
          log: false
        )
      end
    end)
  end

  test "inventories every child family plus audit and worker-specific pending jobs stably" do
    prefix = "memory_space_identity_inventory_#{System.unique_integer([:positive])}"
    migration_repo = start_migration_repo()

    with_isolated_schema(migration_repo, prefix, fn ->
      create_registry_tables(migration_repo, prefix)
      create_root_tables(migration_repo, prefix)
      fixtures = seed_registry(migration_repo, prefix)

      load_migration("20260905000002_add_memory_space_identity.exs")

      assert :ok =
               Ecto.Migrator.up(migration_repo, @columns_version, @columns_migration,
                 prefix: prefix,
                 log: false
               )

      parents = seed_canonical_parents(migration_repo, prefix, fixtures)
      create_child_inventory_tables(migration_repo, prefix)
      seed_child_inventory(migration_repo, prefix, parents)
      create_audit_and_jobs(migration_repo, prefix, fixtures, parents)

      load_migration("20260905000003_backfill_memory_space_identity.exs")

      assert :ok =
               Ecto.Migrator.up(migration_repo, @backfill_version, @backfill_migration,
                 prefix: prefix,
                 log: false
               )

      child_sources =
        migration_repo.query!("""
        SELECT source_table, disposition
        FROM "#{prefix}".bpm_memory_space_backfill_issues
        WHERE reason = 'child_partition_mismatch'
        ORDER BY source_table
        """).rows

      assert Enum.map(child_sources, &hd/1) ==
               ~w(
                 bpm_memory_evidence
                 bpm_memory_relation_evidence
                 bpm_memory_relations
                 bpm_memory_remember_requests
                 memory_action_edges
                 memory_crystal_lessons
                 memory_crystal_source_actions
                 memory_crystal_source_events
                 memory_crystal_source_summaries
                 memory_facets
                 memory_lessons
                 memory_recall_candidates
                 memory_summary_source_events
               )

      assert Enum.all?(child_sources, fn [_table, disposition] -> disposition == "pending" end)

      assert [[13]] =
               migration_repo.query!("""
               SELECT count(*)
               FROM pg_trigger AS trigger
               JOIN pg_class AS relation ON relation.oid = trigger.tgrelid
               JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
               WHERE namespace.nspname = '#{prefix}'
                 AND trigger.tgname = 'bpm_memory_space_child_partition_guard'
                 AND NOT trigger.tgisinternal
               """).rows

      migration_repo.query!(
        ~s|INSERT INTO "#{prefix}".memory_facets VALUES ($1, 'ongoing-valid')|,
        [Ecto.UUID.dump!(parents.memory)]
      )

      assert_raise Postgrex.Error, ~r/crosses canonical memory partition/, fn ->
        migration_repo.query!(
          ~s|INSERT INTO "#{prefix}".memory_facets VALUES ($1, 'ongoing-invalid')|,
          [Ecto.UUID.dump!(Ecto.UUID.generate())]
        )
      end

      assert [["memory_audit_log", "audit_partition_unresolved", "pending"]] =
               inventory_issues(migration_repo, prefix, "memory_audit_log")

      assert [
               ["oban_jobs", "job_partition_unresolved", "pending"],
               ["oban_jobs", "job_partition_unresolved", "pending"]
             ] = inventory_issues(migration_repo, prefix, "oban_jobs")

      stable_before = issue_identities(migration_repo, prefix)
      assert :ok = apply(@backfill_migration, :backfill, [migration_repo, prefix])
      assert stable_before == issue_identities(migration_repo, prefix)

      migration_repo.query!("""
      UPDATE "#{prefix}".bpm_memory_space_backfill_issues
      SET disposition = 'approved_waiver'
      WHERE source_table = 'memory_summary_source_events'
      """)

      assert :ok = apply(@backfill_migration, :backfill, [migration_repo, prefix])

      assert [["approved_waiver"]] =
               migration_repo.query!("""
               SELECT disposition
               FROM "#{prefix}".bpm_memory_space_backfill_issues
               WHERE source_table = 'memory_summary_source_events'
               """).rows

      migration_repo.query!("""
      UPDATE "#{prefix}".memory_audit_log
      SET metadata = jsonb_build_object(
        'memory_space_id', '#{fixtures.trusted_space_id}',
        'scope', 'scope:shared',
        'namespace', 'team:backend'
      )
      WHERE id = '#{parents.invalid_audit_id}'
      """)

      migration_repo.query!("""
      UPDATE "#{prefix}".oban_jobs
      SET state = 'completed'
      WHERE id IN (#{Enum.join(parents.invalid_job_ids, ", ")})
      """)

      assert :ok = apply(@backfill_migration, :backfill, [migration_repo, prefix])

      assert Enum.all?(
               inventory_issues(migration_repo, prefix, "memory_audit_log") ++
                 inventory_issues(migration_repo, prefix, "oban_jobs"),
               fn [_table, _reason, disposition] -> disposition == "resolved" end
             )
    end)
  end

  test "derives ownerless projection roots only through one exact parent" do
    prefix = "memory_space_identity_inheritance_#{System.unique_integer([:positive])}"
    migration_repo = start_migration_repo()

    with_isolated_schema(migration_repo, prefix, fn ->
      create_registry_tables(migration_repo, prefix)
      create_root_tables(migration_repo, prefix)
      fixtures = seed_registry(migration_repo, prefix)

      migration_repo.query!(
        """
        INSERT INTO "#{prefix}".bpm_projected_sessions
          (fixture_id, host_id, client_id, scope, namespace, subject_id, session_id)
        VALUES ('parent-session', $1, 'trusted-client', 'scope:shared', 'team:backend',
                'subject-session', 'session-trusted')
        """,
        [fixtures.trusted_host_id]
      )

      migration_repo.query!(
        """
        INSERT INTO "#{prefix}".bpm_projected_observations
          (fixture_id, host_id, client_id, scope, namespace, subject_id)
        VALUES ('parent-observation', $1, 'trusted-client', 'scope:shared', 'team:backend',
                'subject-observation')
        """,
        [fixtures.trusted_host_id]
      )

      for statement <- [
            ~s|INSERT INTO "#{prefix}".memory_sessions (fixture_id, session_id) VALUES ('inherited', 'session-trusted'), ('orphan', 'session-orphan')|,
            ~s|INSERT INTO "#{prefix}".bpm_observations (fixture_id, session_id) VALUES ('inherited', 'session-trusted'), ('orphan', 'session-orphan')|,
            ~s|INSERT INTO "#{prefix}".bpm_projection_states (fixture_id, subject_id) VALUES ('inherited', 'subject-session'), ('orphan', 'subject-orphan')|,
            ~s|INSERT INTO "#{prefix}".bpm_projection_snapshots (fixture_id, subject_id) VALUES ('inherited', 'subject-observation'), ('orphan', 'subject-orphan')|
          ] do
        migration_repo.query!(statement)
      end

      load_migration("20260905000002_add_memory_space_identity.exs")
      load_migration("20260905000003_backfill_memory_space_identity.exs")

      assert :ok =
               Ecto.Migrator.up(migration_repo, @columns_version, @columns_migration,
                 prefix: prefix,
                 log: false
               )

      assert :ok =
               Ecto.Migrator.up(migration_repo, @backfill_version, @backfill_migration,
                 prefix: prefix,
                 log: false
               )

      trusted_space_id = fixtures.trusted_space_id

      for table <-
            ~w(memory_sessions bpm_observations bpm_projection_states bpm_projection_snapshots) do
        assert [["inherited", ^trusted_space_id, "scope:shared", "team:backend"]] =
                 migration_repo.query!("""
                 SELECT fixture_id, memory_space_id::text, scope, namespace
                 FROM "#{prefix}"."#{table}"
                 WHERE fixture_id = 'inherited'
                 """).rows

        assert [[^table, "missing_mapping", "pending"]] =
                 migration_repo.query!(
                   """
                   SELECT source_table, reason, disposition
                   FROM "#{prefix}".bpm_memory_space_backfill_issues
                   WHERE source_table = $1
                     AND details ->> 'memory_space_id' IS NULL
                     AND disposition = 'pending'
                   """,
                   [table]
                 ).rows
      end
    end)
  end

  defp create_registry_tables(repo, prefix) do
    repo.query!("""
    CREATE TABLE "#{prefix}".bpm_memory_spaces (
      id uuid PRIMARY KEY,
      kind text NOT NULL,
      status text NOT NULL
    )
    """)

    repo.query!("""
    CREATE TABLE "#{prefix}".bpm_memory_space_legacy_aliases (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      alias_type text NOT NULL,
      alias_value text NOT NULL,
      memory_space_id uuid NOT NULL
    )
    """)

    repo.query!("""
    CREATE TABLE "#{prefix}".bpm_memory_space_entitlements (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      memory_space_id uuid NOT NULL,
      host_id uuid NOT NULL,
      scope text NOT NULL,
      namespace text NOT NULL,
      default_capture boolean NOT NULL,
      status text NOT NULL
    )
    """)

    repo.query!("""
    CREATE TABLE "#{prefix}".bpm_memory_space_backfill_issues (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      source_table text NOT NULL,
      source_id text NOT NULL,
      reason text NOT NULL,
      disposition text NOT NULL DEFAULT 'pending',
      details jsonb NOT NULL DEFAULT '{}'::jsonb,
      resolved_at timestamptz,
      inserted_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now(),
      UNIQUE (source_table, source_id)
    )
    """)
  end

  defp create_root_tables(repo, prefix) do
    Enum.each(@roots, fn {table, legacy_columns} ->
      columns =
        legacy_columns
        |> Enum.map(fn
          "host_id" when table == "memory_import_batches" -> "host_id uuid"
          name -> ~s|"#{name}" text|
        end)
        |> then(fn columns ->
          ["fixture_id text PRIMARY KEY" | columns ++ extra_root_columns(table)]
        end)
        |> Enum.join(", ")

      repo.query!(~s|CREATE TABLE "#{prefix}"."#{table}" (#{columns})|)
    end)
  end

  defp extra_root_columns(table) do
    case table do
      "bpm_events" ->
        ["id uuid UNIQUE DEFAULT gen_random_uuid()"]

      "bpm_memories" ->
        ["id uuid UNIQUE DEFAULT gen_random_uuid()"]

      "bpm_observations" ->
        ["id uuid UNIQUE DEFAULT gen_random_uuid()", "session_id text"]

      "memory_sessions" ->
        ["session_id text"]

      "bpm_projected_observations" ->
        ["id uuid UNIQUE DEFAULT gen_random_uuid()", "subject_id text"]

      "bpm_projected_sessions" ->
        ["subject_id text", "session_id text"]

      "memory_summaries" ->
        ["id uuid UNIQUE DEFAULT gen_random_uuid()"]

      "memory_crystals" ->
        ["id uuid UNIQUE DEFAULT gen_random_uuid()"]

      "memory_actions" ->
        ["id uuid UNIQUE DEFAULT gen_random_uuid()"]

      "memory_recall_runs" ->
        ["id uuid UNIQUE DEFAULT gen_random_uuid()"]

      "bpm_projection_states" ->
        ["subject_id text"]

      "bpm_projection_snapshots" ->
        ["subject_id text"]

      _other ->
        []
    end
  end

  defp seed_registry(repo, prefix) do
    trusted_host_id = Ecto.UUID.generate()
    ambiguous_host_id = Ecto.UUID.generate()
    missing_host_id = Ecto.UUID.generate()
    trusted_space_id = Ecto.UUID.generate()
    ambiguous_space_a_id = Ecto.UUID.generate()
    ambiguous_space_b_id = Ecto.UUID.generate()
    wrong_space_id = Ecto.UUID.generate()

    for space_id <- [
          trusted_space_id,
          ambiguous_space_a_id,
          ambiguous_space_b_id,
          wrong_space_id
        ] do
      repo.query!(
        ~s|INSERT INTO "#{prefix}".bpm_memory_spaces (id, kind, status) VALUES ($1, 'private', 'active')|,
        [Ecto.UUID.dump!(space_id)]
      )
    end

    insert_alias(repo, prefix, trusted_host_id, trusted_space_id)
    insert_entitlement(repo, prefix, trusted_host_id, trusted_space_id)
    insert_alias(repo, prefix, ambiguous_host_id, ambiguous_space_a_id)
    insert_alias(repo, prefix, ambiguous_host_id, ambiguous_space_b_id)
    insert_entitlement(repo, prefix, ambiguous_host_id, ambiguous_space_a_id)
    insert_entitlement(repo, prefix, ambiguous_host_id, ambiguous_space_b_id)

    %{
      trusted_host_id: trusted_host_id,
      ambiguous_host_id: ambiguous_host_id,
      missing_host_id: missing_host_id,
      trusted_space_id: trusted_space_id,
      wrong_space_id: wrong_space_id
    }
  end

  defp insert_alias(repo, prefix, host_id, space_id) do
    repo.query!(
      """
      INSERT INTO "#{prefix}".bpm_memory_space_legacy_aliases
        (alias_type, alias_value, memory_space_id)
      VALUES ('host', $1, $2)
      """,
      ["host:#{host_id}", Ecto.UUID.dump!(space_id)]
    )
  end

  defp insert_entitlement(repo, prefix, host_id, space_id) do
    repo.query!(
      """
      INSERT INTO "#{prefix}".bpm_memory_space_entitlements
        (memory_space_id, host_id, scope, namespace, default_capture, status)
      VALUES ($1, $2, 'scope:shared', 'team:backend', true, 'active')
      """,
      [Ecto.UUID.dump!(space_id), Ecto.UUID.dump!(host_id)]
    )
  end

  defp seed_legacy_roots(repo, prefix, fixtures) do
    @roots
    |> Enum.filter(fn {_table, columns} -> "host_id" in columns end)
    |> Enum.map(fn {table, columns} ->
      for {fixture_id, host_id} <- [
            {"trusted", fixtures.trusted_host_id},
            {"missing", fixtures.missing_host_id},
            {"ambiguous", fixtures.ambiguous_host_id},
            {"mismatch", fixtures.trusted_host_id}
          ] do
        {column_names, values, placeholders} =
          columns
          |> Enum.reduce({["fixture_id"], [fixture_id], ["$1"]}, fn column,
                                                                    {names, values, placeholders} ->
            value =
              case column do
                "host_id" when table == "memory_import_batches" -> Ecto.UUID.dump!(host_id)
                "host_id" -> host_id
                "client_id" -> "host:#{host_id}"
                "scope" -> "scope:shared"
                "namespace" -> "team:backend"
              end

            next = length(values) + 1
            {names ++ [column], values ++ [value], placeholders ++ ["$#{next}"]}
          end)

        repo.query!(
          ~s|INSERT INTO "#{prefix}"."#{table}" (#{Enum.join(column_names, ", ")}) VALUES (#{Enum.join(placeholders, ", ")})|,
          values
        )
      end

      table
    end)
  end

  defp seed_canonical_parents(repo, prefix, fixtures) do
    trusted = %{
      memory: Ecto.UUID.generate(),
      second_memory: Ecto.UUID.generate(),
      event: Ecto.UUID.generate(),
      observation: Ecto.UUID.generate(),
      summary: Ecto.UUID.generate(),
      crystal: Ecto.UUID.generate(),
      action: Ecto.UUID.generate(),
      recall_run: Ecto.UUID.generate()
    }

    foreign = %{
      memory: Ecto.UUID.generate(),
      event: Ecto.UUID.generate(),
      summary: Ecto.UUID.generate(),
      action: Ecto.UUID.generate()
    }

    for {table, rows} <- [
          {"bpm_memories",
           [
             {"trusted-memory", trusted.memory, fixtures.trusted_space_id},
             {"trusted-memory-2", trusted.second_memory, fixtures.trusted_space_id},
             {"foreign-memory", foreign.memory, fixtures.wrong_space_id}
           ]},
          {"bpm_events",
           [
             {"trusted-event", trusted.event, fixtures.trusted_space_id},
             {"foreign-event", foreign.event, fixtures.wrong_space_id}
           ]},
          {"memory_summaries",
           [
             {"trusted-summary", trusted.summary, fixtures.trusted_space_id},
             {"foreign-summary", foreign.summary, fixtures.wrong_space_id}
           ]},
          {"memory_actions",
           [
             {"trusted-action", trusted.action, fixtures.trusted_space_id},
             {"foreign-action", foreign.action, fixtures.wrong_space_id}
           ]},
          {"bpm_observations",
           [{"trusted-observation", trusted.observation, fixtures.trusted_space_id}]},
          {"memory_crystals", [{"trusted-crystal", trusted.crystal, fixtures.trusted_space_id}]},
          {"memory_recall_runs",
           [{"trusted-recall", trusted.recall_run, fixtures.trusted_space_id}]}
        ] do
      Enum.each(rows, fn {fixture_id, id, memory_space_id} ->
        columns =
          if table in ["memory_summaries", "bpm_observations"] do
            "fixture_id, id, memory_space_id, host_id, source_client_id, scope, namespace"
          else
            "fixture_id, id, memory_space_id, host_id, client_id, source_client_id, scope, namespace"
          end

        placeholders =
          if table in ["memory_summaries", "bpm_observations"] do
            "$1, $2, $3, $4, $5, 'scope:shared', 'team:backend'"
          else
            "$1, $2, $3, $4, $5, $5, 'scope:shared', 'team:backend'"
          end

        repo.query!(
          ~s|INSERT INTO "#{prefix}"."#{table}" (#{columns}) VALUES (#{placeholders})|,
          [
            fixture_id,
            Ecto.UUID.dump!(id),
            Ecto.UUID.dump!(memory_space_id),
            fixtures.trusted_host_id,
            "trusted-client"
          ]
        )
      end)
    end

    Map.merge(trusted, %{
      foreign: foreign,
      host_id: fixtures.trusted_host_id,
      invalid_audit_id: Ecto.UUID.generate(),
      invalid_job_ids: [7, 8]
    })
  end

  defp create_child_inventory_tables(repo, prefix) do
    statements = [
      ~s|CREATE TABLE "#{prefix}".bpm_memory_remember_requests (fixture_id text PRIMARY KEY, id uuid UNIQUE DEFAULT gen_random_uuid(), memory_id uuid)|,
      ~s|CREATE TABLE "#{prefix}".bpm_memory_evidence (fixture_id text PRIMARY KEY, id uuid UNIQUE DEFAULT gen_random_uuid(), memory_id uuid, source_event_id uuid, source_observation_id uuid, source_summary_id uuid, source_request_id uuid, source_crystal_id uuid, source_session_id text, host_id text)|,
      ~s|CREATE TABLE "#{prefix}".bpm_memory_relations (fixture_id text UNIQUE, id uuid PRIMARY KEY DEFAULT gen_random_uuid(), source_memory_id uuid, target_memory_id uuid)|,
      ~s|CREATE TABLE "#{prefix}".bpm_memory_relation_evidence (relation_id uuid, evidence_id uuid, PRIMARY KEY (relation_id, evidence_id))|,
      ~s|CREATE TABLE "#{prefix}".memory_lessons (fixture_id text PRIMARY KEY, memory_id uuid)|,
      ~s|CREATE TABLE "#{prefix}".memory_crystal_source_events (crystal_id uuid, event_id uuid, PRIMARY KEY (crystal_id, event_id))|,
      ~s|CREATE TABLE "#{prefix}".memory_crystal_source_summaries (crystal_id uuid, summary_id uuid, PRIMARY KEY (crystal_id, summary_id))|,
      ~s|CREATE TABLE "#{prefix}".memory_crystal_source_actions (crystal_id uuid, action_id uuid, PRIMARY KEY (crystal_id, action_id))|,
      ~s|CREATE TABLE "#{prefix}".memory_crystal_lessons (crystal_id uuid, lesson_memory_id uuid, PRIMARY KEY (crystal_id, lesson_memory_id))|,
      ~s|CREATE TABLE "#{prefix}".memory_summary_source_events (summary_id uuid, event_id uuid, host_id text, UNIQUE (summary_id, event_id))|,
      ~s|CREATE TABLE "#{prefix}".memory_action_edges (source_id uuid, target_id uuid, PRIMARY KEY (source_id, target_id))|,
      ~s|CREATE TABLE "#{prefix}".memory_facets (memory_id uuid, dimension text, PRIMARY KEY (memory_id, dimension))|,
      ~s|CREATE TABLE "#{prefix}".memory_recall_candidates (recall_run_id uuid, candidate_id uuid, candidate_kind text, PRIMARY KEY (recall_run_id, candidate_id, candidate_kind))|
    ]

    Enum.each(statements, &repo.query!/1)
  end

  defp seed_child_inventory(repo, prefix, parents) do
    missing_id = Ecto.UUID.generate()

    repo.query!(
      ~s|INSERT INTO "#{prefix}".bpm_memory_remember_requests (fixture_id, memory_id) VALUES ('valid', $1), ('invalid', $2)|,
      [Ecto.UUID.dump!(parents.memory), Ecto.UUID.dump!(missing_id)]
    )

    repo.query!(
      ~s|INSERT INTO "#{prefix}".bpm_memory_evidence (fixture_id, memory_id, source_event_id, host_id) VALUES ('valid', $1, $2, $3), ('invalid', $1, $4, $3), ('foreign-owner', $5, $4, $3)|,
      [
        Ecto.UUID.dump!(parents.memory),
        Ecto.UUID.dump!(parents.event),
        parents.host_id,
        Ecto.UUID.dump!(parents.foreign.event),
        Ecto.UUID.dump!(parents.foreign.memory)
      ]
    )

    relation_ids = [Ecto.UUID.generate(), Ecto.UUID.generate()]

    repo.query!(
      ~s|INSERT INTO "#{prefix}".bpm_memory_relations (fixture_id, id, source_memory_id, target_memory_id) VALUES ('valid', $1, $3, $4), ('invalid', $2, $3, $5)|,
      [
        Ecto.UUID.dump!(Enum.at(relation_ids, 0)),
        Ecto.UUID.dump!(Enum.at(relation_ids, 1)),
        Ecto.UUID.dump!(parents.memory),
        Ecto.UUID.dump!(parents.second_memory),
        Ecto.UUID.dump!(parents.foreign.memory)
      ]
    )

    evidence_ids = child_ids(repo, prefix, "bpm_memory_evidence")

    repo.query!(
      ~s|INSERT INTO "#{prefix}".bpm_memory_relation_evidence VALUES ($1, $2), ($1, $3)|,
      [
        Ecto.UUID.dump!(Enum.at(relation_ids, 0)),
        Ecto.UUID.dump!(evidence_ids["valid"]),
        Ecto.UUID.dump!(evidence_ids["foreign-owner"])
      ]
    )

    repo.query!(
      ~s|INSERT INTO "#{prefix}".memory_lessons VALUES ('valid', $1), ('invalid', $2)|,
      [
        Ecto.UUID.dump!(parents.memory),
        Ecto.UUID.dump!(missing_id)
      ]
    )

    for {table, valid_id, invalid_id} <- [
          {"memory_crystal_source_events", parents.event, parents.foreign.event},
          {"memory_crystal_source_summaries", parents.summary, parents.foreign.summary},
          {"memory_crystal_source_actions", parents.action, parents.foreign.action},
          {"memory_crystal_lessons", parents.memory, parents.foreign.memory}
        ] do
      repo.query!(~s|INSERT INTO "#{prefix}"."#{table}" VALUES ($1, $2), ($1, $3)|, [
        Ecto.UUID.dump!(parents.crystal),
        Ecto.UUID.dump!(valid_id),
        Ecto.UUID.dump!(invalid_id)
      ])
    end

    repo.query!(
      ~s|INSERT INTO "#{prefix}".memory_summary_source_events VALUES ($1, $2, $3), ($1, $4, $3)|,
      [
        Ecto.UUID.dump!(parents.summary),
        Ecto.UUID.dump!(parents.event),
        parents.host_id,
        Ecto.UUID.dump!(parents.foreign.event)
      ]
    )

    repo.query!(~s|INSERT INTO "#{prefix}".memory_action_edges VALUES ($1, $2), ($1, $3)|, [
      Ecto.UUID.dump!(parents.action),
      Ecto.UUID.dump!(parents.action),
      Ecto.UUID.dump!(parents.foreign.action)
    ])

    repo.query!(~s|INSERT INTO "#{prefix}".memory_facets VALUES ($1, 'valid'), ($2, 'invalid')|, [
      Ecto.UUID.dump!(parents.memory),
      Ecto.UUID.dump!(missing_id)
    ])

    repo.query!(
      ~s|INSERT INTO "#{prefix}".memory_recall_candidates VALUES ($1, $2, 'memory'), ($1, $3, 'memory')|,
      [
        Ecto.UUID.dump!(parents.recall_run),
        Ecto.UUID.dump!(parents.memory),
        Ecto.UUID.dump!(parents.foreign.memory)
      ]
    )
  end

  defp create_audit_and_jobs(repo, prefix, fixtures, parents) do
    repo.query!("""
    CREATE TABLE "#{prefix}".memory_audit_log (
      id uuid PRIMARY KEY,
      operation text NOT NULL,
      target_ids jsonb NOT NULL,
      metadata jsonb NOT NULL
    )
    """)

    repo.query!("""
    INSERT INTO "#{prefix}".memory_audit_log VALUES
      (gen_random_uuid(), 'remember', jsonb_build_array('#{parents.memory}'), '{}'::jsonb),
      ('#{parents.invalid_audit_id}', 'hard_delete', jsonb_build_array('#{Ecto.UUID.generate()}'), '{}'::jsonb),
      (gen_random_uuid(), 'privacy.contract', '[]'::jsonb, '{}'::jsonb),
      (gen_random_uuid(), 'crystal.crystallize', '[]'::jsonb,
       jsonb_build_object('memory_space_id', '#{fixtures.trusted_space_id}', 'scope', 'scope:shared', 'namespace', 'team:backend'))
    """)

    repo.query!("""
    CREATE TABLE "#{prefix}".oban_jobs (
      id bigint PRIMARY KEY,
      worker text NOT NULL,
      state text NOT NULL,
      args jsonb NOT NULL
    )
    """)

    repo.query!("""
    INSERT INTO "#{prefix}".oban_jobs VALUES
      (1, 'Elixir.Backplane.Memory.Workers.ProceduralWorker', 'available', '{}'::jsonb),
      (2, 'Elixir.Backplane.Memory.Workers.EmbedWorker', 'available', jsonb_build_object('id', '#{parents.memory}')),
      (3, 'Elixir.Backplane.Memory.Workers.ProjectionRepairWorker', 'available', jsonb_build_object('event_id', '#{parents.event}')),
      (4, 'Elixir.Backplane.Memory.Workers.RelationClassifierWorker', 'available', jsonb_build_object('memory_id', '#{parents.memory}', 'partition', jsonb_build_object('memory_space_id', '#{fixtures.trusted_space_id}', 'scope', 'scope:shared', 'namespace', 'team:backend'))),
      (5, 'Elixir.Backplane.Memory.Workers.SummaryWorker', 'available', jsonb_build_object('memory_space_id', '#{fixtures.trusted_space_id}', 'scope', 'scope:shared', 'namespace', 'team:backend')),
      (6, 'Elixir.Backplane.Memory.Workers.EmbedWorker', 'completed', '{}'::jsonb),
      (7, 'Elixir.Backplane.Memory.Workers.EmbedWorker', 'available', jsonb_build_object('id', '#{Ecto.UUID.generate()}')),
      (8, 'Elixir.Backplane.Memory.Workers.SummaryWorker', 'retryable', '{}'::jsonb)
    """)
  end

  defp child_ids(repo, prefix, table) do
    repo.query!(~s|SELECT fixture_id, id::text FROM "#{prefix}"."#{table}"|).rows
    |> Map.new(fn [fixture_id, id] -> {fixture_id, id} end)
  end

  defp inventory_issues(repo, prefix, source_table) do
    repo.query!(
      """
      SELECT source_table, reason, disposition
      FROM "#{prefix}".bpm_memory_space_backfill_issues
      WHERE source_table = $1
      ORDER BY source_id
      """,
      [source_table]
    ).rows
  end

  defp issue_identities(repo, prefix) do
    repo.query!("""
    SELECT id::text, source_table, source_id
    FROM "#{prefix}".bpm_memory_space_backfill_issues
    ORDER BY source_table, source_id
    """).rows
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

    start_supervised!({Backplane.Memory.MemorySpaceIdentityMigrationTestRepo, config})
    Backplane.Memory.MemorySpaceIdentityMigrationTestRepo
  end

  defp with_isolated_schema(migration_repo, prefix, fun) do
    migration_repo.query!(~s|CREATE SCHEMA "#{prefix}"|)

    try do
      fun.()
    after
      migration_repo.query!(~s|DROP SCHEMA IF EXISTS "#{prefix}" CASCADE|)
    end
  end
end

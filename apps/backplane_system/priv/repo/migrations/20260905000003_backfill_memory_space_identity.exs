defmodule Backplane.Repo.Migrations.BackfillMemorySpaceIdentity do
  use Ecto.Migration

  @roots ~w(
    bpm_events
    bpm_streams
    bpm_memories
    bpm_observations
    memory_sessions
    bpm_projected_observations
    bpm_projected_sessions
    memory_summaries
    memory_crystals
    memory_profiles
    memory_graph_nodes
    memory_graph_edges
    memory_activity_daily
    memory_activity_subject_contributions
    memory_replay_events
    memory_recall_runs
    memory_actions
    memory_leases
    memory_signals
    memory_slots
    memory_import_batches
    bpm_projection_states
    bpm_projection_snapshots
    bpm_host_memory_revocations
  )

  @immutable_root_triggers [
    {"bpm_events", "bpm_events_captured_immutable"},
    {"memory_replay_events", "memory_replay_immutable_row"},
    {"bpm_host_memory_revocations", "bpm_host_memory_revocations_immutable_row"}
  ]

  @children [
    {"bpm_memory_remember_requests",
     "LEFT JOIN %MEMORIES% AS owner ON owner.id = child.memory_id",
     "%MATCH%(to_jsonb(owner), to_jsonb(owner))", "owner"},
    {"bpm_memory_evidence",
     "LEFT JOIN %MEMORIES% AS owner ON owner.id = child.memory_id LEFT JOIN %EVENTS% AS source_event ON source_event.id = child.source_event_id LEFT JOIN %OBSERVATIONS% AS source_observation ON source_observation.id = child.source_observation_id LEFT JOIN %SUMMARIES% AS source_summary ON source_summary.id = child.source_summary_id LEFT JOIN %REMEMBER_REQUESTS% AS source_request ON source_request.id = child.source_request_id LEFT JOIN %MEMORIES% AS request_owner ON request_owner.id = source_request.memory_id LEFT JOIN %CRYSTALS% AS source_crystal ON source_crystal.id = child.source_crystal_id LEFT JOIN %PROJECTED_SESSIONS% AS source_session ON source_session.host_id = child.host_id AND source_session.session_id = child.source_session_id",
     "%MATCH%(to_jsonb(owner), to_jsonb(owner)) AND child.host_id IS NOT DISTINCT FROM owner.host_id AND (child.source_event_id IS NULL OR %MATCH%(to_jsonb(owner), to_jsonb(source_event))) AND (child.source_observation_id IS NULL OR %MATCH%(to_jsonb(owner), to_jsonb(source_observation))) AND (child.source_summary_id IS NULL OR %MATCH%(to_jsonb(owner), to_jsonb(source_summary))) AND (child.source_request_id IS NULL OR %MATCH%(to_jsonb(owner), to_jsonb(request_owner))) AND (child.source_crystal_id IS NULL OR %MATCH%(to_jsonb(owner), to_jsonb(source_crystal))) AND (child.source_session_id IS NULL OR %MATCH%(to_jsonb(owner), to_jsonb(source_session)))",
     "owner"},
    {"bpm_memory_relations",
     "LEFT JOIN %MEMORIES% AS owner ON owner.id = child.source_memory_id LEFT JOIN %MEMORIES% AS related ON related.id = child.target_memory_id",
     "%MATCH%(to_jsonb(owner), to_jsonb(related))", "owner"},
    {"bpm_memory_relation_evidence",
     "LEFT JOIN %RELATIONS% AS relation ON relation.id = child.relation_id LEFT JOIN %MEMORIES% AS owner ON owner.id = relation.source_memory_id LEFT JOIN %MEMORIES% AS related ON related.id = relation.target_memory_id LEFT JOIN %EVIDENCE% AS evidence ON evidence.id = child.evidence_id LEFT JOIN %MEMORIES% AS evidence_owner ON evidence_owner.id = evidence.memory_id",
     "%MATCH%(to_jsonb(owner), to_jsonb(related)) AND %MATCH%(to_jsonb(owner), to_jsonb(evidence_owner))",
     "owner"},
    {"memory_lessons", "LEFT JOIN %MEMORIES% AS owner ON owner.id = child.memory_id",
     "%MATCH%(to_jsonb(owner), to_jsonb(owner))", "owner"},
    {"memory_crystal_source_events",
     "LEFT JOIN %CRYSTALS% AS owner ON owner.id = child.crystal_id LEFT JOIN %EVENTS% AS related ON related.id = child.event_id",
     "%MATCH%(to_jsonb(owner), to_jsonb(related))", "owner"},
    {"memory_crystal_source_summaries",
     "LEFT JOIN %CRYSTALS% AS owner ON owner.id = child.crystal_id LEFT JOIN %SUMMARIES% AS related ON related.id = child.summary_id",
     "%MATCH%(to_jsonb(owner), to_jsonb(related))", "owner"},
    {"memory_crystal_source_actions",
     "LEFT JOIN %CRYSTALS% AS owner ON owner.id = child.crystal_id LEFT JOIN %ACTIONS% AS related ON related.id = child.action_id",
     "%MATCH%(to_jsonb(owner), to_jsonb(related))", "owner"},
    {"memory_crystal_lessons",
     "LEFT JOIN %CRYSTALS% AS owner ON owner.id = child.crystal_id LEFT JOIN %MEMORIES% AS related ON related.id = child.lesson_memory_id",
     "%MATCH%(to_jsonb(owner), to_jsonb(related))", "owner"},
    {"memory_summary_source_events",
     "LEFT JOIN %SUMMARIES% AS owner ON owner.id = child.summary_id LEFT JOIN %EVENTS% AS related ON related.id = child.event_id",
     "%MATCH%(to_jsonb(owner), to_jsonb(related)) AND child.host_id IS NOT DISTINCT FROM owner.host_id",
     "owner"},
    {"memory_action_edges",
     "LEFT JOIN %ACTIONS% AS owner ON owner.id = child.source_id LEFT JOIN %ACTIONS% AS related ON related.id = child.target_id",
     "%MATCH%(to_jsonb(owner), to_jsonb(related))", "owner"},
    {"memory_facets", "LEFT JOIN %MEMORIES% AS owner ON owner.id = child.memory_id",
     "%MATCH%(to_jsonb(owner), to_jsonb(owner))", "owner"},
    {"memory_recall_candidates",
     "LEFT JOIN %RECALL_RUNS% AS owner ON owner.id = child.recall_run_id LEFT JOIN %MEMORIES% AS source_memory ON child.candidate_kind IN ('memory', 'lesson') AND source_memory.id = child.candidate_id LEFT JOIN %EVENTS% AS source_event ON child.candidate_kind = 'event' AND source_event.id = child.candidate_id LEFT JOIN %OBSERVATIONS% AS source_observation ON child.candidate_kind = 'observation' AND source_observation.id = child.candidate_id LEFT JOIN %SUMMARIES% AS source_summary ON child.candidate_kind = 'summary' AND source_summary.id = child.candidate_id LEFT JOIN %REMEMBER_REQUESTS% AS source_request ON child.candidate_kind = 'request' AND source_request.id = child.candidate_id LEFT JOIN %MEMORIES% AS request_owner ON request_owner.id = source_request.memory_id LEFT JOIN %CRYSTALS% AS source_crystal ON child.candidate_kind = 'crystal' AND source_crystal.id = child.candidate_id",
     "%MATCH%(to_jsonb(owner), to_jsonb(owner)) AND CASE child.candidate_kind WHEN 'memory' THEN %MATCH%(to_jsonb(owner), to_jsonb(source_memory)) WHEN 'lesson' THEN %MATCH%(to_jsonb(owner), to_jsonb(source_memory)) WHEN 'event' THEN %MATCH%(to_jsonb(owner), to_jsonb(source_event)) WHEN 'observation' THEN %MATCH%(to_jsonb(owner), to_jsonb(source_observation)) WHEN 'summary' THEN %MATCH%(to_jsonb(owner), to_jsonb(source_summary)) WHEN 'request' THEN %MATCH%(to_jsonb(owner), to_jsonb(request_owner)) WHEN 'crystal' THEN %MATCH%(to_jsonb(owner), to_jsonb(source_crystal)) ELSE false END",
     "owner"}
  ]

  def up do
    Enum.each(statements(prefix()), &execute/1)
  end

  def down do
    raise Ecto.MigrationError,
      message: "forward-only migration: canonical memory-space ownership cannot be discarded"
  end

  @doc false
  def backfill(repo, migration_prefix) do
    {:ok, :ok} =
      repo.transaction(fn ->
        Enum.each(statements(migration_prefix), &repo.query!/1)
        :ok
      end)

    :ok
  end

  defp statements(migration_prefix) do
    immutable_root_trigger_statements(migration_prefix, "DISABLE") ++
      [source_id_function_sql(migration_prefix), partition_match_function_sql(migration_prefix)] ++
      Enum.flat_map(@roots, fn table_name ->
        [
          backfill_root_sql(migration_prefix, table_name),
          upsert_root_issues_sql(migration_prefix, table_name),
          resolve_clean_root_issues_sql(migration_prefix, table_name),
          validate_clean_root_sql(migration_prefix, table_name)
        ]
      end) ++
      inherited_root_statements(migration_prefix) ++
      Enum.flat_map(
        ~w(memory_sessions bpm_observations bpm_projection_states bpm_projection_snapshots),
        fn table_name ->
          [
            upsert_root_issues_sql(migration_prefix, table_name),
            resolve_clean_root_issues_sql(migration_prefix, table_name),
            validate_clean_root_sql(migration_prefix, table_name)
          ]
        end
      ) ++
      Enum.flat_map(@children, fn child ->
        [
          upsert_child_issues_sql(migration_prefix, child),
          resolve_child_issues_sql(migration_prefix, child)
        ]
      end) ++
      [
        inventory_audit_rows_sql(migration_prefix),
        resolve_audit_rows_sql(migration_prefix),
        inventory_pending_jobs_sql(migration_prefix),
        resolve_pending_jobs_sql(migration_prefix)
      ] ++
      Enum.flat_map(@children, &child_constraint_statements(migration_prefix, &1)) ++
      immutable_root_trigger_statements(migration_prefix, "ENABLE")
  end

  defp immutable_root_trigger_statements(migration_prefix, action) do
    Enum.map(@immutable_root_triggers, fn {table_name, trigger_name} ->
      table = qualified(migration_prefix, table_name)
      schema_name = escape_literal(migration_prefix || "public")

      """
      DO $$
      BEGIN
        IF EXISTS (
          SELECT 1
          FROM pg_trigger AS trigger
          JOIN pg_class AS relation ON relation.oid = trigger.tgrelid
          JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
          WHERE namespace.nspname = '#{schema_name}'
            AND relation.relname = '#{escape_literal(table_name)}'
            AND trigger.tgname = '#{escape_literal(trigger_name)}'
            AND NOT trigger.tgisinternal
        ) THEN
          ALTER TABLE #{table} #{action} TRIGGER #{quote_name(trigger_name)};
        END IF;
      END;
      $$
      """
    end)
  end

  defp inherited_root_statements(migration_prefix) do
    sessions = qualified(migration_prefix, "memory_sessions")
    observations = qualified(migration_prefix, "bpm_observations")
    projected_sessions = qualified(migration_prefix, "bpm_projected_sessions")
    projected_observations = qualified(migration_prefix, "bpm_projected_observations")
    states = qualified(migration_prefix, "bpm_projection_states")
    snapshots = qualified(migration_prefix, "bpm_projection_snapshots")

    [
      guarded_by_columns_sql(
        migration_prefix,
        [{"memory_sessions", "session_id"}, {"bpm_projected_sessions", "session_id"}],
        """
        UPDATE #{sessions} AS target
        SET memory_space_id = candidate.memory_space_id,
            host_id = coalesce(target.host_id, candidate.host_id),
            source_client_id = coalesce(target.source_client_id, candidate.source_client_id),
            scope = coalesce(nullif(btrim(target.scope), ''), candidate.scope),
            namespace = coalesce(nullif(btrim(target.namespace), ''), candidate.namespace)
        FROM (
          SELECT session_id,
                 min(memory_space_id::text)::uuid AS memory_space_id,
                 min(host_id) AS host_id,
                 min(source_client_id) AS source_client_id,
                 min(scope) AS scope,
                 min(namespace) AS namespace
          FROM #{projected_sessions}
          WHERE memory_space_id IS NOT NULL
            AND nullif(btrim(scope), '') IS NOT NULL
            AND nullif(btrim(namespace), '') IS NOT NULL
          GROUP BY session_id
          HAVING count(DISTINCT (memory_space_id::text || E'\\x1f' || scope || E'\\x1f' || namespace)) = 1
        ) AS candidate
        WHERE target.session_id = candidate.session_id
          AND target.memory_space_id IS NULL
        """
      ),
      guarded_by_columns_sql(
        migration_prefix,
        [{"bpm_observations", "session_id"}, {"memory_sessions", "session_id"}],
        """
        UPDATE #{observations} AS target
        SET memory_space_id = parent.memory_space_id,
            host_id = coalesce(target.host_id, parent.host_id),
            source_client_id = coalesce(target.source_client_id, parent.source_client_id),
            scope = coalesce(nullif(btrim(target.scope), ''), parent.scope),
            namespace = coalesce(nullif(btrim(target.namespace), ''), parent.namespace)
        FROM #{sessions} AS parent
        WHERE target.session_id = parent.session_id
          AND target.memory_space_id IS NULL
          AND parent.memory_space_id IS NOT NULL
          AND nullif(btrim(parent.scope), '') IS NOT NULL
          AND nullif(btrim(parent.namespace), '') IS NOT NULL
        """
      ),
      guarded_by_columns_sql(
        migration_prefix,
        [
          {"bpm_projection_states", "subject_id"},
          {"bpm_projected_sessions", "subject_id"},
          {"bpm_projected_observations", "subject_id"}
        ],
        inherited_projection_root_sql(states, projected_sessions, projected_observations)
      ),
      guarded_by_columns_sql(
        migration_prefix,
        [
          {"bpm_projection_snapshots", "subject_id"},
          {"bpm_projected_sessions", "subject_id"},
          {"bpm_projected_observations", "subject_id"}
        ],
        inherited_projection_root_sql(snapshots, projected_sessions, projected_observations)
      )
    ]
  end

  defp guarded_by_columns_sql(migration_prefix, requirements, statement) do
    schema_name = escape_literal(migration_prefix || "public")

    condition =
      requirements
      |> Enum.map_join(" AND ", fn {table, column} ->
        """
        EXISTS (
          SELECT 1
          FROM information_schema.columns
          WHERE table_schema = '#{schema_name}'
            AND table_name = '#{escape_literal(table)}'
            AND column_name = '#{escape_literal(column)}'
        )
        """
      end)

    """
    DO $$
    BEGIN
      IF #{condition} THEN
        #{statement};
      END IF;
    END;
    $$
    """
  end

  defp inherited_projection_root_sql(target, projected_sessions, projected_observations) do
    """
    UPDATE #{target} AS target
    SET memory_space_id = candidate.memory_space_id,
        host_id = coalesce(target.host_id, candidate.host_id),
        source_client_id = coalesce(target.source_client_id, candidate.source_client_id),
        scope = coalesce(nullif(btrim(target.scope), ''), candidate.scope),
        namespace = coalesce(nullif(btrim(target.namespace), ''), candidate.namespace)
    FROM (
      SELECT subject_id,
             min(memory_space_id::text)::uuid AS memory_space_id,
             min(host_id) AS host_id,
             min(source_client_id) AS source_client_id,
             min(scope) AS scope,
             min(namespace) AS namespace
      FROM (
        SELECT subject_id, memory_space_id, host_id, source_client_id, scope, namespace
        FROM #{projected_sessions}
        UNION ALL
        SELECT subject_id, memory_space_id, host_id, source_client_id, scope, namespace
        FROM #{projected_observations}
      ) AS parent
      WHERE memory_space_id IS NOT NULL
        AND nullif(btrim(scope), '') IS NOT NULL
        AND nullif(btrim(namespace), '') IS NOT NULL
      GROUP BY subject_id
      HAVING count(DISTINCT (memory_space_id::text || E'\\x1f' || scope || E'\\x1f' || namespace)) = 1
    ) AS candidate
    WHERE target.subject_id = candidate.subject_id
      AND target.memory_space_id IS NULL
    """
  end

  defp partition_match_function_sql(migration_prefix) do
    function = qualified(migration_prefix, "bpm_memory_partitions_match")

    """
    CREATE OR REPLACE FUNCTION #{function}(left_row jsonb, right_row jsonb)
    RETURNS boolean AS $$
      SELECT nullif(btrim(left_row ->> 'memory_space_id'), '') IS NOT NULL
         AND nullif(btrim(left_row ->> 'scope'), '') IS NOT NULL
         AND nullif(btrim(left_row ->> 'namespace'), '') IS NOT NULL
         AND left_row ->> 'memory_space_id' = right_row ->> 'memory_space_id'
         AND left_row ->> 'scope' = right_row ->> 'scope'
         AND left_row ->> 'namespace' = right_row ->> 'namespace'
    $$ LANGUAGE sql IMMUTABLE
    """
  end

  defp upsert_child_issues_sql(migration_prefix, {table, joins, valid, owner_alias}) do
    issues = qualified(migration_prefix, "bpm_memory_space_backfill_issues")
    source_id = qualified(migration_prefix, "bpm_memory_backfill_source_id")
    child = qualified(migration_prefix, table)
    regclass = escape_literal((migration_prefix || "public") <> "." <> table)
    joins = child_sql(migration_prefix, joins)
    valid = child_sql(migration_prefix, valid)

    """
    DO $$
    BEGIN
      IF to_regclass('#{regclass}') IS NOT NULL THEN
        INSERT INTO #{issues} AS existing
          (source_table, source_id, reason, disposition, details, inserted_at, updated_at)
        SELECT '#{escape_literal(table)}',
               #{source_id}('#{escape_literal(table)}', to_jsonb(child)),
               'child_partition_mismatch', 'pending',
               jsonb_build_object(
                 'memory_space_id', #{owner_alias}.memory_space_id,
                 'host_id', #{owner_alias}.host_id,
                 'scope', #{owner_alias}.scope,
                 'namespace', #{owner_alias}.namespace
               ), now(), now()
        FROM #{child} AS child
        #{joins}
        WHERE (#{valid}) IS NOT TRUE
        ON CONFLICT (source_table, source_id) DO UPDATE
          SET reason = EXCLUDED.reason,
              disposition = CASE WHEN existing.disposition = 'approved_waiver'
                                 THEN existing.disposition ELSE 'pending' END,
              details = EXCLUDED.details,
              resolved_at = CASE WHEN existing.disposition = 'approved_waiver'
                                 THEN existing.resolved_at ELSE NULL END,
              updated_at = now();
      END IF;
    END;
    $$
    """
  end

  defp resolve_child_issues_sql(migration_prefix, {table, joins, valid, _owner_alias}) do
    issues = qualified(migration_prefix, "bpm_memory_space_backfill_issues")
    source_id = qualified(migration_prefix, "bpm_memory_backfill_source_id")
    child = qualified(migration_prefix, table)
    regclass = escape_literal((migration_prefix || "public") <> "." <> table)
    joins = child_sql(migration_prefix, joins)
    valid = child_sql(migration_prefix, valid)

    """
    DO $$
    BEGIN
      IF to_regclass('#{regclass}') IS NOT NULL THEN
        UPDATE #{issues} AS issue
        SET disposition = 'resolved', resolved_at = now(), updated_at = now()
        WHERE issue.source_table = '#{escape_literal(table)}'
          AND issue.disposition = 'pending'
          AND NOT EXISTS (
            SELECT 1
            FROM #{child} AS child
            #{joins}
            WHERE #{source_id}('#{escape_literal(table)}', to_jsonb(child)) = issue.source_id
              AND (#{valid}) IS NOT TRUE
          );
      END IF;
    END;
    $$
    """
  end

  defp child_constraint_statements(migration_prefix, {table, joins, valid, _owner_alias}) do
    child = qualified(migration_prefix, table)
    source_id = qualified(migration_prefix, "bpm_memory_backfill_source_id")
    function_name = "bpm_assert_#{table}_canonical_partition"
    function = qualified(migration_prefix, function_name)
    trigger_name = "bpm_memory_space_child_partition_guard"
    regclass = escape_literal((migration_prefix || "public") <> "." <> table)
    joins = child_sql(migration_prefix, joins)
    valid = child_sql(migration_prefix, valid)

    function_sql = """
    CREATE OR REPLACE FUNCTION #{function}()
    RETURNS trigger AS $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1
        FROM #{child} AS child
        #{joins}
        WHERE #{source_id}('#{escape_literal(table)}', to_jsonb(child)) =
              #{source_id}('#{escape_literal(table)}', to_jsonb(NEW))
          AND (#{valid}) IS TRUE
      ) THEN
        RAISE EXCEPTION 'child row in #{escape_literal(table)} crosses canonical memory partition'
          USING ERRCODE = '23514',
                CONSTRAINT = '#{escape_literal(table)}_canonical_partition';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """

    trigger_sql = """
    DO $$
    BEGIN
      IF to_regclass('#{regclass}') IS NOT NULL THEN
        EXECUTE 'DROP TRIGGER IF EXISTS #{trigger_name} ON #{child}';
        EXECUTE 'CREATE CONSTRAINT TRIGGER #{trigger_name} '
             || 'AFTER INSERT OR UPDATE ON #{child} '
             || 'DEFERRABLE INITIALLY IMMEDIATE FOR EACH ROW '
             || 'EXECUTE FUNCTION #{function}()';
      END IF;
    END;
    $$
    """

    [function_sql, trigger_sql]
  end

  defp child_sql(migration_prefix, sql) do
    replacements = %{
      "%MEMORIES%" => qualified(migration_prefix, "bpm_memories"),
      "%RELATIONS%" => qualified(migration_prefix, "bpm_memory_relations"),
      "%EVIDENCE%" => qualified(migration_prefix, "bpm_memory_evidence"),
      "%OBSERVATIONS%" => qualified(migration_prefix, "bpm_observations"),
      "%REMEMBER_REQUESTS%" => qualified(migration_prefix, "bpm_memory_remember_requests"),
      "%PROJECTED_SESSIONS%" => qualified(migration_prefix, "bpm_projected_sessions"),
      "%CRYSTALS%" => qualified(migration_prefix, "memory_crystals"),
      "%EVENTS%" => qualified(migration_prefix, "bpm_events"),
      "%SUMMARIES%" => qualified(migration_prefix, "memory_summaries"),
      "%ACTIONS%" => qualified(migration_prefix, "memory_actions"),
      "%RECALL_RUNS%" => qualified(migration_prefix, "memory_recall_runs"),
      "%MATCH%" => qualified(migration_prefix, "bpm_memory_partitions_match")
    }

    Enum.reduce(replacements, sql, fn {placeholder, replacement}, acc ->
      String.replace(acc, placeholder, replacement)
    end)
  end

  defp source_id_function_sql(migration_prefix) do
    function = qualified(migration_prefix, "bpm_memory_backfill_source_id")
    schema_name = escape_literal(migration_prefix || "public")

    """
    CREATE OR REPLACE FUNCTION #{function}(root_table text, row_data jsonb)
    RETURNS text AS $$
    DECLARE
      column_name text;
      identity jsonb := '{}'::jsonb;
      identity_index oid;
    BEGIN
      SELECT index_row.indexrelid
      INTO identity_index
      FROM pg_index AS index_row
      JOIN pg_class AS relation ON relation.oid = index_row.indrelid
      JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
      WHERE index_row.indisunique
        AND index_row.indpred IS NULL
        AND index_row.indexprs IS NULL
        AND namespace.nspname = '#{schema_name}'
        AND relation.relname = root_table
      ORDER BY index_row.indisprimary DESC, index_row.indnkeyatts, index_row.indexrelid
      LIMIT 1;

      FOR column_name IN
        SELECT attribute.attname
        FROM pg_index AS index_row
        JOIN pg_class AS relation ON relation.oid = index_row.indrelid
        JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
        JOIN LATERAL unnest(index_row.indkey) WITH ORDINALITY AS key(attnum, ordinality)
          ON true
        JOIN pg_attribute AS attribute
          ON attribute.attrelid = relation.oid AND attribute.attnum = key.attnum
        WHERE index_row.indexrelid = identity_index
        ORDER BY key.ordinality
      LOOP
        identity := identity || jsonb_build_object(column_name, row_data -> column_name);
      END LOOP;

      IF identity = '{}'::jsonb THEN
        RAISE EXCEPTION 'partition source % has no stable unique key', root_table;
      END IF;

      RETURN identity::text;
    END;
    $$ LANGUAGE plpgsql STABLE
    """
  end

  defp backfill_root_sql(migration_prefix, table_name) do
    root = qualified(migration_prefix, table_name)
    matches = matches_sql(migration_prefix, "root")

    """
    UPDATE #{root} AS root
    SET memory_space_id = (SELECT min(match.memory_space_id::text)::uuid FROM (#{matches}) AS match),
        scope = coalesce(nullif(btrim(root.scope), ''),
                         (SELECT min(match.scope) FROM (#{matches}) AS match)),
        namespace = coalesce(nullif(btrim(root.namespace), ''),
                             (SELECT min(match.namespace) FROM (#{matches}) AS match))
    WHERE root.memory_space_id IS NULL
      AND (SELECT count(*) FROM (#{matches}) AS match) = 1
    """
  end

  defp upsert_root_issues_sql(migration_prefix, table_name) do
    root = qualified(migration_prefix, table_name)
    issues = qualified(migration_prefix, "bpm_memory_space_backfill_issues")
    source_id = qualified(migration_prefix, "bpm_memory_backfill_source_id")
    matches = matches_sql(migration_prefix, "root")
    valid = valid_partition_sql(migration_prefix, "root")

    """
    INSERT INTO #{issues} AS existing
      (source_table, source_id, reason, disposition, details, inserted_at, updated_at)
    SELECT '#{escape_literal(table_name)}',
           #{source_id}('#{escape_literal(table_name)}', to_jsonb(root)),
           CASE
             WHEN root.memory_space_id IS NOT NULL THEN 'partition_mismatch'
             WHEN (SELECT count(*) FROM (#{matches}) AS match) > 1 THEN 'ambiguous_partition'
             ELSE 'missing_mapping'
           END,
           'pending',
           jsonb_build_object(
             'memory_space_id', root.memory_space_id,
             'host_id', root.host_id,
             'scope', root.scope,
             'namespace', root.namespace
           ),
           now(), now()
    FROM #{root} AS root
    WHERE NOT (#{valid})
    ON CONFLICT (source_table, source_id) DO UPDATE
      SET reason = EXCLUDED.reason,
          disposition = CASE WHEN existing.disposition = 'approved_waiver'
                             THEN existing.disposition ELSE 'pending' END,
          details = EXCLUDED.details,
          resolved_at = CASE WHEN existing.disposition = 'approved_waiver'
                             THEN existing.resolved_at ELSE NULL END,
          updated_at = now()
    """
  end

  defp resolve_clean_root_issues_sql(migration_prefix, table_name) do
    root = qualified(migration_prefix, table_name)
    issues = qualified(migration_prefix, "bpm_memory_space_backfill_issues")
    source_id = qualified(migration_prefix, "bpm_memory_backfill_source_id")
    valid = valid_partition_sql(migration_prefix, "root")

    """
    UPDATE #{issues} AS issue
    SET disposition = 'resolved', resolved_at = now(), updated_at = now()
    WHERE issue.source_table = '#{escape_literal(table_name)}'
      AND issue.disposition = 'pending'
      AND NOT EXISTS (
        SELECT 1
        FROM #{root} AS root
        WHERE #{source_id}('#{escape_literal(table_name)}', to_jsonb(root)) = issue.source_id
          AND NOT (#{valid})
      )
    """
  end

  defp validate_clean_root_sql(migration_prefix, table_name) do
    root = qualified(migration_prefix, table_name)
    issues = qualified(migration_prefix, "bpm_memory_space_backfill_issues")

    """
    DO $$
    BEGIN
      IF NOT EXISTS (
           SELECT 1 FROM #{root}
           WHERE memory_space_id IS NULL
              OR scope IS NULL OR length(btrim(scope)) = 0
              OR namespace IS NULL OR length(btrim(namespace)) = 0
         )
         AND NOT EXISTS (
           SELECT 1 FROM #{issues}
           WHERE source_table = '#{escape_literal(table_name)}' AND disposition = 'pending'
         ) THEN
        ALTER TABLE #{root}
          VALIDATE CONSTRAINT #{quote_name(table_name <> "_canonical_memory_space_id")};
        ALTER TABLE #{root}
          VALIDATE CONSTRAINT #{quote_name(table_name <> "_canonical_scope")};
        ALTER TABLE #{root}
          VALIDATE CONSTRAINT #{quote_name(table_name <> "_canonical_namespace")};
      END IF;
    END;
    $$
    """
  end

  defp matches_sql(migration_prefix, row_alias) do
    aliases = qualified(migration_prefix, "bpm_memory_space_legacy_aliases")
    spaces = qualified(migration_prefix, "bpm_memory_spaces")
    entitlements = qualified(migration_prefix, "bpm_memory_space_entitlements")

    """
    SELECT DISTINCT alias_row.memory_space_id, entitlement.scope, entitlement.namespace
    FROM #{aliases} AS alias_row
    JOIN #{spaces} AS space
      ON space.id = alias_row.memory_space_id AND space.status = 'active'
    JOIN #{entitlements} AS entitlement
      ON entitlement.memory_space_id = alias_row.memory_space_id
     AND entitlement.host_id::text = #{row_alias}.host_id::text
     AND entitlement.status = 'active'
    WHERE alias_row.alias_type = 'host'
      AND alias_row.alias_value = 'host:' || #{row_alias}.host_id::text
      AND (nullif(btrim(#{row_alias}.scope), '') IS NULL OR
           entitlement.scope = btrim(#{row_alias}.scope))
      AND (nullif(btrim(#{row_alias}.namespace), '') IS NULL OR
           entitlement.namespace = btrim(#{row_alias}.namespace))
    """
  end

  defp valid_partition_sql(migration_prefix, row_alias) do
    aliases = qualified(migration_prefix, "bpm_memory_space_legacy_aliases")
    spaces = qualified(migration_prefix, "bpm_memory_spaces")
    entitlements = qualified(migration_prefix, "bpm_memory_space_entitlements")

    """
    #{row_alias}.memory_space_id IS NOT NULL
    AND nullif(btrim(#{row_alias}.scope), '') IS NOT NULL
    AND nullif(btrim(#{row_alias}.namespace), '') IS NOT NULL
    AND EXISTS (
      SELECT 1
      FROM #{aliases} AS alias_row
      JOIN #{spaces} AS space
        ON space.id = alias_row.memory_space_id AND space.status = 'active'
      JOIN #{entitlements} AS entitlement
        ON entitlement.memory_space_id = alias_row.memory_space_id
       AND entitlement.host_id::text = #{row_alias}.host_id::text
       AND entitlement.status = 'active'
      WHERE alias_row.alias_type = 'host'
        AND alias_row.alias_value = 'host:' || #{row_alias}.host_id::text
        AND alias_row.memory_space_id = #{row_alias}.memory_space_id
        AND entitlement.scope = btrim(#{row_alias}.scope)
        AND entitlement.namespace = btrim(#{row_alias}.namespace)
    )
    """
  end

  defp inventory_audit_rows_sql(migration_prefix) do
    issues = qualified(migration_prefix, "bpm_memory_space_backfill_issues")
    audit = qualified(migration_prefix, "memory_audit_log")
    audit_regclass = escape_literal((migration_prefix || "public") <> ".memory_audit_log")
    unresolved = audit_unresolved_sql(migration_prefix, "audit")

    """
    DO $$
    BEGIN
      IF to_regclass('#{audit_regclass}') IS NOT NULL THEN
        INSERT INTO #{issues} AS existing
          (source_table, source_id, reason, disposition, details, inserted_at, updated_at)
        SELECT 'memory_audit_log', audit.id::text, 'audit_partition_unresolved', 'pending',
               jsonb_build_object('operation', audit.operation), now(), now()
        FROM #{audit} AS audit
        WHERE audit.operation IN (#{audit_operations_sql()})
          AND (#{unresolved})
        ON CONFLICT (source_table, source_id) DO UPDATE
          SET reason = EXCLUDED.reason,
              disposition = CASE WHEN existing.disposition = 'approved_waiver'
                                 THEN existing.disposition ELSE 'pending' END,
              details = EXCLUDED.details,
              resolved_at = CASE WHEN existing.disposition = 'approved_waiver'
                                 THEN existing.resolved_at ELSE NULL END,
              updated_at = now();
      END IF;
    END;
    $$
    """
  end

  defp resolve_audit_rows_sql(migration_prefix) do
    issues = qualified(migration_prefix, "bpm_memory_space_backfill_issues")
    audit = qualified(migration_prefix, "memory_audit_log")
    audit_regclass = escape_literal((migration_prefix || "public") <> ".memory_audit_log")
    unresolved = audit_unresolved_sql(migration_prefix, "audit")

    """
    DO $$
    BEGIN
      IF to_regclass('#{audit_regclass}') IS NOT NULL THEN
        UPDATE #{issues} AS issue
        SET disposition = 'resolved', resolved_at = now(), updated_at = now()
        WHERE issue.source_table = 'memory_audit_log'
          AND issue.disposition = 'pending'
          AND NOT EXISTS (
            SELECT 1 FROM #{audit} AS audit
            WHERE audit.id::text = issue.source_id
              AND audit.operation IN (#{audit_operations_sql()})
              AND (#{unresolved})
          );
      END IF;
    END;
    $$
    """
  end

  defp audit_unresolved_sql(migration_prefix, row_alias) do
    memories = qualified(migration_prefix, "bpm_memories")

    """
    NOT (
      nullif(btrim(#{row_alias}.metadata ->> 'memory_space_id'), '') IS NOT NULL
      AND nullif(btrim(#{row_alias}.metadata ->> 'scope'), '') IS NOT NULL
      AND nullif(btrim(#{row_alias}.metadata ->> 'namespace'), '') IS NOT NULL
    )
    AND 1 <> (
      SELECT count(*)
      FROM (
        SELECT DISTINCT memory.memory_space_id, memory.scope, memory.namespace
        FROM #{memories} AS memory
        WHERE memory.memory_space_id IS NOT NULL
          AND nullif(btrim(memory.scope), '') IS NOT NULL
          AND nullif(btrim(memory.namespace), '') IS NOT NULL
          AND CASE jsonb_typeof(#{row_alias}.target_ids)
            WHEN 'array' THEN #{row_alias}.target_ids @> jsonb_build_array(memory.id::text)
            WHEN 'object' THEN EXISTS (
              SELECT 1 FROM jsonb_each_text(#{row_alias}.target_ids) AS target(key, value)
              WHERE target.value = memory.id::text
            )
            ELSE false
          END
      ) AS owners
    )
    """
  end

  defp audit_operations_sql do
    ~w(
      activity.repair
      coordination.action.create
      coordination.action.status
      coordination.heal
      coordination.lease.acquire
      coordination.lease.cleanup
      coordination.signal.read
      coordination.signal.send
      crystal.crystallize
      forget
      governance_delete
      hard_delete
      lesson.candidate
      lesson.save
      lesson.strengthen
      lesson.transition
      memory.activity.purge
      memory.activity.summary
      memory.apply
      memory.archive
      memory.config.set
      memory.export
      memory.gate.set
      memory.import.completed
      memory.import.failed
      memory.import.started
      memory.recall_trace.purge
      memory.repair
      memory.replay.import_dispatched
      memory.replay.load
      memory.replay.sessions
      memory_relation.candidate
      memory_relation.policy
      memory_relation.resolve
      projection.rebuild
      projection.repair
      remember
      session.abandoned
      session.lifecycle_transition
      session.summary_enqueued
    )
    |> Enum.map_join(", ", &("'" <> escape_literal(&1) <> "'"))
  end

  defp inventory_pending_jobs_sql(migration_prefix) do
    issues = qualified(migration_prefix, "bpm_memory_space_backfill_issues")
    jobs = qualified(migration_prefix, "oban_jobs")
    jobs_regclass = escape_literal((migration_prefix || "public") <> ".oban_jobs")
    unresolved = job_unresolved_sql(migration_prefix, "job")

    """
    DO $$
    BEGIN
      IF to_regclass('#{jobs_regclass}') IS NOT NULL THEN
        INSERT INTO #{issues} AS existing
          (source_table, source_id, reason, disposition, details, inserted_at, updated_at)
        SELECT 'oban_jobs', job.id::text, 'job_partition_unresolved', 'pending',
               jsonb_build_object('worker', job.worker, 'state', job.state), now(), now()
        FROM #{jobs} AS job
        WHERE job.worker LIKE 'Elixir.Backplane.Memory.%'
          AND job.state IN ('available', 'scheduled', 'retryable', 'executing')
          AND (#{unresolved})
        ON CONFLICT (source_table, source_id) DO UPDATE
          SET reason = EXCLUDED.reason,
              disposition = CASE WHEN existing.disposition = 'approved_waiver'
                                 THEN existing.disposition ELSE 'pending' END,
              details = EXCLUDED.details,
              resolved_at = CASE WHEN existing.disposition = 'approved_waiver'
                                 THEN existing.resolved_at ELSE NULL END,
              updated_at = now();
      END IF;
    END;
    $$
    """
  end

  defp resolve_pending_jobs_sql(migration_prefix) do
    issues = qualified(migration_prefix, "bpm_memory_space_backfill_issues")
    jobs = qualified(migration_prefix, "oban_jobs")
    jobs_regclass = escape_literal((migration_prefix || "public") <> ".oban_jobs")
    unresolved = job_unresolved_sql(migration_prefix, "job")

    """
    DO $$
    BEGIN
      IF to_regclass('#{jobs_regclass}') IS NOT NULL THEN
        UPDATE #{issues} AS issue
        SET disposition = 'resolved', resolved_at = now(), updated_at = now()
        WHERE issue.source_table = 'oban_jobs'
          AND issue.disposition = 'pending'
          AND NOT EXISTS (
            SELECT 1 FROM #{jobs} AS job
            WHERE job.id::text = issue.source_id
              AND job.worker LIKE 'Elixir.Backplane.Memory.%'
              AND job.state IN ('available', 'scheduled', 'retryable', 'executing')
              AND (#{unresolved})
          );
      END IF;
    END;
    $$
    """
  end

  defp job_unresolved_sql(migration_prefix, row_alias) do
    memories = qualified(migration_prefix, "bpm_memories")
    events = qualified(migration_prefix, "bpm_events")
    summaries = qualified(migration_prefix, "memory_summaries")
    match = qualified(migration_prefix, "bpm_memory_partitions_match")

    """
    NOT CASE #{row_alias}.worker
      WHEN 'Elixir.Backplane.Memory.Workers.ProceduralWorker' THEN true
      WHEN 'Elixir.Backplane.Memory.Workers.EvictionWorker' THEN true
      WHEN 'Elixir.Backplane.Memory.Workers.FallbackSweepWorker' THEN true
      WHEN 'Elixir.Backplane.Memory.Workers.ActivityRetentionWorker' THEN true
      WHEN 'Elixir.Backplane.Memory.Workers.LeaseCleanupWorker' THEN true
      WHEN 'Elixir.Backplane.Memory.Workers.RecallTracePurgeWorker' THEN true
      WHEN 'Elixir.Backplane.Memory.Workers.LessonDecaySweepWorker' THEN true
      WHEN 'Elixir.Backplane.Memory.Workers.EmbedWorker' THEN EXISTS (
        SELECT 1 FROM #{memories} AS owner
        WHERE owner.id::text = #{row_alias}.args ->> 'id'
          AND #{match}(to_jsonb(owner), to_jsonb(owner))
      )
      WHEN 'Elixir.Backplane.Memory.Workers.AccessWritebackWorker' THEN
        jsonb_typeof(#{row_alias}.args -> 'memory_ids') = 'array'
        AND NOT EXISTS (
          SELECT 1 FROM jsonb_array_elements_text(#{row_alias}.args -> 'memory_ids') AS target(id)
          LEFT JOIN #{memories} AS owner ON owner.id::text = target.id
          WHERE owner.id IS NULL OR NOT #{match}(to_jsonb(owner), to_jsonb(owner))
        )
      WHEN 'Elixir.Backplane.Memory.Workers.ProjectionRepairWorker' THEN EXISTS (
        SELECT 1 FROM #{events} AS owner
        WHERE owner.id::text = #{row_alias}.args ->> 'event_id'
          AND #{match}(to_jsonb(owner), to_jsonb(owner))
      )
      WHEN 'Elixir.Backplane.Memory.Workers.LessonCandidateWorker' THEN EXISTS (
        SELECT 1 FROM #{events} AS owner
        WHERE owner.id::text = #{row_alias}.args ->> 'event_id'
          AND #{match}(to_jsonb(owner), to_jsonb(owner))
      )
      WHEN 'Elixir.Backplane.Memory.Workers.EpisodicWorker' THEN EXISTS (
        SELECT 1 FROM #{summaries} AS owner
        WHERE owner.id::text = #{row_alias}.args ->> 'summary_id'
          AND #{match}(to_jsonb(owner), to_jsonb(owner))
      )
      WHEN 'Elixir.Backplane.Memory.Workers.RelationClassifierWorker' THEN EXISTS (
        SELECT 1 FROM #{memories} AS owner
        WHERE owner.id::text = #{row_alias}.args ->> 'memory_id'
          AND #{match}(to_jsonb(owner), #{row_alias}.args -> 'partition')
      )
      ELSE
        nullif(btrim(#{row_alias}.args ->> 'memory_space_id'), '') IS NOT NULL
        AND nullif(btrim(#{row_alias}.args ->> 'scope'), '') IS NOT NULL
        AND nullif(btrim(#{row_alias}.args ->> 'namespace'), '') IS NOT NULL
    END
    """
  end

  defp qualified(migration_prefix, name) do
    [migration_prefix || "public", name]
    |> Enum.map_join(".", &quote_name/1)
  end

  defp quote_name(name), do: ~s("#{String.replace(name, "\"", "\"\"")}")
  defp escape_literal(value), do: String.replace(value, "'", "''")
end

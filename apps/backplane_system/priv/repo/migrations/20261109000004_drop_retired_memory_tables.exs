defmodule Backplane.Repo.Migrations.DropRetiredMemoryTables do
  use Ecto.Migration

  # Memory simplification: partitions, edge sync, recall, lessons, crystals, graph,
  # coordination, replay, imports, facets, profiles and activity are retired. Their data
  # is disposable. Capture tables, memory_records and memory_audit_log are kept.
  @tables ~w(
    bpm_host_memory_command_receipts
    bpm_host_memory_compat_receipts
    bpm_host_memory_cursors
    bpm_host_memory_deliveries
    bpm_host_memory_revocations
    bpm_memories
    bpm_memory_access_audits
    bpm_memory_access_commands
    bpm_memory_changes
    bpm_memory_evidence
    bpm_memory_partition_revisions
    bpm_memory_relation_evidence
    bpm_memory_relations
    bpm_memory_remember_requests
    bpm_memory_request_evidence
    bpm_memory_snapshot_chunks
    bpm_memory_snapshots
    bpm_memory_source_entries
    bpm_memory_source_mutations
    bpm_memory_source_reconciliation_pages
    bpm_memory_source_reconciliations
    bpm_memory_sources
    bpm_memory_space_backfill_issues
    bpm_memory_space_entitlements
    bpm_memory_space_legacy_aliases
    bpm_memory_spaces
    bpm_observation_event_migrations
    bpm_observations
    memory_action_edges
    memory_actions
    memory_activity_daily
    memory_activity_subject_contributions
    memory_crystal_lessons
    memory_crystal_source_actions
    memory_crystal_source_events
    memory_crystal_source_summaries
    memory_crystals
    memory_facet_dimensions
    memory_facets
    memory_graph_edges
    memory_graph_nodes
    memory_import_batches
    memory_leases
    memory_lessons
    memory_profiles
    memory_recall_candidates
    memory_recall_runs
    memory_replay_events
    memory_sessions
    memory_signals
    memory_slots
    memory_summaries
    memory_summary_source_events
  )

  # bpm_reject_captured_event_* (bpm_events) and bpm_reject_memory_provenance_mutation
  # (memory_audit_log) still guard kept tables and are intentionally not dropped.
  @functions ~w(
    bpm_assert_bpm_memory_evidence_canonical_partition
    bpm_assert_bpm_memory_relation_evidence_canonical_partition
    bpm_assert_bpm_memory_relations_canonical_partition
    bpm_assert_bpm_memory_remember_requests_canonical_partition
    bpm_assert_memory_action_edges_canonical_partition
    bpm_assert_memory_crystal_lessons_canonical_partition
    bpm_assert_memory_crystal_source_actions_canonical_partition
    bpm_assert_memory_crystal_source_events_canonical_partition
    bpm_assert_memory_crystal_source_summaries_canonical_partition
    bpm_assert_memory_facets_canonical_partition
    bpm_assert_memory_lessons_canonical_partition
    bpm_assert_memory_recall_candidates_canonical_partition
    bpm_assert_memory_summary_source_events_canonical_partition
    bpm_capture_memory_edge_change
    bpm_derive_memory_space_identity
    bpm_guard_memory_relation_mutation
    bpm_memory_backfill_source_id
    bpm_memory_current_supported
    bpm_memory_edge_eligible
    bpm_memory_edge_host_origin
    bpm_memory_edge_max_item_bytes
    bpm_memory_edge_payload
    bpm_memory_independent_support
    bpm_memory_mutation_evidence_partition
    bpm_memory_partitions_match
    bpm_memory_source_valid_until
    bpm_refresh_memory_source_dependents
    bpm_reject_memory_change_update
    bpm_require_relation_endpoint_evidence
    bpm_validate_relation_evidence
    memory_access_audit_immutable
    memory_access_sorted_capabilities
    memory_active_lesson_requires_evidence
    memory_crystal_action_reciprocal_valid
    memory_crystal_action_source_valid
    memory_crystal_event_reciprocal_valid
    memory_crystal_event_source_valid
    memory_crystal_evidence_valid
    memory_crystal_lesson_link_valid
    memory_crystal_lesson_reciprocal_valid
    memory_crystal_links_reciprocal_valid
    memory_crystal_memory_parent_valid
    memory_crystal_parent_valid
    memory_crystal_source_immutable
    memory_crystal_summary_reciprocal_valid
    memory_crystal_summary_source_valid
    memory_crystal_typed_link_immutable
    memory_lesson_requires_procedural_parent
    memory_recall_source_refs_valid
    memory_replay_immutable
    validate_memory_summary_source_event
  )

  @retired_settings ~w(
    memory.host_sync.enabled
    memory.host_sync_max_item_bytes
    memory.pipeline.enabled
    memory.window_summaries.enabled
    memory.session_summary.enabled
    memory.fact_extraction.enabled
    memory.procedure_extraction.enabled
    memory.relation_classifier.enabled
    memory.recall.enabled
    memory.recall_trace_enabled
    memory.recall_trace_retention_days
    memory.recall_rrf_k
    memory.recall_channel_weights
    memory.recall_channel_limits
    memory.recall_max_per_session
    memory.recall_relevance_vector_min
    memory.recall_relevance_reranker_model
    memory.recall_relevance_reranker_min
    memory.recall_token_budget
    memory.recall_reranker_enabled
    memory.recall_reranker_top_k
    memory.activity_retention_days
    memory.replay_enabled
    memory.replay_import_enabled
    memory.replay_max_events
    memory.replay_import_max_files
    memory.replay_import_max_entries
    memory.replay_import_max_bytes
    memory.lesson_auto_extract
    memory.lesson_auto_promote
    memory.lesson_promote_confidence
    memory.lesson_promote_sources
    memory.lesson_decay_enabled
    memory.lesson_decay_archive_days
    memory.crystals_enabled
    memory.crystal_session_enabled
    memory.crystal_action_enabled
  )

  def up do
    p = quoted_prefix()

    execute("""
    DO $$
    BEGIN
      IF to_regclass('#{p}.bpm_memories') IS NOT NULL THEN
        EXECUTE 'DROP TRIGGER IF EXISTS bpm_memory_edge_change_capture ON #{p}.bpm_memories';
      END IF;
    END
    $$
    """)

    for table <- @tables do
      execute("DROP TABLE IF EXISTS #{p}.#{table} CASCADE")
    end

    # Some retired functions are overloaded; drop every signature by name.
    execute("""
    DO $$
    DECLARE r record;
    BEGIN
      FOR r IN
        SELECT p.oid::regprocedure AS signature
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = '#{schema_literal()}'
          AND p.proname = ANY(ARRAY[#{Enum.map_join(@functions, ", ", &"'#{&1}'")}]::text[])
      LOOP
        EXECUTE format('DROP FUNCTION IF EXISTS %s CASCADE', r.signature);
      END LOOP;
    END
    $$
    """)

    execute("""
    DELETE FROM #{p}.system_settings
    WHERE key = ANY(ARRAY[#{Enum.map_join(@retired_settings, ", ", &"'#{&1}'")}]::text[])
    """)
  end

  def down do
    raise Ecto.MigrationError, "dropping retired memory tables is irreversible"
  end

  defp schema_literal, do: String.replace(prefix() || "public", "'", "''")

  defp quoted_prefix, do: ~s("#{String.replace(prefix() || "public", "\"", "\"\"")}")
end

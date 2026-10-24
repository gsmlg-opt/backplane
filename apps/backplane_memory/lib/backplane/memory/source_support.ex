defmodule Backplane.Memory.SourceSupport do
  @moduledoc "Projects effective source support without deleting immutable evidence or operator history."

  @doc false
  def refresh!(partition) do
    repo().query!(
      """
      WITH locked AS MATERIALIZED (
        SELECT id FROM bpm_memories WHERE memory_space_id=$1 AND scope=$2 AND namespace=$3
        ORDER BY id FOR UPDATE
      ), projected AS (
        SELECT m.id,
          bpm_memory_current_supported(m) AS supported,
          jsonb_build_object(
            'policy_version','current_context.v1','support_complete',true,
            'independent_support',bpm_memory_independent_support(m),
            'valid_until',bpm_memory_source_valid_until(m),
            'trust', CASE WHEN EXISTS (
              SELECT 1 FROM bpm_memory_evidence ev LEFT JOIN bpm_events event ON event.id=ev.source_event_id
              WHERE ev.memory_id=m.id AND ev.evidence_kind='confirms' AND ev.support_score > 0
                AND event.event_type IN ('conversation.user_message','agent.prompt.submitted')
            ) THEN 'established_fact' ELSE 'candidate_inference' END,
            'source_refs', COALESCE((
              SELECT jsonb_agg(jsonb_build_object(
                'source',jsonb_build_object('integration',s.integration,'installation_id',s.installation_id,'profile_id',s.profile_id,'target',s.target),
                'entry_id',e.entry_id,'source_revision',e.revision,'event_id',e.mutation_id,'active',true
              ) ORDER BY s.id,e.entry_id)
              FROM bpm_memory_source_entries e JOIN bpm_memory_sources s ON s.id=e.source_id
              JOIN bpm_memories root ON root.id=e.memory_id
              WHERE (e.memory_id=m.id OR EXISTS (
                SELECT 1 FROM bpm_memory_remember_requests r JOIN bpm_memory_request_evidence g ON g.request_id=r.id
                JOIN bpm_memory_evidence ev ON ev.id=g.evidence_id
                WHERE r.memory_id=m.id AND ev.source_mutation_id=e.mutation_id
              )) AND e.active AND NOT e.suppressed
                AND root.deleted_at IS NULL AND root.lifecycle_state NOT IN ('superseded','archived','tombstoned')
                AND (root.expires_at IS NULL OR root.expires_at>timezone('UTC',clock_timestamp()))
            ),'[]'::jsonb)
          ) AS context
        FROM bpm_memories m JOIN locked l ON l.id=m.id
      )
      UPDATE bpm_memories m SET effective_support=p.supported,
        metadata=jsonb_set(COALESCE(m.metadata,'{}'::jsonb),'{current_context}',p.context,true),
        updated_at=timezone('UTC',clock_timestamp())
      FROM projected p WHERE m.id=p.id AND (m.effective_support IS DISTINCT FROM p.supported
        OR m.metadata->'current_context' IS DISTINCT FROM p.context)
      """,
      [Ecto.UUID.dump!(partition.memory_space_id), partition.scope, partition.namespace]
    )

    :ok
  end

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)
end

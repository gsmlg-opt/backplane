defmodule Backplane.Repo.Migrations.AlignMemoryRecallCandidateIdentity do
  use Ecto.Migration

  def up do
    p = quote_name(prefix() || "public")
    match = "#{p}.bpm_memory_partitions_match"

    # Adapters expose a crystal's memory ID and a captured observation's event ID.
    # Host/client identify provenance; sharing uses space, scope, and namespace.
    # Replace the function in place to retain the existing constraint trigger.
    execute("""
    CREATE OR REPLACE FUNCTION #{p}.bpm_assert_memory_recall_candidates_canonical_partition()
    RETURNS trigger AS $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM #{p}.memory_recall_runs AS owner
        WHERE owner.id = NEW.recall_run_id
          AND #{match}(to_jsonb(owner), to_jsonb(owner))
          AND NEW.scope IS NOT DISTINCT FROM owner.scope
          AND NEW.namespace IS NOT DISTINCT FROM owner.namespace
          AND CASE NEW.candidate_kind
            WHEN 'memory' THEN EXISTS (
              SELECT 1 FROM #{p}.bpm_memories AS artifact
              WHERE artifact.id = NEW.candidate_id
                AND #{match}(to_jsonb(owner), to_jsonb(artifact))
            )
            WHEN 'lesson' THEN EXISTS (
              SELECT 1 FROM #{p}.bpm_memories AS artifact
              WHERE artifact.id = NEW.candidate_id
                AND #{match}(to_jsonb(owner), to_jsonb(artifact))
            )
            WHEN 'event' THEN EXISTS (
              SELECT 1 FROM #{p}.bpm_events AS artifact
              WHERE artifact.id = NEW.candidate_id
                AND #{match}(to_jsonb(owner), to_jsonb(artifact))
            )
            WHEN 'observation' THEN EXISTS (
              SELECT 1 FROM #{p}.bpm_projected_observations AS artifact
              JOIN #{p}.bpm_events AS event ON event.id = artifact.event_id
              WHERE artifact.event_id = NEW.candidate_id
                AND #{match}(to_jsonb(owner), to_jsonb(artifact))
                AND #{match}(to_jsonb(owner), to_jsonb(event))
            ) OR EXISTS (
              SELECT 1 FROM #{p}.bpm_observations AS artifact
              WHERE artifact.id = NEW.candidate_id
                AND #{match}(to_jsonb(owner), to_jsonb(artifact))
            )
            WHEN 'summary' THEN EXISTS (
              SELECT 1 FROM #{p}.memory_summaries AS artifact
              WHERE artifact.id = NEW.candidate_id
                AND #{match}(to_jsonb(owner), to_jsonb(artifact))
            )
            WHEN 'request' THEN EXISTS (
              SELECT 1 FROM #{p}.memory_remember_requests AS request
              JOIN #{p}.bpm_memories AS artifact ON artifact.id = request.memory_id
              WHERE request.id = NEW.candidate_id
                AND #{match}(to_jsonb(owner), to_jsonb(artifact))
            )
            WHEN 'crystal' THEN EXISTS (
              SELECT 1 FROM #{p}.memory_crystals AS crystal
              JOIN #{p}.bpm_memories AS artifact ON artifact.id = crystal.memory_id
              WHERE (crystal.memory_id = NEW.candidate_id OR crystal.id = NEW.candidate_id)
                AND #{match}(to_jsonb(owner), to_jsonb(crystal))
                AND #{match}(to_jsonb(owner), to_jsonb(artifact))
            )
            ELSE false
          END
      ) THEN
        RAISE EXCEPTION 'child row in memory_recall_candidates crosses canonical memory partition'
          USING ERRCODE = '23514',
                CONSTRAINT = 'memory_recall_candidates_canonical_partition';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)
  end

  def down do
    raise Ecto.MigrationError,
      message: "forward-only migration: current recall candidate identities cannot be discarded"
  end

  defp quote_name(name), do: ~s("#{String.replace(name, "\"", "\"\"")}")
end

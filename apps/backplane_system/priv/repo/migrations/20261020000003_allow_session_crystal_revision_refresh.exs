defmodule Backplane.Repo.Migrations.AllowSessionCrystalRevisionRefresh do
  use Ecto.Migration

  def up do
    parent_checks(true)
    summary_checks(true)
    summary_trigger(true)
    memory_trigger(true)
  end

  def down do
    p = quoted_prefix()

    execute("""
    DO $$ BEGIN
      IF EXISTS (
        SELECT 1 FROM #{p}.memory_crystal_source_summaries link
        JOIN #{p}.memory_crystals crystal ON crystal.id = link.crystal_id
        JOIN #{p}.memory_summaries summary ON summary.id = link.summary_id
        WHERE summary.input_revision IS DISTINCT FROM crystal.input_revision
      ) OR EXISTS (
        SELECT 1 FROM #{p}.memory_crystals crystal
        JOIN #{p}.bpm_memories memory ON memory.id = crystal.memory_id
        WHERE memory.deleted_at IS NOT NULL OR memory.lifecycle_state <> 'active'
      ) THEN
        RAISE EXCEPTION 'cannot restore crystal constraints while historical revisions or governed parents exist';
      END IF;
    END $$;
    """)

    parent_checks(false)
    summary_checks(false)
    summary_trigger(false)
    memory_trigger(false)
  end

  defp parent_checks(refresh?) do
    p = quoted_prefix()
    space = if refresh?, do: "AND memory.memory_space_id = NEW.memory_space_id", else: ""

    lifecycle =
      if refresh?,
        do: "memory.lifecycle_state IN ('active', 'archived', 'tombstoned')",
        else: "memory.deleted_at IS NULL AND memory.lifecycle_state = 'active'"

    execute("""
    CREATE OR REPLACE FUNCTION #{p}.memory_crystal_parent_valid()
    RETURNS trigger AS $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM #{p}.bpm_memories memory
        WHERE memory.id = NEW.memory_id
          AND memory.memory_type = 'episodic'
          AND memory.host_id = NEW.host_id AND memory.client_id = NEW.client_id
          AND memory.scope = NEW.scope AND memory.namespace = NEW.namespace
          AND memory.session_id = NEW.source_session_id
          #{space} AND #{lifecycle}
      ) THEN
        RAISE EXCEPTION 'crystal parent must be an exact-partition episodic memory'
          USING ERRCODE = '23514', CONSTRAINT = 'memory_crystal_parent_check';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    space =
      if refresh?, do: "OR NEW.memory_space_id IS DISTINCT FROM crystal.memory_space_id", else: ""

    lifecycle =
      if refresh?,
        do: "NEW.lifecycle_state NOT IN ('active', 'archived', 'tombstoned')",
        else: "NEW.deleted_at IS NOT NULL OR NEW.lifecycle_state <> 'active'"

    execute("""
    CREATE OR REPLACE FUNCTION #{p}.memory_crystal_memory_parent_valid()
    RETURNS trigger AS $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM #{p}.memory_crystals crystal
        WHERE crystal.memory_id = NEW.id AND (
          NEW.memory_type <> 'episodic'
          OR NEW.host_id IS DISTINCT FROM crystal.host_id
          OR NEW.client_id IS DISTINCT FROM crystal.client_id
          OR NEW.scope IS DISTINCT FROM crystal.scope
          OR NEW.namespace IS DISTINCT FROM crystal.namespace
          OR NEW.session_id IS DISTINCT FROM crystal.source_session_id
          #{space} OR #{lifecycle}
        )
      ) THEN
        RAISE EXCEPTION 'crystal parent must remain an exact-partition episodic memory'
          USING ERRCODE = '23514', CONSTRAINT = 'memory_crystal_parent_check';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)
  end

  defp summary_checks(refresh?) do
    p = quoted_prefix()

    # Action-chain source semantics are unchanged. Session sources additionally
    # bind the immutable summary itself, not just its current projected session.
    exact = if refresh?, do: session_identity("crystal"), else: "true"

    execute("""
    CREATE OR REPLACE FUNCTION #{p}.memory_crystal_summary_source_valid()
    RETURNS trigger AS $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM #{p}.memory_crystals crystal
        JOIN #{p}.memory_summaries summary ON summary.id = NEW.summary_id
        JOIN #{p}.bpm_projected_sessions session
          ON session.subject_id = summary.subject_id AND session.host_id = summary.host_id
          AND session.session_id = summary.session_id
        WHERE crystal.id = NEW.crystal_id
          AND summary.input_revision = crystal.input_revision
          AND session.host_id = crystal.host_id AND session.client_id = crystal.client_id
          AND session.scope = crystal.scope AND session.namespace = crystal.namespace
          AND session.session_id = crystal.source_session_id
          AND (#{exact})
      ) THEN
        RAISE EXCEPTION 'crystal summary source partition mismatch'
          USING ERRCODE = '23514', CONSTRAINT = 'memory_crystal_summary_source_check';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    if refresh? do
      execute("""
      CREATE OR REPLACE FUNCTION #{p}.memory_crystal_summary_reciprocal_valid()
      RETURNS trigger AS $$
      DECLARE crystal #{p}.memory_crystals%ROWTYPE;
      BEGIN
        -- Deferred checks validate the final row, including all links appended
        -- by this transaction, rather than an intermediate trigger tuple.
        SELECT * INTO crystal FROM #{p}.memory_crystals WHERE id = NEW.id;
        IF NOT FOUND THEN RETURN NEW; END IF;
        IF EXISTS (
          SELECT 1 FROM #{p}.memory_crystal_source_summaries link
          JOIN #{p}.memory_summaries summary ON summary.id = link.summary_id
          WHERE link.crystal_id = crystal.id AND NOT EXISTS (
            SELECT 1 FROM #{p}.bpm_projected_sessions session
            WHERE session.subject_id = summary.subject_id AND session.host_id = summary.host_id
              AND session.session_id = summary.session_id
              AND session.host_id = crystal.host_id AND session.client_id = crystal.client_id
              AND session.scope = crystal.scope AND session.namespace = crystal.namespace
              AND session.session_id = crystal.source_session_id
              AND (#{session_identity("crystal")})
              AND (crystal.source_kind = 'session' OR summary.input_revision = crystal.input_revision)
          )
        ) OR (crystal.source_kind = 'session' AND NOT EXISTS (
          SELECT 1 FROM #{p}.memory_crystal_source_summaries link
          JOIN #{p}.memory_summaries summary ON summary.id = link.summary_id
          JOIN #{p}.bpm_projected_sessions session ON session.subject_id = summary.subject_id
          WHERE link.crystal_id = crystal.id
            AND summary.input_revision = crystal.input_revision
            AND summary.processing_version = 'summary-v1'
            AND session.input_revision = crystal.input_revision
            AND (#{session_identity("crystal")})
        )) THEN
          RAISE EXCEPTION 'crystal requires exact historical provenance and current summary evidence'
            USING ERRCODE = '23514', CONSTRAINT = 'memory_crystal_summary_source_check';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
      """)
    else
      execute("""
      CREATE OR REPLACE FUNCTION #{p}.memory_crystal_summary_reciprocal_valid()
      RETURNS trigger AS $$
      BEGIN
        IF EXISTS (
          SELECT 1 FROM #{p}.memory_crystal_source_summaries link
          JOIN #{p}.memory_summaries summary ON summary.id = link.summary_id
          WHERE link.crystal_id = NEW.id AND NOT EXISTS (
            SELECT 1 FROM #{p}.bpm_projected_sessions session
            WHERE session.subject_id = summary.subject_id AND session.host_id = summary.host_id
              AND session.session_id = summary.session_id AND summary.input_revision = NEW.input_revision
              AND session.host_id = NEW.host_id AND session.client_id = NEW.client_id
              AND session.scope = NEW.scope AND session.namespace = NEW.namespace
              AND session.session_id = NEW.source_session_id
          )
        ) THEN
          RAISE EXCEPTION 'crystal update invalidates summary source links'
            USING ERRCODE = '23514', CONSTRAINT = 'memory_crystal_summary_source_check';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
      """)
    end
  end

  defp session_identity(crystal) do
    """
    #{crystal}.source_kind <> 'session' OR (
      summary.subject_id = #{crystal}.subject_id AND session.subject_id = #{crystal}.subject_id
      AND summary.memory_space_id = #{crystal}.memory_space_id
      AND session.memory_space_id = #{crystal}.memory_space_id
      AND summary.host_id = #{crystal}.host_id AND session.host_id = #{crystal}.host_id
      AND session.client_id = #{crystal}.client_id
      AND summary.scope = #{crystal}.scope AND session.scope = #{crystal}.scope
      AND summary.namespace = #{crystal}.namespace AND session.namespace = #{crystal}.namespace
      AND summary.session_id = #{crystal}.source_session_id
      AND session.session_id = #{crystal}.source_session_id
    )
    """
  end

  defp summary_trigger(refresh?) do
    p = quoted_prefix()
    execute("DROP TRIGGER memory_crystal_summary_reciprocal_check ON #{p}.memory_crystals")

    action =
      if refresh?,
        do: "INSERT OR UPDATE",
        else: "UPDATE OF host_id, client_id, scope, namespace, source_session_id, input_revision"

    execute("""
    CREATE CONSTRAINT TRIGGER memory_crystal_summary_reciprocal_check
    AFTER #{action} ON #{p}.memory_crystals
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
    EXECUTE FUNCTION #{p}.memory_crystal_summary_reciprocal_valid();
    """)
  end

  defp memory_trigger(refresh?) do
    p = quoted_prefix()
    space = if refresh?, do: ", memory_space_id", else: ""
    execute("DROP TRIGGER memory_crystal_memory_parent_check ON #{p}.bpm_memories")

    execute("""
    CREATE CONSTRAINT TRIGGER memory_crystal_memory_parent_check
    AFTER UPDATE OF memory_type, host_id, client_id, scope, namespace, session_id, deleted_at, lifecycle_state#{space}
    ON #{p}.bpm_memories DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
    EXECUTE FUNCTION #{p}.memory_crystal_memory_parent_valid();
    """)
  end

  defp quoted_prefix, do: ~s("#{String.replace(prefix() || "public", "\"", "\"\"")}")
end

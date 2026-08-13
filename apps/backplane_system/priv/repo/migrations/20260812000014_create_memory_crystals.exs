defmodule Backplane.Repo.Migrations.CreateMemoryCrystals do
  use Ecto.Migration

  def up do
    crystals = qualified("memory_crystals")
    source_summaries = qualified("memory_crystal_source_summaries")
    source_events = qualified("memory_crystal_source_events")
    memories = qualified("bpm_memories")
    events = qualified("bpm_events")
    summaries = qualified("memory_summaries")
    sessions = qualified("bpm_projected_sessions")
    immutable_fn = qualified("memory_crystal_source_immutable")
    parent_fn = qualified("memory_crystal_parent_valid")
    reciprocal_parent_fn = qualified("memory_crystal_memory_parent_valid")
    event_source_fn = qualified("memory_crystal_event_source_valid")
    summary_source_fn = qualified("memory_crystal_summary_source_valid")
    reciprocal_event_source_fn = qualified("memory_crystal_event_reciprocal_valid")
    reciprocal_summary_source_fn = qualified("memory_crystal_summary_reciprocal_valid")

    create table(:memory_crystals, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:memory_id, references(:bpm_memories, type: :uuid, on_delete: :restrict), null: false)
      add(:subject_id, :text, null: false)
      add(:host_id, :text, null: false)
      add(:client_id, :text, null: false)
      add(:scope, :text, null: false)
      add(:namespace, :text, null: false)
      add(:source_session_id, :text, null: false)
      add(:title, :text, null: false)
      add(:project, :text)
      add(:narrative, :text, null: false)
      add(:key_outcomes, :map, null: false, default: fragment("'[]'::jsonb"))
      add(:decisions, :map, null: false, default: fragment("'[]'::jsonb"))
      add(:files_affected, :map, null: false, default: fragment("'[]'::jsonb"))
      add(:unresolved_items, :map, null: false, default: fragment("'[]'::jsonb"))
      add(:processing_version, :text, null: false)
      add(:model, :text)
      add(:prompt_version, :text, null: false)
      add(:input_revision, :text, null: false)
      add(:output_revision, :text, null: false)
      add(:status, :text, null: false)
      add(:last_error, :text)
      add(:started_at, :utc_datetime_usec)
      add(:completed_at, :utc_datetime_usec)
      add(:inserted_at, :utc_datetime_usec, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create(unique_index(:memory_crystals, [:memory_id]))

    create(
      unique_index(
        :memory_crystals,
        [:client_id, :scope, :namespace, :host_id, :source_session_id, :processing_version],
        name: :memory_crystals_partition_session_version_uniq
      )
    )

    create(
      constraint(:memory_crystals, :memory_crystals_status_check,
        check: "status IN ('pending', 'running', 'complete', 'failed')"
      )
    )

    create(
      constraint(:memory_crystals, :memory_crystals_revisions_check,
        check: "octet_length(input_revision) = 64 AND octet_length(output_revision) = 64"
      )
    )

    create(
      constraint(:memory_crystals, :memory_crystals_structured_arrays_check,
        check: """
        jsonb_typeof(key_outcomes) = 'array' AND jsonb_array_length(key_outcomes) <= 100 AND
        jsonb_typeof(decisions) = 'array' AND jsonb_array_length(decisions) <= 100 AND
        jsonb_typeof(files_affected) = 'array' AND jsonb_array_length(files_affected) <= 500 AND
        jsonb_typeof(unresolved_items) = 'array' AND jsonb_array_length(unresolved_items) <= 100
        """
      )
    )

    create table(:memory_crystal_source_summaries, primary_key: false) do
      add(:crystal_id, references(:memory_crystals, type: :uuid, on_delete: :delete_all),
        primary_key: true,
        null: false
      )

      add(:summary_id, references(:memory_summaries, type: :uuid, on_delete: :restrict),
        primary_key: true,
        null: false
      )

      add(:inserted_at, :utc_datetime_usec, null: false)
    end

    create table(:memory_crystal_source_events, primary_key: false) do
      add(:crystal_id, references(:memory_crystals, type: :uuid, on_delete: :delete_all),
        primary_key: true,
        null: false
      )

      add(:event_id, references(:bpm_events, type: :uuid, on_delete: :restrict),
        primary_key: true,
        null: false
      )

      add(:inserted_at, :utc_datetime_usec, null: false)
    end

    create table(:memory_crystal_lessons, primary_key: false) do
      add(:crystal_id, references(:memory_crystals, type: :uuid, on_delete: :delete_all),
        primary_key: true,
        null: false
      )

      add(
        :lesson_memory_id,
        references(:memory_lessons, column: :memory_id, type: :uuid, on_delete: :restrict),
        primary_key: true,
        null: false
      )

      add(:relation_type, :text, null: false)
      add(:inserted_at, :utc_datetime_usec, null: false)
    end

    create(
      constraint(:memory_crystal_lessons, :memory_crystal_lessons_relation_type_check,
        check: "relation_type IN ('extracted', 'reinforced')"
      )
    )

    execute("""
    CREATE FUNCTION #{immutable_fn}()
    RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'crystal source links are immutable'
        USING ERRCODE = '23514', CONSTRAINT = 'memory_crystal_source_immutable';
    END;
    $$ LANGUAGE plpgsql
    """)

    for table <- ~w(memory_crystal_source_summaries memory_crystal_source_events) do
      qualified_table = qualified(table)

      execute("""
      CREATE TRIGGER #{quote_name("#{table}_immutable")}
      BEFORE UPDATE OR DELETE ON #{qualified_table}
      FOR EACH ROW EXECUTE FUNCTION #{immutable_fn}()
      """)

      execute("""
      CREATE TRIGGER #{quote_name("#{table}_truncate_immutable")}
      BEFORE TRUNCATE ON #{qualified_table}
      FOR EACH STATEMENT EXECUTE FUNCTION #{immutable_fn}()
      """)
    end

    execute("""
    CREATE FUNCTION #{parent_fn}()
    RETURNS trigger AS $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM #{memories} memory
        WHERE memory.id = NEW.memory_id
          AND memory.memory_type = 'episodic'
          AND memory.host_id = NEW.host_id
          AND memory.client_id = NEW.client_id
          AND memory.scope = NEW.scope
          AND memory.namespace = NEW.namespace
          AND memory.session_id = NEW.source_session_id
          AND memory.deleted_at IS NULL
          AND memory.lifecycle_state = 'active'
      ) THEN
        RAISE EXCEPTION 'crystal parent must be an exact-partition episodic memory'
          USING ERRCODE = '23514', CONSTRAINT = 'memory_crystal_parent_check';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE CONSTRAINT TRIGGER #{quote_name("memory_crystal_parent_check")}
    AFTER INSERT OR UPDATE ON #{crystals}
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION #{parent_fn}()
    """)

    execute("""
    CREATE FUNCTION #{reciprocal_parent_fn}()
    RETURNS trigger AS $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM #{crystals} crystal
        WHERE crystal.memory_id = NEW.id
          AND (
            NEW.memory_type <> 'episodic'
            OR NEW.host_id IS DISTINCT FROM crystal.host_id
            OR NEW.client_id IS DISTINCT FROM crystal.client_id
            OR NEW.scope IS DISTINCT FROM crystal.scope
            OR NEW.namespace IS DISTINCT FROM crystal.namespace
            OR NEW.session_id IS DISTINCT FROM crystal.source_session_id
            OR NEW.deleted_at IS NOT NULL
            OR NEW.lifecycle_state <> 'active'
          )
      ) THEN
        RAISE EXCEPTION 'crystal parent must remain an exact-partition active episodic memory'
          USING ERRCODE = '23514', CONSTRAINT = 'memory_crystal_parent_check';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE CONSTRAINT TRIGGER #{quote_name("memory_crystal_memory_parent_check")}
    AFTER UPDATE OF memory_type, host_id, client_id, scope, namespace, session_id, deleted_at, lifecycle_state
    ON #{memories}
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION #{reciprocal_parent_fn}()
    """)

    execute("""
    CREATE FUNCTION #{event_source_fn}()
    RETURNS trigger AS $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1
        FROM #{crystals} crystal
        JOIN #{events} event ON event.id = NEW.event_id
        WHERE crystal.id = NEW.crystal_id
          AND event.schema_version IS NOT NULL
          AND event.host_id = crystal.host_id
          AND event.client_id = crystal.client_id
          AND event.scope = crystal.scope
          AND event.namespace = crystal.namespace
          AND event.session_id = crystal.source_session_id
      ) THEN
        RAISE EXCEPTION 'crystal event source partition mismatch'
          USING ERRCODE = '23514', CONSTRAINT = 'memory_crystal_event_source_check';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE CONSTRAINT TRIGGER #{quote_name("memory_crystal_event_source_check")}
    AFTER INSERT ON #{source_events}
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION #{event_source_fn}()
    """)

    execute("""
    CREATE FUNCTION #{summary_source_fn}()
    RETURNS trigger AS $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1
        FROM #{crystals} crystal
        JOIN #{summaries} summary ON summary.id = NEW.summary_id
        JOIN #{sessions} session
          ON session.subject_id = summary.subject_id
         AND session.host_id = summary.host_id
         AND session.session_id = summary.session_id
        WHERE crystal.id = NEW.crystal_id
          AND summary.input_revision = crystal.input_revision
          AND session.host_id = crystal.host_id
          AND session.client_id = crystal.client_id
          AND session.scope = crystal.scope
          AND session.namespace = crystal.namespace
          AND session.session_id = crystal.source_session_id
      ) THEN
        RAISE EXCEPTION 'crystal summary source partition mismatch'
          USING ERRCODE = '23514', CONSTRAINT = 'memory_crystal_summary_source_check';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE CONSTRAINT TRIGGER #{quote_name("memory_crystal_summary_source_check")}
    AFTER INSERT ON #{source_summaries}
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION #{summary_source_fn}()
    """)

    execute("""
    CREATE FUNCTION #{reciprocal_event_source_fn}()
    RETURNS trigger AS $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM #{source_events} link
        JOIN #{events} event ON event.id = link.event_id
        WHERE link.crystal_id = NEW.id
          AND (
            event.schema_version IS NULL
            OR event.host_id IS DISTINCT FROM NEW.host_id
            OR event.client_id IS DISTINCT FROM NEW.client_id
            OR event.scope IS DISTINCT FROM NEW.scope
            OR event.namespace IS DISTINCT FROM NEW.namespace
            OR event.session_id IS DISTINCT FROM NEW.source_session_id
          )
      ) THEN
        RAISE EXCEPTION 'crystal update invalidates event source links'
          USING ERRCODE = '23514', CONSTRAINT = 'memory_crystal_event_source_check';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE CONSTRAINT TRIGGER #{quote_name("memory_crystal_event_reciprocal_check")}
    AFTER UPDATE OF host_id, client_id, scope, namespace, source_session_id
    ON #{crystals}
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION #{reciprocal_event_source_fn}()
    """)

    execute("""
    CREATE FUNCTION #{reciprocal_summary_source_fn}()
    RETURNS trigger AS $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM #{source_summaries} link
        JOIN #{summaries} summary ON summary.id = link.summary_id
        WHERE link.crystal_id = NEW.id
          AND NOT EXISTS (
            SELECT 1
            FROM #{sessions} session
            WHERE session.subject_id = summary.subject_id
              AND session.host_id = summary.host_id
              AND session.session_id = summary.session_id
              AND summary.input_revision = NEW.input_revision
              AND session.host_id = NEW.host_id
              AND session.client_id = NEW.client_id
              AND session.scope = NEW.scope
              AND session.namespace = NEW.namespace
              AND session.session_id = NEW.source_session_id
          )
      ) THEN
        RAISE EXCEPTION 'crystal update invalidates summary source links'
          USING ERRCODE = '23514', CONSTRAINT = 'memory_crystal_summary_source_check';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE CONSTRAINT TRIGGER #{quote_name("memory_crystal_summary_reciprocal_check")}
    AFTER UPDATE OF host_id, client_id, scope, namespace, source_session_id, input_revision
    ON #{crystals}
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION #{reciprocal_summary_source_fn}()
    """)
  end

  def down do
    crystals = qualified("memory_crystals")
    source_summaries = qualified("memory_crystal_source_summaries")
    source_events = qualified("memory_crystal_source_events")
    memories = qualified("bpm_memories")

    execute(
      "DROP TRIGGER IF EXISTS #{quote_name("memory_crystal_summary_reciprocal_check")} ON #{crystals}"
    )

    execute("DROP FUNCTION IF EXISTS #{qualified("memory_crystal_summary_reciprocal_valid")}()")

    execute(
      "DROP TRIGGER IF EXISTS #{quote_name("memory_crystal_event_reciprocal_check")} ON #{crystals}"
    )

    execute("DROP FUNCTION IF EXISTS #{qualified("memory_crystal_event_reciprocal_valid")}()")

    execute(
      "DROP TRIGGER IF EXISTS #{quote_name("memory_crystal_summary_source_check")} ON #{source_summaries}"
    )

    execute("DROP FUNCTION IF EXISTS #{qualified("memory_crystal_summary_source_valid")}()")

    execute(
      "DROP TRIGGER IF EXISTS #{quote_name("memory_crystal_event_source_check")} ON #{source_events}"
    )

    execute("DROP FUNCTION IF EXISTS #{qualified("memory_crystal_event_source_valid")}()")

    execute(
      "DROP TRIGGER IF EXISTS #{quote_name("memory_crystal_memory_parent_check")} ON #{memories}"
    )

    execute("DROP FUNCTION IF EXISTS #{qualified("memory_crystal_memory_parent_valid")}()")
    execute("DROP TRIGGER IF EXISTS #{quote_name("memory_crystal_parent_check")} ON #{crystals}")
    execute("DROP FUNCTION IF EXISTS #{qualified("memory_crystal_parent_valid")}()")

    for table <- ~w(memory_crystal_source_summaries memory_crystal_source_events) do
      qualified_table = qualified(table)

      execute(
        "DROP TRIGGER IF EXISTS #{quote_name("#{table}_truncate_immutable")} ON #{qualified_table}"
      )

      execute("DROP TRIGGER IF EXISTS #{quote_name("#{table}_immutable")} ON #{qualified_table}")
    end

    execute("DROP FUNCTION IF EXISTS #{qualified("memory_crystal_source_immutable")}()")
    drop(table(:memory_crystal_lessons))
    drop(table(:memory_crystal_source_events))
    drop(table(:memory_crystal_source_summaries))
    drop(table(:memory_crystals))
  end

  defp qualified(name) do
    [prefix(), name]
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join(".", &quote_name/1)
  end

  defp quote_name(name), do: ~s("#{String.replace(name, "\"", "\"\"")}")
end

defmodule Backplane.Repo.Migrations.VersionCanonicalMemorySummaries do
  use Ecto.Migration

  @legacy_host "legacy"
  @legacy_version "legacy-v0"

  def up do
    summaries = qualified_table("memory_summaries")

    alter table(:memory_summaries) do
      add(:subject_id, :text)
      add(:host_id, :text)
      add(:agent_id, :text)
      add(:processing_version, :text)
      add(:input_revision, :text)
      add(:output_revision, :text)
      add(:superseded_at, :utc_datetime_usec)
      add(:superseded_by_input_revision, :text)
    end

    flush()

    execute("""
    UPDATE #{summaries}
    SET subject_id = 'legacy:' || session_id,
        host_id = '#{@legacy_host}',
        processing_version = '#{@legacy_version}',
        input_revision = md5('legacy-input:' || session_id) ||
          md5('legacy-input-2:' || session_id),
        output_revision = md5(content) || md5('legacy-output-2:' || content)
    """)

    alter table(:memory_summaries) do
      modify(:subject_id, :text, null: false, default: nil)
      modify(:host_id, :text, null: false, default: nil)
      modify(:processing_version, :text, null: false, default: nil)
      modify(:input_revision, :text, null: false, default: nil)
      modify(:output_revision, :text, null: false, default: nil)
    end

    flush()

    drop(index(:memory_summaries, [:session_id]))

    create(
      unique_index(:memory_summaries, [:subject_id, :processing_version],
        name: :memory_summaries_subject_version_uniq
      )
    )

    create(index(:memory_summaries, [:host_id, :session_id]))
    create(index(:memory_summaries, [:project, :created_at]))
    create(index(:memory_summaries, [:input_revision]))

    create table(:memory_summary_source_events, primary_key: false) do
      add(:summary_id, references(:memory_summaries, type: :binary_id, on_delete: :restrict),
        null: false
      )

      add(:event_id, references(:bpm_events, type: :binary_id, on_delete: :restrict), null: false)
      add(:host_id, :text, null: false)
      add(:session_id, :text, null: false)
      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create(
      unique_index(:memory_summary_source_events, [:summary_id, :event_id],
        name: :memory_summary_source_events_summary_event_uniq
      )
    )

    create(index(:memory_summary_source_events, [:host_id, :session_id]))
    create(index(:memory_summary_source_events, [:event_id, :summary_id]))
    create_source_event_ownership_trigger()
  end

  def down do
    drop_source_event_ownership_trigger()
    drop(table(:memory_summary_source_events))

    drop(index(:memory_summaries, [:input_revision]))
    drop(index(:memory_summaries, [:project, :created_at]))
    drop(index(:memory_summaries, [:host_id, :session_id]))

    drop(
      index(:memory_summaries, [:subject_id, :processing_version],
        name: :memory_summaries_subject_version_uniq
      )
    )

    # Canonical history can legitimately contain several revisions for the same
    # captured session. Rewrite only the deprecated identity before restoring its
    # unique index so every row and every UUID/FK target survives rollback.
    execute("""
    UPDATE #{qualified_table("memory_summaries")}
    SET session_id = 'legacy-summary:' || id::text || ':' || session_id
    """)

    alter table(:memory_summaries) do
      remove(:superseded_by_input_revision)
      remove(:superseded_at)
      remove(:output_revision)
      remove(:input_revision)
      remove(:processing_version)
      remove(:agent_id)
      remove(:host_id)
      remove(:subject_id)
    end

    create(unique_index(:memory_summaries, [:session_id]))
  end

  defp create_source_event_ownership_trigger do
    function = qualified_function("validate_memory_summary_source_event")
    links = qualified_table("memory_summary_source_events")
    summaries = qualified_table("memory_summaries")
    events = qualified_table("bpm_events")

    execute("""
    CREATE FUNCTION #{function}() RETURNS trigger AS $$
    DECLARE
      summary_host text;
      summary_session text;
      event_host text;
      event_session text;
      event_schema_version integer;
    BEGIN
      SELECT host_id, session_id INTO STRICT summary_host, summary_session
      FROM #{summaries} WHERE id = NEW.summary_id;

      SELECT host_id, session_id, schema_version
      INTO STRICT event_host, event_session, event_schema_version
      FROM #{events} WHERE id = NEW.event_id;

      IF event_schema_version IS NULL
         OR NEW.host_id IS DISTINCT FROM summary_host
         OR NEW.session_id IS DISTINCT FROM summary_session
         OR event_host IS DISTINCT FROM summary_host
         OR event_session IS DISTINCT FROM summary_session THEN
        RAISE EXCEPTION 'summary source event must be canonical and belong to the same host and session'
          USING ERRCODE = '23514';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER memory_summary_source_events_ownership
    BEFORE INSERT ON #{links}
    FOR EACH ROW EXECUTE FUNCTION #{function}()
    """)

    execute("""
    CREATE TRIGGER memory_summary_source_events_immutable_row
    BEFORE UPDATE OR DELETE ON #{links}
    FOR EACH ROW EXECUTE FUNCTION #{qualified_function("bpm_reject_memory_provenance_mutation")}()
    """)

    execute("""
    CREATE TRIGGER memory_summary_source_events_immutable_truncate
    BEFORE TRUNCATE ON #{links}
    FOR EACH STATEMENT EXECUTE FUNCTION #{qualified_function("bpm_reject_memory_provenance_mutation")}()
    """)
  end

  defp drop_source_event_ownership_trigger do
    execute(
      "DROP TRIGGER IF EXISTS memory_summary_source_events_immutable_truncate ON #{qualified_table("memory_summary_source_events")}"
    )

    execute(
      "DROP TRIGGER IF EXISTS memory_summary_source_events_immutable_row ON #{qualified_table("memory_summary_source_events")}"
    )

    execute(
      "DROP TRIGGER IF EXISTS memory_summary_source_events_ownership ON #{qualified_table("memory_summary_source_events")}"
    )

    execute(
      "DROP FUNCTION IF EXISTS #{qualified_function("validate_memory_summary_source_event")}()"
    )
  end

  defp qualified_table(table) do
    case prefix() do
      nil -> ~s|"#{table}"|
      prefix -> ~s|"#{String.replace(prefix, "\"", "\"\"")}"."#{table}"|
    end
  end

  defp qualified_function(function) do
    case prefix() do
      nil -> ~s|"#{function}"|
      prefix -> ~s|"#{String.replace(prefix, "\"", "\"\"")}"."#{function}"|
    end
  end
end

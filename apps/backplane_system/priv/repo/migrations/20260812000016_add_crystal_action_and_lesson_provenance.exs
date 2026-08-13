defmodule Backplane.Repo.Migrations.AddCrystalActionAndLessonProvenance do
  use Ecto.Migration

  def up do
    alter table(:memory_crystals, prefix: prefix()) do
      add(:source_kind, :text, null: false, default: "session")
      add(:action_chain_key, :text)
    end

    create(
      constraint(:memory_crystals, :memory_crystals_source_kind_check,
        check:
          "(source_kind = 'session' AND action_chain_key IS NULL) OR " <>
            "(source_kind = 'action_chain' AND action_chain_key IS NOT NULL)"
      )
    )

    create(
      unique_index(
        :memory_crystals,
        [:client_id, :scope, :namespace, :host_id, :action_chain_key, :processing_version],
        where: "source_kind = 'action_chain'",
        name: :memory_crystals_partition_action_version_uniq
      )
    )

    create table(:memory_crystal_source_actions, primary_key: false, prefix: prefix()) do
      add(:crystal_id, references(:memory_crystals, type: :uuid, on_delete: :delete_all),
        primary_key: true,
        null: false
      )

      add(:action_id, references(:memory_actions, type: :uuid, on_delete: :restrict),
        primary_key: true,
        null: false
      )

      add(:terminal_override, :boolean, null: false, default: false)
      add(:inserted_at, :utc_datetime_usec, null: false)
    end

    alter table(:bpm_memory_evidence, prefix: prefix()) do
      add(:source_crystal_id, references(:memory_crystals, type: :uuid, on_delete: :restrict))
    end

    drop(constraint(:bpm_memory_evidence, :bpm_memory_evidence_source_check, prefix: prefix()))

    create(
      constraint(:bpm_memory_evidence, :bpm_memory_evidence_source_check,
        check: """
        num_nonnulls(source_event_id, source_observation_id, source_summary_id,
          source_request_id, source_crystal_id)
          + CASE WHEN source_session_id IS NULL THEN 0 ELSE 1 END = 1
        AND (source_session_id IS NULL
          OR (btrim(source_session_id) <> '' AND host_id IS NOT NULL AND btrim(host_id) <> ''))
        """
      )
    )

    create(
      unique_index(:bpm_memory_evidence, [:source_crystal_id, :memory_id],
        where: "source_crystal_id IS NOT NULL",
        name: :bpm_memory_evidence_crystal_source_uniq
      )
    )

    immutable = qualified("memory_crystal_typed_link_immutable")
    actions = qualified("memory_actions")
    crystals = qualified("memory_crystals")
    lessons = qualified("memory_lessons")
    memories = qualified("bpm_memories")
    source_actions = qualified("memory_crystal_source_actions")
    crystal_lessons = qualified("memory_crystal_lessons")

    execute("""
    CREATE FUNCTION #{immutable}() RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'crystal typed links are immutable'
        USING ERRCODE = '23514', CONSTRAINT = 'memory_crystal_typed_link_immutable';
    END; $$ LANGUAGE plpgsql
    """)

    for table <- [source_actions, crystal_lessons] do
      suffix = table |> String.replace(~r/[^a-zA-Z0-9]+/, "_")

      execute(
        "CREATE TRIGGER #{quote_name("#{suffix}_immutable")} BEFORE UPDATE OR DELETE ON #{table} FOR EACH ROW EXECUTE FUNCTION #{immutable}()"
      )

      execute(
        "CREATE TRIGGER #{quote_name("#{suffix}_truncate_immutable")} BEFORE TRUNCATE ON #{table} FOR EACH STATEMENT EXECUTE FUNCTION #{immutable}()"
      )
    end

    action_check = qualified("memory_crystal_action_source_valid")

    execute("""
    CREATE FUNCTION #{action_check}() RETURNS trigger AS $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM #{crystals} c JOIN #{actions} a ON a.id = NEW.action_id
        WHERE c.id = NEW.crystal_id AND c.source_kind = 'action_chain'
          AND a.host_id = c.host_id AND a.client_id = c.client_id
          AND a.scope = c.scope AND a.namespace = c.namespace
          AND (NEW.terminal_override OR a.status IN ('done', 'cancelled'))
      ) THEN
        RAISE EXCEPTION 'crystal action source mismatch or nonterminal action'
          USING ERRCODE = '23514', CONSTRAINT = 'memory_crystal_action_source_check';
      END IF;
      RETURN NEW;
    END; $$ LANGUAGE plpgsql
    """)

    execute(
      "CREATE CONSTRAINT TRIGGER memory_crystal_action_source_check AFTER INSERT ON #{source_actions} DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION #{action_check}()"
    )

    lesson_check = qualified("memory_crystal_lesson_link_valid")

    execute("""
    CREATE FUNCTION #{lesson_check}() RETURNS trigger AS $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM #{crystals} c
        JOIN #{lessons} l ON l.memory_id = NEW.lesson_memory_id
        JOIN #{memories} m ON m.id = l.memory_id
        WHERE c.id = NEW.crystal_id AND m.host_id = c.host_id
          AND m.client_id = c.client_id AND m.scope = c.scope AND m.namespace = c.namespace
      ) THEN
        RAISE EXCEPTION 'crystal lesson partition mismatch'
          USING ERRCODE = '23514', CONSTRAINT = 'memory_crystal_lesson_link_check';
      END IF;
      RETURN NEW;
    END; $$ LANGUAGE plpgsql
    """)

    execute(
      "CREATE CONSTRAINT TRIGGER memory_crystal_lesson_link_check AFTER INSERT ON #{crystal_lessons} DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION #{lesson_check}()"
    )

    execute("""
    CREATE FUNCTION #{qualified("memory_crystal_action_reciprocal_valid")}() RETURNS trigger AS $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM #{source_actions} link JOIN #{crystals} c ON c.id = link.crystal_id
        WHERE link.action_id = NEW.id AND (
          NEW.host_id IS DISTINCT FROM c.host_id OR NEW.client_id IS DISTINCT FROM c.client_id
          OR NEW.scope IS DISTINCT FROM c.scope OR NEW.namespace IS DISTINCT FROM c.namespace
          OR (NOT link.terminal_override AND NEW.status NOT IN ('done', 'cancelled'))
        )
      ) THEN RAISE EXCEPTION 'linked crystal action invariant violated'
        USING ERRCODE = '23514', CONSTRAINT = 'memory_crystal_action_source_check'; END IF;
      RETURN NEW;
    END; $$ LANGUAGE plpgsql
    """)

    execute(
      "CREATE CONSTRAINT TRIGGER memory_crystal_action_reciprocal_check AFTER UPDATE OF status, host_id, client_id, scope, namespace ON #{actions} DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION #{qualified("memory_crystal_action_reciprocal_valid")}()"
    )

    execute("""
    CREATE FUNCTION #{qualified("memory_crystal_lesson_reciprocal_valid")}() RETURNS trigger AS $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM #{crystal_lessons} link JOIN #{crystals} c ON c.id = link.crystal_id
        WHERE link.lesson_memory_id = NEW.id AND (
          NEW.host_id IS DISTINCT FROM c.host_id OR NEW.client_id IS DISTINCT FROM c.client_id
          OR NEW.scope IS DISTINCT FROM c.scope OR NEW.namespace IS DISTINCT FROM c.namespace
        )
      ) THEN RAISE EXCEPTION 'linked crystal lesson partition invariant violated'
        USING ERRCODE = '23514', CONSTRAINT = 'memory_crystal_lesson_link_check'; END IF;
      RETURN NEW;
    END; $$ LANGUAGE plpgsql
    """)

    execute(
      "CREATE CONSTRAINT TRIGGER memory_crystal_lesson_reciprocal_check AFTER UPDATE OF host_id, client_id, scope, namespace ON #{memories} DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION #{qualified("memory_crystal_lesson_reciprocal_valid")}()"
    )

    evidence = qualified("bpm_memory_evidence")

    execute("""
    CREATE FUNCTION #{qualified("memory_crystal_evidence_valid")}() RETURNS trigger AS $$
    BEGIN
      IF NEW.source_crystal_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM #{crystals} c JOIN #{memories} m ON m.id = NEW.memory_id
        WHERE c.id = NEW.source_crystal_id AND m.host_id = c.host_id
          AND m.client_id = c.client_id AND m.scope = c.scope AND m.namespace = c.namespace
      ) THEN RAISE EXCEPTION 'crystal evidence partition mismatch'
        USING ERRCODE = '23514', CONSTRAINT = 'memory_crystal_evidence_check'; END IF;
      RETURN NEW;
    END; $$ LANGUAGE plpgsql
    """)

    execute(
      "CREATE CONSTRAINT TRIGGER memory_crystal_evidence_check AFTER INSERT OR UPDATE OF memory_id, source_crystal_id ON #{evidence} DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION #{qualified("memory_crystal_evidence_valid")}()"
    )

    execute("""
    CREATE FUNCTION #{qualified("memory_crystal_links_reciprocal_valid")}() RETURNS trigger AS $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM #{source_actions} link JOIN #{actions} action ON action.id = link.action_id
        WHERE link.crystal_id = NEW.id AND (
          NEW.source_kind <> 'action_chain'
          OR action.host_id IS DISTINCT FROM NEW.host_id
          OR action.client_id IS DISTINCT FROM NEW.client_id
          OR action.scope IS DISTINCT FROM NEW.scope
          OR action.namespace IS DISTINCT FROM NEW.namespace
          OR (NOT link.terminal_override AND action.status NOT IN ('done', 'cancelled'))
        )
      ) THEN RAISE EXCEPTION 'crystal update invalidates action source links'
        USING ERRCODE = '23514', CONSTRAINT = 'memory_crystal_action_source_check'; END IF;

      IF EXISTS (
        SELECT 1 FROM #{crystal_lessons} link
        JOIN #{memories} memory ON memory.id = link.lesson_memory_id
        WHERE link.crystal_id = NEW.id AND (
          memory.host_id IS DISTINCT FROM NEW.host_id
          OR memory.client_id IS DISTINCT FROM NEW.client_id
          OR memory.scope IS DISTINCT FROM NEW.scope
          OR memory.namespace IS DISTINCT FROM NEW.namespace
        )
      ) THEN RAISE EXCEPTION 'crystal update invalidates lesson links'
        USING ERRCODE = '23514', CONSTRAINT = 'memory_crystal_lesson_link_check'; END IF;

      IF EXISTS (
        SELECT 1 FROM #{evidence} evidence
        JOIN #{memories} memory ON memory.id = evidence.memory_id
        WHERE evidence.source_crystal_id = NEW.id AND (
          memory.host_id IS DISTINCT FROM NEW.host_id
          OR memory.client_id IS DISTINCT FROM NEW.client_id
          OR memory.scope IS DISTINCT FROM NEW.scope
          OR memory.namespace IS DISTINCT FROM NEW.namespace
        )
      ) THEN RAISE EXCEPTION 'crystal update invalidates evidence links'
        USING ERRCODE = '23514', CONSTRAINT = 'memory_crystal_evidence_check'; END IF;

      RETURN NEW;
    END; $$ LANGUAGE plpgsql
    """)

    execute(
      "CREATE CONSTRAINT TRIGGER memory_crystal_links_reciprocal_check AFTER UPDATE OF host_id, client_id, scope, namespace, source_kind ON #{crystals} DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION #{qualified("memory_crystal_links_reciprocal_valid")}()"
    )
  end

  def down do
    execute(
      "DROP TRIGGER IF EXISTS memory_crystal_links_reciprocal_check ON #{qualified("memory_crystals")}"
    )

    execute("DROP FUNCTION IF EXISTS #{qualified("memory_crystal_links_reciprocal_valid")}()")

    execute(
      "DROP TRIGGER IF EXISTS memory_crystal_evidence_check ON #{qualified("bpm_memory_evidence")}"
    )

    execute("DROP FUNCTION IF EXISTS #{qualified("memory_crystal_evidence_valid")}()")

    execute(
      "DROP TRIGGER IF EXISTS memory_crystal_lesson_reciprocal_check ON #{qualified("bpm_memories")}"
    )

    execute("DROP FUNCTION IF EXISTS #{qualified("memory_crystal_lesson_reciprocal_valid")}()")

    execute(
      "DROP TRIGGER IF EXISTS memory_crystal_action_reciprocal_check ON #{qualified("memory_actions")}"
    )

    execute("DROP FUNCTION IF EXISTS #{qualified("memory_crystal_action_reciprocal_valid")}()")

    execute(
      "DROP TRIGGER IF EXISTS memory_crystal_lesson_link_check ON #{qualified("memory_crystal_lessons")}"
    )

    execute("DROP FUNCTION IF EXISTS #{qualified("memory_crystal_lesson_link_valid")}()")

    execute(
      "DROP TRIGGER IF EXISTS memory_crystal_action_source_check ON #{qualified("memory_crystal_source_actions")}"
    )

    execute("DROP FUNCTION IF EXISTS #{qualified("memory_crystal_action_source_valid")}()")

    for table <- ~w(memory_crystal_source_actions memory_crystal_lessons) do
      suffix = qualified(table) |> String.replace(~r/[^a-zA-Z0-9]+/, "_")

      execute(
        "DROP TRIGGER IF EXISTS #{quote_name("#{suffix}_truncate_immutable")} ON #{qualified(table)}"
      )

      execute(
        "DROP TRIGGER IF EXISTS #{quote_name("#{suffix}_immutable")} ON #{qualified(table)}"
      )
    end

    execute("DROP FUNCTION IF EXISTS #{qualified("memory_crystal_typed_link_immutable")}()")

    drop(
      index(:bpm_memory_evidence, [:source_crystal_id, :memory_id],
        name: :bpm_memory_evidence_crystal_source_uniq,
        prefix: prefix()
      )
    )

    drop(constraint(:bpm_memory_evidence, :bpm_memory_evidence_source_check, prefix: prefix()))
    alter table(:bpm_memory_evidence, prefix: prefix()), do: remove(:source_crystal_id)

    create(
      constraint(:bpm_memory_evidence, :bpm_memory_evidence_source_check,
        check:
          "num_nonnulls(source_event_id, source_observation_id, source_summary_id, source_request_id) + CASE WHEN source_session_id IS NULL THEN 0 ELSE 1 END = 1 AND (source_session_id IS NULL OR (btrim(source_session_id) <> '' AND host_id IS NOT NULL AND btrim(host_id) <> ''))"
      )
    )

    drop(table(:memory_crystal_source_actions, prefix: prefix()))

    drop(
      index(
        :memory_crystals,
        [:client_id, :scope, :namespace, :host_id, :action_chain_key, :processing_version],
        name: :memory_crystals_partition_action_version_uniq,
        prefix: prefix()
      )
    )

    drop(constraint(:memory_crystals, :memory_crystals_source_kind_check, prefix: prefix()))

    alter table(:memory_crystals, prefix: prefix()) do
      remove(:source_kind)
      remove(:action_chain_key)
    end
  end

  defp qualified(name),
    do: [prefix(), name] |> Enum.reject(&is_nil/1) |> Enum.map_join(".", &quote_name/1)

  defp quote_name(name), do: ~s("#{String.replace(name, "\"", "\"\"")}")
end

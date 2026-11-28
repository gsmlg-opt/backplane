defmodule Backplane.Repo.Migrations.AddSkillProtocolChanges do
  use Ecto.Migration

  @watched_tables [
    {"skills",
     ~w(name description tags content content_hash enabled always_return archive_ref current_revision publication_status)},
    {"skill_revisions", ~w(skill_id revision artifact_digest manifest blob_ref)},
    {"clients", ~w(active scopes token_digest token_issued_at)},
    {"oauth_clients", ~w(metadata public_key private_key secret)},
    {"oauth_tokens", ~w(type value scope expires_at revoked_at client_id sub)},
    {"oauth_token_resources", ~w(oauth_token_id resource)},
    {"users", ~w(active)},
    {"system_settings", ~w(key value)}
  ]

  def up do
    create table(:skill_protocol_state, primary_key: false) do
      add(:id, :integer, primary_key: true)
      add(:generation, :uuid, null: false, default: fragment("gen_random_uuid()"))
    end

    create constraint(:skill_protocol_state, :skill_protocol_state_singleton, check: "id = 1")
    execute("INSERT INTO #{qualified("skill_protocol_state")} (id) VALUES (1)")

    execute("""
    CREATE FUNCTION #{qualified("notify_skill_protocol_change")}() RETURNS trigger AS $$
    DECLARE
      field_name text;
      changed boolean := TG_OP <> 'UPDATE';
    BEGIN
      IF TG_TABLE_NAME = 'system_settings' AND TG_OP <> 'TRUNCATE' THEN
        IF TG_OP = 'INSERT' AND NEW.key <> 'clients.auth_bypass.enabled' THEN RETURN NULL; END IF;
        IF TG_OP = 'DELETE' AND OLD.key <> 'clients.auth_bypass.enabled' THEN RETURN NULL; END IF;
        IF TG_OP = 'UPDATE' AND OLD.key <> 'clients.auth_bypass.enabled'
                           AND NEW.key <> 'clients.auth_bypass.enabled' THEN RETURN NULL; END IF;
      END IF;

      IF TG_OP = 'UPDATE' THEN
        FOREACH field_name IN ARRAY TG_ARGV LOOP
          IF to_jsonb(OLD)->field_name IS DISTINCT FROM to_jsonb(NEW)->field_name THEN
            changed := true;
            EXIT;
          END IF;
        END LOOP;
      END IF;

      IF changed THEN
        UPDATE #{qualified("skill_protocol_state")} SET generation = gen_random_uuid() WHERE id = 1;
        PERFORM pg_notify('backplane_skill_protocol_changed', '');
      END IF;
      RETURN NULL;
    END;
    $$ LANGUAGE plpgsql
    """)

    for {table, fields} <- @watched_tables do
      arguments = Enum.map_join(fields, ", ", &"'#{&1}'")

      execute("""
      CREATE TRIGGER skill_protocol_row_changed
      AFTER INSERT OR UPDATE OR DELETE ON #{qualified(table)}
      FOR EACH ROW EXECUTE FUNCTION #{qualified("notify_skill_protocol_change")}(#{arguments})
      """)

      execute("""
      CREATE TRIGGER skill_protocol_truncated
      AFTER TRUNCATE ON #{qualified(table)}
      FOR EACH STATEMENT EXECUTE FUNCTION #{qualified("notify_skill_protocol_change")}()
      """)
    end
  end

  def down do
    for {table, _fields} <- @watched_tables do
      execute("DROP TRIGGER IF EXISTS skill_protocol_row_changed ON #{qualified(table)}")
      execute("DROP TRIGGER IF EXISTS skill_protocol_truncated ON #{qualified(table)}")
    end

    execute("DROP FUNCTION IF EXISTS #{qualified("notify_skill_protocol_change")}()")
    drop(table(:skill_protocol_state))
  end

  defp qualified(name) do
    [prefix(), name]
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join(".", fn identifier ->
      ~s("#{identifier |> to_string() |> String.replace("\"", "\"\"")}")
    end)
  end
end

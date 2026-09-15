defmodule Backplane.Repo.Migrations.CreateSkillRevisions do
  use Ecto.Migration

  def up do
    drop(constraint(:oauth_token_resources, :oauth_token_resources_resource_check))

    create constraint(:oauth_token_resources, :oauth_token_resources_resource_check,
             check: "resource IN ('mcp', 'skill_protocol', 'v1')"
           )

    alter table(:skills) do
      add(:current_revision, :text)
      add(:publication_status, :text, null: false, default: "pending")
      add(:publication_diagnostic, :map, null: false, default: %{})
    end

    create constraint(:skills, :skills_publication_status_check,
             check: "publication_status IN ('ready', 'invalid', 'pending', 'withdrawn')"
           )

    create table(:skill_revisions, primary_key: false) do
      add(:skill_id, references(:skills, type: :text, on_delete: :delete_all),
        primary_key: true,
        null: false
      )

      add(:revision, :text, primary_key: true, null: false)
      add(:artifact_digest, :text, null: false)
      add(:manifest, :map, null: false)
      add(:blob_ref, :text, null: false)
      add(:published_at, :utc_datetime_usec, null: false)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:skill_revisions, [:skill_id, :artifact_digest])
    create index(:skill_revisions, [:blob_ref])

    create constraint(:skill_revisions, :skill_revisions_revision_format,
             check: "revision ~ '^r-[a-f0-9]{64}$'"
           )

    create constraint(:skill_revisions, :skill_revisions_artifact_digest_format,
             check: "artifact_digest ~ '^sha256:[a-f0-9]{64}$'"
           )

    create constraint(:skill_revisions, :skill_revisions_blob_ref_format,
             check: "blob_ref ~ '^sha256/[a-f0-9]{64}\\.tar\\.gz$'"
           )

    execute("""
    ALTER TABLE #{qualified("skills")}
    ADD CONSTRAINT skills_current_revision_fkey
    FOREIGN KEY (id, current_revision)
    REFERENCES #{qualified("skill_revisions")}(skill_id, revision)
    DEFERRABLE INITIALLY DEFERRED
    """)

    execute("""
    CREATE FUNCTION #{qualified("prevent_skill_revision_update")}() RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'skill revisions are immutable';
    END;
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER skill_revisions_immutable
    BEFORE UPDATE ON #{qualified("skill_revisions")}
    FOR EACH ROW EXECUTE FUNCTION #{qualified("prevent_skill_revision_update")}()
    """)
  end

  def down do
    execute(fn -> ensure_no_retained_revisions!() end)
    flush()

    execute(
      "ALTER TABLE #{qualified("skills")} DROP CONSTRAINT IF EXISTS skills_current_revision_fkey"
    )

    execute("DROP TRIGGER IF EXISTS skill_revisions_immutable ON #{qualified("skill_revisions")}")
    execute("DROP FUNCTION IF EXISTS #{qualified("prevent_skill_revision_update")}()")
    drop(table(:skill_revisions))

    alter table(:skills) do
      remove(:publication_diagnostic)
      remove(:publication_status)
      remove(:current_revision)
    end

    drop(constraint(:oauth_token_resources, :oauth_token_resources_resource_check))

    create constraint(:oauth_token_resources, :oauth_token_resources_resource_check,
             check: "resource IN ('mcp', 'v1')"
           )
  end

  defp ensure_no_retained_revisions! do
    %{rows: [[retained_revisions?]]} =
      repo().query!("SELECT EXISTS (SELECT 1 FROM #{qualified("skill_revisions")} LIMIT 1)")

    if retained_revisions? do
      raise Ecto.MigrationError,
        message:
          "refusing destructive rollback: skill_revisions contains retained immutable publications"
    end
  end

  defp qualified(name) do
    [prefix(), name]
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join(".", fn identifier ->
      ~s("#{identifier |> to_string() |> String.replace("\"", "\"\"")}")
    end)
  end
end

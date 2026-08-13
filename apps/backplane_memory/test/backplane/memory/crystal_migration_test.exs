defmodule Backplane.Memory.CrystalMigrationTestRepo do
  use Ecto.Repo, otp_app: :backplane_system, adapter: Ecto.Adapters.Postgres
end

defmodule Backplane.Memory.CrystalMigrationTest do
  use Backplane.Memory.DataCase, async: false

  @version 20_260_812_000_014
  @migration Backplane.Repo.Migrations.CreateMemoryCrystals

  test "00014 is prefix-safe and reversible without touching public objects" do
    prefix = "crystal_migration_#{System.unique_integer([:positive])}"
    migration_repo = start_migration_repo()
    load_migration()
    public_oid = relation_oid(migration_repo, "public.memory_crystals")

    migration_repo.query!(~s(CREATE SCHEMA "#{prefix}"))

    try do
      create_prerequisites(migration_repo, prefix)
      assert :ok = migrate(migration_repo, prefix, :up)
      assert relation_oid(migration_repo, "#{prefix}.memory_crystals")
      assert relation_oid(migration_repo, "public.memory_crystals") == public_oid

      assert MapSet.subset?(
               MapSet.new([
                 "memory_crystal_event_reciprocal_check",
                 "memory_crystal_summary_reciprocal_check"
               ]),
               MapSet.new(trigger_names(migration_repo, prefix, "memory_crystals"))
             )

      assert_reciprocal_source_checks(migration_repo, prefix)

      assert :ok = migrate(migration_repo, prefix, :down)
      refute relation_oid(migration_repo, "#{prefix}.memory_crystals")
      assert relation_oid(migration_repo, "public.memory_crystals") == public_oid
    after
      migration_repo.query!(~s(DROP SCHEMA IF EXISTS "#{prefix}" CASCADE))
    end
  end

  defp create_prerequisites(repo, prefix) do
    statements = [
      """
      CREATE TABLE "#{prefix}".bpm_memories (
        id uuid PRIMARY KEY, memory_type text, host_id text, client_id text, scope text,
        namespace text, session_id text, deleted_at timestamp, lifecycle_state text
      )
      """,
      """
      CREATE TABLE "#{prefix}".memory_summaries (
        id uuid PRIMARY KEY, subject_id text, host_id text, session_id text, input_revision text
      )
      """,
      """
      CREATE TABLE "#{prefix}".bpm_events (
        id uuid PRIMARY KEY, schema_version integer, host_id text, client_id text,
        scope text, namespace text, session_id text
      )
      """,
      ~s|CREATE TABLE "#{prefix}".memory_lessons (memory_id uuid UNIQUE)|,
      """
      CREATE TABLE "#{prefix}".bpm_projected_sessions (
        subject_id text, host_id text, session_id text, client_id text, scope text, namespace text
      )
      """
    ]

    Enum.each(statements, &repo.query!/1)
  end

  defp assert_reciprocal_source_checks(repo, prefix) do
    q = &~s("#{prefix}".#{&1})
    ids = Map.new(~w(memory crystal event summary), &{&1, Ecto.UUID.generate()})
    revision = String.duplicate("0", 64)

    repo.query!(
      "INSERT INTO #{q.("bpm_memories")} (id, memory_type, host_id, client_id, scope, namespace, session_id, lifecycle_state) VALUES ($1, 'episodic', 'h', 'c', 's', 'n', 'session', 'active')",
      [Ecto.UUID.dump!(ids["memory"])]
    )

    repo.query!(
      "INSERT INTO #{q.("bpm_projected_sessions")} (subject_id, host_id, session_id, client_id, scope, namespace) VALUES ('subject', 'h', 'session', 'c', 's', 'n')"
    )

    repo.query!(
      "INSERT INTO #{q.("memory_summaries")} (id, subject_id, host_id, session_id, input_revision) VALUES ($1, 'subject', 'h', 'session', $2)",
      [Ecto.UUID.dump!(ids["summary"]), revision]
    )

    repo.query!(
      "INSERT INTO #{q.("bpm_events")} (id, schema_version, host_id, client_id, scope, namespace, session_id) VALUES ($1, 1, 'h', 'c', 's', 'n', 'session')",
      [Ecto.UUID.dump!(ids["event"])]
    )

    repo.query!(
      """
      INSERT INTO #{q.("memory_crystals")}
        (id, memory_id, subject_id, host_id, client_id, scope, namespace, source_session_id,
         title, narrative, processing_version, prompt_version, input_revision, output_revision,
         status, inserted_at, updated_at)
      VALUES ($1, $2, 'subject', 'h', 'c', 's', 'n', 'session', 'title', 'narrative',
              'crystal-v1', 'prompt-v1', $3, $3, 'complete', now(), now())
      """,
      [Ecto.UUID.dump!(ids["crystal"]), Ecto.UUID.dump!(ids["memory"]), revision]
    )

    repo.query!(
      "INSERT INTO #{q.("memory_crystal_source_events")} (crystal_id, event_id, inserted_at) VALUES ($1, $2, now())",
      [Ecto.UUID.dump!(ids["crystal"]), Ecto.UUID.dump!(ids["event"])]
    )

    repo.query!(
      "INSERT INTO #{q.("memory_crystal_source_summaries")} (crystal_id, summary_id, inserted_at) VALUES ($1, $2, now())",
      [Ecto.UUID.dump!(ids["crystal"]), Ecto.UUID.dump!(ids["summary"])]
    )

    event_error =
      assert_raise Postgrex.Error, fn ->
        repo.transaction(fn ->
          repo.query!("UPDATE #{q.("bpm_memories")} SET namespace = 'moved' WHERE id = $1", [
            Ecto.UUID.dump!(ids["memory"])
          ])

          repo.query!("UPDATE #{q.("memory_crystals")} SET namespace = 'moved' WHERE id = $1", [
            Ecto.UUID.dump!(ids["crystal"])
          ])

          repo.query!("SET CONSTRAINTS ALL IMMEDIATE")
        end)
      end

    assert event_error.postgres.constraint == "memory_crystal_event_source_check"

    summary_error =
      assert_raise Postgrex.Error, fn ->
        repo.transaction(fn ->
          repo.query!("UPDATE #{q.("memory_crystals")} SET input_revision = $1 WHERE id = $2", [
            String.duplicate("a", 64),
            Ecto.UUID.dump!(ids["crystal"])
          ])

          repo.query!("SET CONSTRAINTS ALL IMMEDIATE")
        end)
      end

    assert summary_error.postgres.constraint == "memory_crystal_summary_source_check"
  end

  defp relation_oid(repo, name) do
    case repo.query!("SELECT to_regclass($1)::oid", [name]).rows do
      [[nil]] -> nil
      [[oid]] -> oid
    end
  end

  defp trigger_names(repo, prefix, table) do
    repo.query!(
      """
      SELECT trigger_name
      FROM information_schema.triggers
      WHERE event_object_schema = $1 AND event_object_table = $2
      """,
      [prefix, table]
    ).rows
    |> List.flatten()
  end

  defp migrate(repo, prefix, direction) do
    apply(Ecto.Migrator, direction, [repo, @version, @migration, [prefix: prefix, log: false]])
  end

  defp start_migration_repo do
    config = Application.fetch_env!(:backplane_system, Backplane.Repo)
    start_supervised!({Backplane.Memory.CrystalMigrationTestRepo, config})
    Backplane.Memory.CrystalMigrationTestRepo
  end

  defp load_migration do
    :backplane_system
    |> Application.app_dir("priv/repo/migrations/20260812000014_create_memory_crystals.exs")
    |> Code.require_file()
  end
end

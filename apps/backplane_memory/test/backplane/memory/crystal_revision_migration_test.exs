defmodule Backplane.Memory.CrystalRevisionMigrationTestRepo do
  use Ecto.Repo, otp_app: :backplane_system, adapter: Ecto.Adapters.Postgres
end

defmodule Backplane.Memory.CrystalRevisionMigrationTest do
  use Backplane.Memory.DataCase, async: false

  @original Backplane.Repo.Migrations.CreateMemoryCrystals
  @migration Backplane.Repo.Migrations.AllowSessionCrystalRevisionRefresh
  @version 20_261_020_000_003

  test "revision migration retains immutable history, validates current evidence, and rolls back safely" do
    repo = Backplane.Memory.CrystalRevisionMigrationTestRepo
    start_supervised!({repo, Application.fetch_env!(:backplane_system, Backplane.Repo)})
    prefix = "crystal_revision_#{System.unique_integer([:positive])}"
    p = ~s("#{prefix}")

    for file <- [
          "20260812000014_create_memory_crystals.exs",
          "20261020000003_allow_session_crystal_revision_refresh.exs"
        ] do
      Code.require_file(Application.app_dir(:backplane_system, "priv/repo/migrations/#{file}"))
    end

    original_public = function_def(repo, "public")
    repo.query!("CREATE SCHEMA #{p}")

    try do
      prerequisites(repo, p)
      :ok = Ecto.Migrator.up(repo, 20_260_812_000_014, @original, prefix: prefix, log: false)

      repo.query!(
        "ALTER TABLE #{p}.memory_crystals ADD memory_space_id uuid, ADD source_kind text NOT NULL DEFAULT 'session'"
      )

      :ok = migrate(repo, prefix, :up)
      ids = seed(repo, p)

      # Old-schema compatibility before any refresh, without touching public functions.
      assert :ok = migrate(repo, prefix, :down)
      assert :ok = migrate(repo, prefix, :up)
      assert function_def(repo, "public") == original_public

      for statement <- [
            "UPDATE #{p}.memory_crystals SET subject_id = 'foreign'",
            "UPDATE #{p}.memory_crystals SET memory_space_id = '#{Ecto.UUID.generate()}'",
            "UPDATE #{p}.memory_crystals SET input_revision = '#{revision(2)}'",
            "UPDATE #{p}.bpm_memories SET memory_type = 'semantic'",
            "UPDATE #{p}.bpm_memories SET memory_space_id = '#{Ecto.UUID.generate()}'"
          ] do
        rejects(repo, fn -> repo.query!(statement) end)
      end

      for table <- ~w(memory_crystal_source_summaries memory_crystal_source_events),
          statement <- [
            "UPDATE #{p}.#{table} SET inserted_at = now()",
            "DELETE FROM #{p}.#{table}",
            "TRUNCATE #{p}.#{table}"
          ] do
        assert rejects(repo, fn -> repo.query!(statement) end).postgres.constraint ==
                 "memory_crystal_source_immutable"
      end

      # A summary with the right revision but another subject is never current evidence.
      repo.query!(
        "INSERT INTO #{p}.bpm_projected_sessions SELECT 'foreign', host_id, session_id, client_id, scope, namespace, memory_space_id, input_revision FROM #{p}.bpm_projected_sessions"
      )

      wrong = Ecto.UUID.generate()

      repo.query!(
        "INSERT INTO #{p}.memory_summaries SELECT '#{wrong}', 'foreign', host_id, session_id, input_revision, memory_space_id, scope, namespace, processing_version FROM #{p}.memory_summaries"
      )

      assert rejects(repo, fn -> link(repo, p, ids.crystal, wrong) end).postgres.constraint ==
               "memory_crystal_summary_source_check"

      # R2 requires both an R2 summary link and the matching current projection.
      second = Ecto.UUID.generate()

      repo.query!(
        "INSERT INTO #{p}.memory_summaries SELECT '#{second}', subject_id, host_id, session_id, '#{revision(2)}', memory_space_id, scope, namespace, processing_version FROM #{p}.memory_summaries WHERE id = '#{ids.summary}'"
      )

      assert rejects(repo, fn ->
               repo.query!("UPDATE #{p}.memory_crystals SET input_revision = '#{revision(2)}'")
               link(repo, p, ids.crystal, second)
             end).postgres.constraint == "memory_crystal_summary_source_check"

      repo.query!(
        "UPDATE #{p}.bpm_projected_sessions SET input_revision = '#{revision(2)}' WHERE subject_id = 'subject'"
      )

      assert rejects(repo, fn ->
               repo.query!("UPDATE #{p}.memory_crystals SET input_revision = '#{revision(2)}'")
             end).postgres.constraint == "memory_crystal_summary_source_check"

      assert {:ok, _} =
               repo.transaction(fn ->
                 repo.query!("UPDATE #{p}.memory_crystals SET input_revision = '#{revision(2)}'")
                 link(repo, p, ids.crystal, second)
                 repo.query!("SET CONSTRAINTS ALL IMMEDIATE")
               end)

      assert [[2]] = repo.query!("SELECT count(*) FROM #{p}.memory_crystal_source_summaries").rows

      assert rejects(repo, fn ->
               repo.query!("UPDATE #{p}.memory_crystals SET input_revision = '#{revision(1)}'")
             end).postgres.constraint == "memory_crystal_summary_source_check"

      # Current parent governance is permitted without changing partition/type.
      repo.query!("UPDATE #{p}.bpm_memories SET lifecycle_state = 'archived'")

      repo.query!(
        "UPDATE #{p}.bpm_memories SET lifecycle_state = 'tombstoned', deleted_at = now()"
      )

      assert_raise Postgrex.Error, ~r/cannot restore crystal constraints/, fn ->
        migrate(repo, prefix, :down)
      end

      assert [[2]] = repo.query!("SELECT count(*) FROM #{p}.memory_crystal_source_summaries").rows
      assert function_def(repo, "public") == original_public
    after
      repo.query!("DROP SCHEMA IF EXISTS #{p} CASCADE")
    end
  end

  defp prerequisites(repo, p) do
    for sql <- [
          "CREATE TABLE #{p}.bpm_memories (id uuid PRIMARY KEY, memory_type text, host_id text, client_id text, scope text, namespace text, session_id text, deleted_at timestamp, lifecycle_state text, memory_space_id uuid)",
          "CREATE TABLE #{p}.memory_summaries (id uuid PRIMARY KEY, subject_id text, host_id text, session_id text, input_revision text, memory_space_id uuid, scope text, namespace text, processing_version text)",
          "CREATE TABLE #{p}.bpm_projected_sessions (subject_id text PRIMARY KEY, host_id text, session_id text, client_id text, scope text, namespace text, memory_space_id uuid, input_revision text)",
          "CREATE TABLE #{p}.bpm_events (id uuid PRIMARY KEY, schema_version integer, host_id text, client_id text, scope text, namespace text, session_id text)",
          "CREATE TABLE #{p}.memory_lessons (memory_id uuid UNIQUE)"
        ],
        do: repo.query!(sql)
  end

  defp seed(repo, p) do
    ids = Map.new(~w(memory crystal summary event space)a, &{&1, Ecto.UUID.generate()})
    r = revision(1)

    repo.query!(
      "INSERT INTO #{p}.bpm_memories VALUES ('#{ids.memory}', 'episodic', 'h', 'c', 's', 'n', 'session', NULL, 'active', '#{ids.space}')"
    )

    repo.query!(
      "INSERT INTO #{p}.bpm_projected_sessions VALUES ('subject', 'h', 'session', 'c', 's', 'n', '#{ids.space}', '#{r}')"
    )

    repo.query!(
      "INSERT INTO #{p}.memory_summaries VALUES ('#{ids.summary}', 'subject', 'h', 'session', '#{r}', '#{ids.space}', 's', 'n', 'summary-v1')"
    )

    repo.query!(
      "INSERT INTO #{p}.bpm_events VALUES ('#{ids.event}', 1, 'h', 'c', 's', 'n', 'session')"
    )

    {:ok, _} =
      repo.transaction(fn ->
        repo.query!("""
        INSERT INTO #{p}.memory_crystals
          (id, memory_id, subject_id, host_id, client_id, scope, namespace, source_session_id,
           title, narrative, processing_version, prompt_version, input_revision, output_revision,
           status, inserted_at, updated_at, memory_space_id)
        VALUES ('#{ids.crystal}', '#{ids.memory}', 'subject', 'h', 'c', 's', 'n', 'session',
          'title', 'narrative', 'crystal-v1', 'prompt', '#{r}', '#{r}', 'complete', now(), now(), '#{ids.space}')
        """)

        link(repo, p, ids.crystal, ids.summary)

        repo.query!(
          "INSERT INTO #{p}.memory_crystal_source_events VALUES ('#{ids.crystal}', '#{ids.event}', now())"
        )
      end)

    ids
  end

  defp link(repo, p, crystal, summary),
    do:
      repo.query!(
        "INSERT INTO #{p}.memory_crystal_source_summaries VALUES ('#{crystal}', '#{summary}', now())"
      )

  defp revision(n), do: String.duplicate(Integer.to_string(n), 64)

  defp rejects(repo, fun) do
    assert_raise Postgrex.Error, fn ->
      repo.transaction(fn ->
        fun.()
        repo.query!("SET CONSTRAINTS ALL IMMEDIATE")
      end)
    end
  end

  defp migrate(repo, prefix, direction),
    do:
      apply(Ecto.Migrator, direction, [repo, @version, @migration, [prefix: prefix, log: false]])

  defp function_def(repo, prefix),
    do:
      repo.query!("SELECT pg_get_functiondef($1::text::regprocedure)", [
        "#{prefix}.memory_crystal_summary_reciprocal_valid()"
      ]).rows
end

defmodule Backplane.Memory.SummaryIdentityMigrationTestRepo do
  use Ecto.Repo,
    otp_app: :backplane_system,
    adapter: Ecto.Adapters.Postgres
end

defmodule Backplane.Memory.SummaryIdentityMigrationTest do
  use Backplane.Memory.DataCase, async: false

  @version 20_260_812_000_002
  @migration Backplane.Repo.Migrations.VersionCanonicalMemorySummaries

  test "prefix-aware up normalizes source ownership and down preserves colliding history and FK targets" do
    prefix = "summary_identity_#{System.unique_integer([:positive])}"
    migration_repo = start_migration_repo()

    with_schema(migration_repo, prefix, fn ->
      create_legacy_table(migration_repo, prefix)
      create_event_and_evidence_tables(migration_repo, prefix)
      id = Ecto.UUID.generate()
      memory_id = Ecto.UUID.generate()

      migration_repo.query!(
        ~s|INSERT INTO "#{prefix}".memory_summaries (id, session_id, project, content, observation_count, created_at) VALUES ($1, 'same', 'project', 'legacy', 1, now())|,
        [Ecto.UUID.dump!(id)]
      )

      migration_repo.query!(
        ~s|INSERT INTO "#{prefix}".bpm_memory_evidence (id, memory_id, source_summary_id) VALUES ($1, $2, $3)|,
        Enum.map([Ecto.UUID.generate(), memory_id, id], &Ecto.UUID.dump!/1)
      )

      load_migration()

      assert :ok =
               Ecto.Migrator.up(migration_repo, @version, @migration,
                 prefix: prefix,
                 log: false
               )

      assert [["legacy:same", "legacy", "legacy-v0", input_revision, output_revision]] =
               migration_repo.query!("""
               SELECT subject_id, host_id, processing_version, input_revision, output_revision
               FROM "#{prefix}".memory_summaries
               """).rows

      assert input_revision == Backplane.Memory.Summaries.Summary.legacy_input_revision("same")

      assert output_revision ==
               Backplane.Memory.Summaries.Summary.legacy_output_revision("legacy")

      assert [] ==
               migration_repo.query!(
                 """
                 SELECT column_name
                 FROM information_schema.columns
                 WHERE table_schema = $1 AND table_name = 'memory_summaries'
                   AND column_name IN ('subject_id', 'host_id', 'processing_version', 'input_revision', 'output_revision')
                   AND column_default IS NOT NULL
                 """,
                 [prefix]
               ).rows

      assert_raise Postgrex.Error, fn ->
        migration_repo.query!("""
        INSERT INTO "#{prefix}".memory_summaries
          (id, session_id, project, content, observation_count, created_at,
           subject_id, host_id, processing_version, input_revision, output_revision)
        VALUES (gen_random_uuid(), 'other', '', 'duplicate', 0, now(),
                'legacy:same', 'legacy', 'legacy-v0', repeat('a', 64), repeat('b', 64))
        """)
      end

      second_id = Ecto.UUID.generate()
      third_id = Ecto.UUID.generate()
      legacy_event_id = Ecto.UUID.generate()
      canonical_event_id = Ecto.UUID.generate()
      noncanonical_event_id = Ecto.UUID.generate()

      insert_event(migration_repo, prefix, legacy_event_id, "legacy", "same")
      insert_event(migration_repo, prefix, canonical_event_id, "host-a", "same")

      insert_event(
        migration_repo,
        prefix,
        noncanonical_event_id,
        "host-a",
        "same",
        nil
      )

      insert_canonical_summary(
        migration_repo,
        prefix,
        second_id,
        "same",
        "subject-a",
        "summary-v1"
      )

      insert_canonical_summary(
        migration_repo,
        prefix,
        third_id,
        "same",
        "subject-a",
        "summary-v1@history"
      )

      for summary_id <- [second_id, third_id] do
        migration_repo.query!(
          ~s|INSERT INTO "#{prefix}".bpm_memory_evidence (id, memory_id, source_summary_id) VALUES ($1, $2, $3)|,
          Enum.map([Ecto.UUID.generate(), Ecto.UUID.generate(), summary_id], &Ecto.UUID.dump!/1)
        )
      end

      insert_source(migration_repo, prefix, id, legacy_event_id, "legacy", "same")
      insert_source(migration_repo, prefix, second_id, canonical_event_id, "host-a", "same")

      assert_raise Postgrex.Error, fn ->
        insert_source(migration_repo, prefix, second_id, legacy_event_id, "host-a", "same")
      end

      assert_raise Postgrex.Error, fn ->
        insert_source(
          migration_repo,
          prefix,
          second_id,
          noncanonical_event_id,
          "host-a",
          "same"
        )
      end

      assert_raise Postgrex.Error, fn ->
        migration_repo.query!(
          ~s|UPDATE "#{prefix}".memory_summary_source_events SET host_id = host_id|
        )
      end

      assert_raise Postgrex.Error, fn ->
        migration_repo.query!(
          ~s|DELETE FROM "#{prefix}".memory_summary_source_events WHERE summary_id = $1|,
          [Ecto.UUID.dump!(second_id)]
        )
      end

      assert_raise Postgrex.Error, fn ->
        migration_repo.query!(~s|TRUNCATE "#{prefix}".memory_summary_source_events|)
      end

      assert [["event_id", "summary_id"]] =
               migration_repo.query!(
                 """
                 SELECT
                   (regexp_match(indexdef, '\\(([^,]+), ([^)]+)\\)'))[1],
                   (regexp_match(indexdef, '\\(([^,]+), ([^)]+)\\)'))[2]
                 FROM pg_indexes
                 WHERE schemaname = $1
                   AND tablename = 'memory_summary_source_events'
                   AND indexdef LIKE '%(event_id, summary_id)%'
                 """,
                 [prefix]
               ).rows

      assert :ok =
               Ecto.Migrator.down(migration_repo, @version, @migration,
                 prefix: prefix,
                 log: false
               )

      rows =
        migration_repo.query!(
          ~s|SELECT id::text, session_id FROM "#{prefix}".memory_summaries ORDER BY id|
        ).rows

      assert Enum.map(rows, &hd/1) |> Enum.sort() == Enum.sort([id, second_id, third_id])

      assert Enum.all?(rows, fn [row_id, session_id] ->
               session_id == "legacy-summary:#{row_id}:same"
             end)

      assert migration_repo.query!(
               ~s|SELECT source_summary_id::text FROM "#{prefix}".bpm_memory_evidence ORDER BY source_summary_id|
             ).rows
             |> Enum.map(&hd/1)
             |> Enum.sort() == Enum.sort([id, second_id, third_id])

      assert [] ==
               migration_repo.query!(
                 """
                 SELECT column_name
                 FROM information_schema.columns
                 WHERE table_schema = $1 AND table_name = 'memory_summaries'
                   AND column_name IN ('subject_id', 'host_id', 'processing_version', 'input_revision', 'output_revision')
                 """,
                 [prefix]
               ).rows
    end)
  end

  defp insert_canonical_summary(repo, prefix, id, session_id, subject_id, version) do
    repo.query!(
      """
      INSERT INTO "#{prefix}".memory_summaries
        (id, session_id, project, content, observation_count, created_at,
         subject_id, host_id, processing_version, input_revision, output_revision)
      VALUES ($1, $2, '', 'canonical', 0, now(), $3, 'host-a', $4, repeat('a', 64), repeat('b', 64))
      """,
      [Ecto.UUID.dump!(id), session_id, subject_id, version]
    )
  end

  defp insert_event(repo, prefix, id, host_id, session_id, schema_version \\ 1) do
    repo.query!(
      ~s|INSERT INTO "#{prefix}".bpm_events (id, host_id, session_id, schema_version) VALUES ($1, $2, $3, $4)|,
      [Ecto.UUID.dump!(id), host_id, session_id, schema_version]
    )
  end

  defp insert_source(repo, prefix, summary_id, event_id, host_id, session_id) do
    repo.query!(
      """
      INSERT INTO "#{prefix}".memory_summary_source_events
        (summary_id, event_id, host_id, session_id)
      VALUES ($1, $2, $3, $4)
      """,
      [Ecto.UUID.dump!(summary_id), Ecto.UUID.dump!(event_id), host_id, session_id]
    )
  end

  defp create_legacy_table(repo, prefix) do
    repo.query!("""
    CREATE TABLE "#{prefix}".memory_summaries (
      id uuid PRIMARY KEY,
      session_id text NOT NULL,
      project text DEFAULT '',
      content text NOT NULL,
      observation_count integer DEFAULT 0,
      created_at timestamp(6) with time zone NOT NULL
    )
    """)

    repo.query!(
      ~s|CREATE UNIQUE INDEX memory_summaries_session_id_index ON "#{prefix}".memory_summaries (session_id)|
    )
  end

  defp create_event_and_evidence_tables(repo, prefix) do
    repo.query!("""
    CREATE FUNCTION "#{prefix}".bpm_reject_memory_provenance_mutation()
    RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      RAISE EXCEPTION 'memory provenance rows are immutable'
        USING ERRCODE = '55000';
    END;
    $$
    """)

    repo.query!("""
    CREATE TABLE "#{prefix}".bpm_events (
      id uuid PRIMARY KEY,
      host_id text,
      session_id text,
      schema_version integer
    )
    """)

    repo.query!("""
    CREATE TABLE "#{prefix}".bpm_memory_evidence (
      id uuid PRIMARY KEY,
      memory_id uuid NOT NULL,
      source_summary_id uuid REFERENCES "#{prefix}".memory_summaries(id) ON DELETE RESTRICT
    )
    """)
  end

  defp load_migration do
    :backplane_system
    |> Application.app_dir(
      "priv/repo/migrations/20260812000002_version_canonical_memory_summaries.exs"
    )
    |> Code.require_file()
  end

  defp start_migration_repo do
    config = repo().config() |> Keyword.delete(:pool) |> Keyword.put(:pool_size, 2)
    start_supervised!({Backplane.Memory.SummaryIdentityMigrationTestRepo, config})
    Backplane.Memory.SummaryIdentityMigrationTestRepo
  end

  defp with_schema(migration_repo, prefix, fun) do
    migration_repo.query!(~s|CREATE SCHEMA "#{prefix}"|)

    try do
      fun.()
    after
      migration_repo.query!(~s|DROP SCHEMA IF EXISTS "#{prefix}" CASCADE|)
    end
  end
end

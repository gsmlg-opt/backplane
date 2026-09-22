defmodule Backplane.Memory.CompletePartitionMigrationTestRepo do
  use Ecto.Repo,
    otp_app: :backplane_system,
    adapter: Ecto.Adapters.Postgres
end

defmodule Backplane.Memory.CompletePartitionMigrationTest do
  use Backplane.Memory.DataCase, async: false

  @version 20_260_905_000_007
  @migration Backplane.Repo.Migrations.EnforceCompleteMemoryPartition
  @migration_file "20260905000007_enforce_complete_memory_partition.exs"
  @dependent_tables ~w(
    bpm_memory_remember_requests
    memory_crystals
    bpm_memory_evidence
    bpm_memory_relations
    bpm_memory_relation_evidence
    bpm_host_memory_revocations
    memory_lessons
    memory_crystal_lessons
    memory_crystal_source_actions
    memory_crystal_source_events
    memory_crystal_source_summaries
  )
  @immutable_tables @dependent_tables -- ["memory_lessons"]

  test "quarantines every incomplete memory before validating complete partition constraints" do
    start_migration_repo()
    prefix = "complete_memory_partition_#{System.unique_integer([:positive])}"
    migration_repo().query!(~s|CREATE SCHEMA "#{prefix}"|)

    on_exit(fn -> Backplane.Repo.query!(~s|DROP SCHEMA IF EXISTS "#{prefix}" CASCADE|) end)

    create_tables(prefix)
    complete_id = insert_memory(prefix, %{})

    incomplete_ids =
      for {field, value} <- [
            memory_space_id: nil,
            host_id: " ",
            client_id: nil,
            scope: "",
            namespace: "   "
          ] do
        insert_memory(prefix, %{field => value})
      end

    migration_repo().query!(
      ~s|UPDATE "#{prefix}".bpm_memories SET superseded_by = $1::text::uuid WHERE id = $2::text::uuid|,
      [hd(incomplete_ids), complete_id]
    )

    seed_dependent_history(prefix, complete_id, hd(incomplete_ids))

    load_migration()

    assert :ok =
             Ecto.Migrator.up(migration_repo(), @version, @migration, prefix: prefix, log: false)

    assert [[^complete_id]] =
             migration_repo().query!(~s|SELECT id::text FROM "#{prefix}".bpm_memories|).rows

    assert [[nil]] =
             migration_repo().query!(
               ~s|SELECT superseded_by FROM "#{prefix}".bpm_memories WHERE id = $1::text::uuid|,
               [complete_id]
             ).rows

    issues =
      migration_repo().query!(
        ~s|SELECT source_id, reason, disposition, details FROM "#{prefix}".bpm_memory_space_backfill_issues ORDER BY source_id|
      ).rows

    assert Enum.sort(Enum.map(issues, &hd/1)) == Enum.sort(incomplete_ids)

    assert Enum.all?(issues, fn [_source_id, "incomplete_partition", "pending", details] ->
             Map.keys(details) |> Enum.sort() ==
               ~w(client_id host_id memory_space_id missing_fields namespace scope)

             is_list(details["missing_fields"]) and details["missing_fields"] != [] and
               not Map.has_key?(details, "content") and
               not Map.has_key?(details, "metadata") and
               not Map.has_key?(details, "evidence") and
               not (inspect(details) =~ "private memory content")
           end)

    assert_dependent_history_cleaned(prefix)

    assert [[5]] =
             migration_repo().query!(
               ~s|SELECT count(*) FROM "#{prefix}".bpm_memory_changes WHERE operation = 'DELETE'|
             ).rows

    assert [[0]] =
             migration_repo().query!("""
             SELECT count(*)
             FROM pg_trigger
             WHERE tgrelid IN (
               SELECT oid FROM pg_class
               WHERE relnamespace = '#{prefix}'::regnamespace
             )
               AND tgname LIKE 'fixture_immutable_%'
               AND tgenabled <> 'O'
             """).rows

    assert_raise Postgrex.Error, ~r/fixture history is immutable/, fn ->
      migration_repo().query!(
        ~s|DELETE FROM "#{prefix}".bpm_memory_remember_requests WHERE memory_id = $1::text::uuid|,
        [complete_id]
      )
    end

    assert :ok = apply(@migration, :enforce, [migration_repo(), prefix])

    assert [[5]] =
             migration_repo().query!(
               ~s|SELECT count(*) FROM "#{prefix}".bpm_memory_space_backfill_issues|
             ).rows

    for field <- ~w(memory_space_id host_id client_id scope namespace), invalid <- [nil, " "] do
      assert_raise Postgrex.Error, fn ->
        insert_memory(prefix, %{String.to_atom(field) => invalid})
      end

      assert_raise Postgrex.Error, fn ->
        cast = if field == "memory_space_id", do: "$1::text::uuid", else: "$1"

        migration_repo().query!(
          ~s|UPDATE "#{prefix}".bpm_memories SET "#{field}" = #{cast} WHERE id = $2::text::uuid|,
          [invalid, complete_id]
        )
      end
    end

    assert_raise Ecto.MigrationError, ~r/irreversible.*quarantined memory history/i, fn ->
      Ecto.Migrator.down(migration_repo(), @version, @migration,
        prefix: prefix,
        log: false
      )
    end

    assert [[5]] =
             migration_repo().query!(
               ~s|SELECT count(*) FROM "#{prefix}".bpm_memory_space_backfill_issues|
             ).rows

    assert [[^complete_id]] =
             migration_repo().query!(~s|SELECT id::text FROM "#{prefix}".bpm_memories|).rows

    assert [[@version]] =
             migration_repo().query!(
               ~s|SELECT version FROM "#{prefix}".schema_migrations WHERE version = #{@version}|
             ).rows
  end

  defp create_tables(prefix) do
    migration_repo().query!("""
    CREATE TABLE "#{prefix}".bpm_memory_space_backfill_issues (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      source_table text NOT NULL,
      source_id text NOT NULL,
      reason text NOT NULL,
      disposition text NOT NULL DEFAULT 'pending',
      details jsonb NOT NULL DEFAULT '{}',
      resolved_at timestamptz,
      inserted_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now(),
      UNIQUE (source_table, source_id)
    )
    """)

    migration_repo().query!("""
    CREATE TABLE "#{prefix}".bpm_memories (
      id uuid PRIMARY KEY,
      memory_space_id uuid,
      host_id text,
      client_id text,
      source_client_id text,
      scope text,
      namespace text,
      content text NOT NULL,
      metadata jsonb NOT NULL DEFAULT '{}',
      evidence jsonb NOT NULL DEFAULT '{}',
      superseded_by uuid REFERENCES "#{prefix}".bpm_memories(id) ON DELETE RESTRICT,
      inserted_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    create_dependent_tables(prefix)
    create_fixture_triggers(prefix)
  end

  defp create_dependent_tables(prefix) do
    migration_repo().query!("""
    CREATE TABLE "#{prefix}".bpm_memory_changes (
      id bigserial PRIMARY KEY,
      memory_id uuid NOT NULL,
      operation text NOT NULL
    )
    """)

    migration_repo().query!("""
    CREATE TABLE "#{prefix}".bpm_memory_remember_requests (
      id uuid PRIMARY KEY,
      memory_id uuid NOT NULL REFERENCES "#{prefix}".bpm_memories(id) ON DELETE RESTRICT
    )
    """)

    migration_repo().query!("""
    CREATE TABLE "#{prefix}".memory_crystals (
      id uuid PRIMARY KEY,
      memory_id uuid NOT NULL REFERENCES "#{prefix}".bpm_memories(id) ON DELETE RESTRICT
    )
    """)

    migration_repo().query!("""
    CREATE TABLE "#{prefix}".bpm_memory_evidence (
      id uuid PRIMARY KEY,
      memory_id uuid NOT NULL REFERENCES "#{prefix}".bpm_memories(id) ON DELETE RESTRICT,
      source_request_id uuid NOT NULL REFERENCES "#{prefix}".bpm_memory_remember_requests(id) ON DELETE RESTRICT,
      source_crystal_id uuid NOT NULL REFERENCES "#{prefix}".memory_crystals(id) ON DELETE RESTRICT
    )
    """)

    migration_repo().query!("""
    CREATE TABLE "#{prefix}".bpm_memory_relations (
      id uuid PRIMARY KEY,
      source_memory_id uuid NOT NULL REFERENCES "#{prefix}".bpm_memories(id) ON DELETE RESTRICT,
      target_memory_id uuid NOT NULL REFERENCES "#{prefix}".bpm_memories(id) ON DELETE RESTRICT
    )
    """)

    migration_repo().query!("""
    CREATE TABLE "#{prefix}".bpm_memory_relation_evidence (
      id uuid PRIMARY KEY,
      relation_id uuid NOT NULL REFERENCES "#{prefix}".bpm_memory_relations(id) ON DELETE RESTRICT,
      evidence_id uuid NOT NULL REFERENCES "#{prefix}".bpm_memory_evidence(id) ON DELETE RESTRICT
    )
    """)

    migration_repo().query!("""
    CREATE TABLE "#{prefix}".bpm_host_memory_revocations (
      id uuid PRIMARY KEY,
      memory_id uuid NOT NULL REFERENCES "#{prefix}".bpm_memories(id) ON DELETE RESTRICT,
      source_request_id uuid NOT NULL REFERENCES "#{prefix}".bpm_memory_remember_requests(id) ON DELETE RESTRICT
    )
    """)

    migration_repo().query!("""
    CREATE TABLE "#{prefix}".memory_lessons (
      memory_id uuid PRIMARY KEY REFERENCES "#{prefix}".bpm_memories(id) ON DELETE CASCADE
    )
    """)

    migration_repo().query!("""
    CREATE TABLE "#{prefix}".memory_crystal_lessons (
      id uuid PRIMARY KEY,
      crystal_id uuid NOT NULL REFERENCES "#{prefix}".memory_crystals(id) ON DELETE RESTRICT,
      lesson_memory_id uuid NOT NULL REFERENCES "#{prefix}".memory_lessons(memory_id) ON DELETE RESTRICT
    )
    """)

    for table <-
          ~w(memory_crystal_source_actions memory_crystal_source_events memory_crystal_source_summaries) do
      migration_repo().query!("""
      CREATE TABLE "#{prefix}"."#{table}" (
        id uuid PRIMARY KEY,
        crystal_id uuid NOT NULL REFERENCES "#{prefix}".memory_crystals(id) ON DELETE CASCADE
      )
      """)
    end
  end

  defp create_fixture_triggers(prefix) do
    migration_repo().query!("""
    CREATE FUNCTION "#{prefix}".capture_memory_delete() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      INSERT INTO "#{prefix}".bpm_memory_changes(memory_id, operation) VALUES (OLD.id, 'DELETE');
      RETURN OLD;
    END
    $$
    """)

    migration_repo().query!("""
    CREATE TRIGGER fixture_edge_capture
    AFTER DELETE ON "#{prefix}".bpm_memories
    FOR EACH ROW EXECUTE FUNCTION "#{prefix}".capture_memory_delete()
    """)

    migration_repo().query!("""
    CREATE FUNCTION "#{prefix}".reject_history_delete() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      RAISE EXCEPTION 'fixture history is immutable';
    END
    $$
    """)

    for table <- @immutable_tables do
      migration_repo().query!("""
      CREATE TRIGGER "fixture_immutable_#{table}"
      BEFORE DELETE ON "#{prefix}"."#{table}"
      FOR EACH ROW EXECUTE FUNCTION "#{prefix}".reject_history_delete()
      """)
    end
  end

  defp seed_dependent_history(prefix, complete_id, incomplete_id) do
    Enum.each([complete_id, incomplete_id], fn memory_id ->
      ids =
        for name <-
              ~w(request crystal evidence relation relation_evidence revocation crystal_lesson action event summary),
            into: %{} do
          {name, Ecto.UUID.generate()}
        end

      query_insert(prefix, "bpm_memory_remember_requests", ~w(id memory_id), [
        ids["request"],
        memory_id
      ])

      query_insert(prefix, "memory_crystals", ~w(id memory_id), [ids["crystal"], memory_id])

      query_insert(
        prefix,
        "bpm_memory_evidence",
        ~w(id memory_id source_request_id source_crystal_id),
        [
          ids["evidence"],
          memory_id,
          ids["request"],
          ids["crystal"]
        ]
      )

      query_insert(prefix, "bpm_memory_relations", ~w(id source_memory_id target_memory_id), [
        ids["relation"],
        memory_id,
        memory_id
      ])

      query_insert(prefix, "bpm_memory_relation_evidence", ~w(id relation_id evidence_id), [
        ids["relation_evidence"],
        ids["relation"],
        ids["evidence"]
      ])

      query_insert(prefix, "bpm_host_memory_revocations", ~w(id memory_id source_request_id), [
        ids["revocation"],
        memory_id,
        ids["request"]
      ])

      query_insert(prefix, "memory_lessons", ~w(memory_id), [memory_id])

      query_insert(prefix, "memory_crystal_lessons", ~w(id crystal_id lesson_memory_id), [
        ids["crystal_lesson"],
        ids["crystal"],
        memory_id
      ])

      for {table, id} <- [
            {"memory_crystal_source_actions", ids["action"]},
            {"memory_crystal_source_events", ids["event"]},
            {"memory_crystal_source_summaries", ids["summary"]}
          ] do
        query_insert(prefix, table, ~w(id crystal_id), [id, ids["crystal"]])
      end
    end)
  end

  defp query_insert(prefix, table, columns, values) do
    names = Enum.map_join(columns, ", ", &~s("#{&1}"))

    params =
      values
      |> Enum.with_index(1)
      |> Enum.map_join(", ", fn {_value, index} -> "$#{index}::text::uuid" end)

    migration_repo().query!(
      ~s|INSERT INTO "#{prefix}"."#{table}" (#{names}) VALUES (#{params})|,
      values
    )
  end

  defp assert_dependent_history_cleaned(prefix) do
    for table <- @dependent_tables do
      assert [[1]] =
               migration_repo().query!(~s|SELECT count(*) FROM "#{prefix}"."#{table}"|).rows
    end
  end

  defp insert_memory(prefix, overrides) do
    attrs =
      Map.merge(
        %{
          id: Ecto.UUID.generate(),
          memory_space_id: Ecto.UUID.generate(),
          host_id: "host",
          client_id: "legacy-client",
          source_client_id: nil,
          scope: "scope",
          namespace: "private",
          content: "private memory content"
        },
        overrides
      )

    migration_repo().query!(
      """
      INSERT INTO "#{prefix}".bpm_memories
        (id, memory_space_id, host_id, client_id, source_client_id, scope, namespace, content)
      VALUES ($1::text::uuid, $2::text::uuid, $3, $4, $5, $6, $7, $8)
      """,
      [
        attrs.id,
        attrs.memory_space_id,
        attrs.host_id,
        attrs.client_id,
        attrs.source_client_id,
        attrs.scope,
        attrs.namespace,
        attrs.content
      ]
    )

    attrs.id
  end

  defp load_migration do
    path =
      Path.expand(
        "../../../../backplane_system/priv/repo/migrations/#{@migration_file}",
        __DIR__
      )

    Code.require_file(path)
  end

  defp start_migration_repo do
    config =
      repo().config()
      |> Keyword.delete(:pool)
      |> Keyword.put(:pool_size, 2)

    start_supervised!({migration_repo(), config})
  end

  defp migration_repo, do: Backplane.Memory.CompletePartitionMigrationTestRepo
end

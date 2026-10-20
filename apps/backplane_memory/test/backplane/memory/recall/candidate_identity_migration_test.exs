defmodule Backplane.Memory.Recall.CandidateIdentityMigrationTestRepo do
  use Ecto.Repo, otp_app: :backplane_system, adapter: Ecto.Adapters.Postgres
end

defmodule Backplane.Memory.Recall.CandidateIdentityMigrationTest do
  use Backplane.Memory.DataCase, async: false

  @space "62a66140-e479-85c1-892d-8b6d6b77aba1"
  @partition %{memory_space_id: @space, scope: "team", namespace: "private"}
  @original_version 20_261_020_000_001
  @original_migration Backplane.Repo.Migrations.AlignMemoryRecallCandidateIdentity
  @version 20_261_020_000_002
  @migration Backplane.Repo.Migrations.CorrectMemoryRecallRequestSource

  setup_all do
    config = repo().config() |> Keyword.delete(:pool) |> Keyword.put(:pool_size, 2)
    migration_repo = Backplane.Memory.Recall.CandidateIdentityMigrationTestRepo
    start_supervised!({migration_repo, config})
    {:ok, repo: migration_repo}
  end

  setup %{repo: migration_repo} = tags do
    prefix = "recall_identity_#{System.unique_integer([:positive])}"
    migration_repo.query!(~s|CREATE SCHEMA "#{prefix}"|)
    on_exit(fn -> migration_repo.query!(~s|DROP SCHEMA IF EXISTS "#{prefix}" CASCADE|) end)
    create_tables(migration_repo, prefix)
    install_original_guard(migration_repo, prefix)

    Code.require_file(
      Path.expand(
        "../../../support/historical_migrations/align_memory_recall_candidate_identity.exs",
        __DIR__
      )
    )

    assert :ok =
             Ecto.Migrator.up(migration_repo, @original_version, @original_migration,
               prefix: prefix,
               log: false
             )

    Code.require_file(
      Application.app_dir(
        :backplane_system,
        "priv/repo/migrations/20261020000002_correct_memory_recall_request_source.exs"
      )
    )

    unless tags[:unrepaired] do
      assert :ok =
               Ecto.Migrator.up(migration_repo, @version, @migration, prefix: prefix, log: false)
    end

    run_id = insert_root(migration_repo, prefix, "memory_recall_runs")

    migration_repo.query!(
      ~s|UPDATE "#{prefix}".memory_recall_runs SET host_id = 'run-host', client_id = 'run-client'|
    )

    {:ok, repo: migration_repo, prefix: prefix, run_id: run_id}
  end

  @tag unrepaired: true
  test "repairs an already-applied guard using the canonical request table without an alias",
       ctx do
    assert [[nil]] =
             ctx.repo.query!("SELECT to_regclass($1)", ["#{ctx.prefix}.memory_remember_requests"]).rows

    memory_id = insert_root(ctx.repo, ctx.prefix, "bpm_memories")
    error = assert_raise Postgrex.Error, fn -> insert_candidate(ctx, "memory", memory_id) end
    assert error.postgres.code == :undefined_table

    assert :ok =
             Ecto.Migrator.up(ctx.repo, @version, @migration, prefix: ctx.prefix, log: false)

    assert insert_candidate(ctx, "memory", memory_id).num_rows == 1

    request_id =
      insert_root(ctx.repo, ctx.prefix, "bpm_memory_remember_requests", %{memory_id: memory_id})

    assert insert_candidate(ctx, "request", request_id).num_rows == 1
    assert_rejected(fn -> insert_candidate(ctx, "request", Ecto.UUID.generate()) end)
  end

  test "the forward-only migration refuses to restore obsolete identity validation", ctx do
    assert_raise Ecto.MigrationError,
                 ~r/current recall candidate identities cannot be discarded/,
                 fn ->
                   Ecto.Migrator.down(ctx.repo, @version, @migration,
                     prefix: ctx.prefix,
                     log: false
                   )
                 end

    memory_id = insert_root(ctx.repo, ctx.prefix, "bpm_memories")
    insert_root(ctx.repo, ctx.prefix, "memory_crystals", %{memory_id: memory_id})
    assert insert_candidate(ctx, "crystal", memory_id).num_rows == 1
  end

  test "crystal memory and legacy record IDs share canonically across artifact hosts and clients",
       ctx do
    memory_id = insert_root(ctx.repo, ctx.prefix, "bpm_memories")
    crystal_id = insert_root(ctx.repo, ctx.prefix, "memory_crystals", %{memory_id: memory_id})
    assert insert_candidate(ctx, "crystal", memory_id).num_rows == 1
    assert insert_candidate(ctx, "crystal", crystal_id).num_rows == 1
  end

  test "captured event and legacy observation IDs share canonically across artifact hosts and clients",
       ctx do
    event_id = insert_root(ctx.repo, ctx.prefix, "bpm_events")
    insert_projection(ctx, event_id)
    observation_id = insert_root(ctx.repo, ctx.prefix, "bpm_observations")
    assert insert_candidate(ctx, "observation", event_id).num_rows == 1
    assert insert_candidate(ctx, "observation", observation_id).num_rows == 1
  end

  test "crystal identity requires both the memory and crystal in the run partition", ctx do
    for mismatch <- mismatches() do
      foreign_memory = insert_root(ctx.repo, ctx.prefix, "bpm_memories", mismatch)

      crystal_id =
        insert_root(ctx.repo, ctx.prefix, "memory_crystals", %{memory_id: foreign_memory})

      assert_rejected(fn -> insert_candidate(ctx, "crystal", foreign_memory) end)
      assert_rejected(fn -> insert_candidate(ctx, "crystal", crystal_id) end)

      local_memory = insert_root(ctx.repo, ctx.prefix, "bpm_memories")

      foreign_crystal =
        insert_root(
          ctx.repo,
          ctx.prefix,
          "memory_crystals",
          Map.put(mismatch, :memory_id, local_memory)
        )

      assert_rejected(fn -> insert_candidate(ctx, "crystal", local_memory) end)
      assert_rejected(fn -> insert_candidate(ctx, "crystal", foreign_crystal) end)
    end

    orphan_memory = insert_root(ctx.repo, ctx.prefix, "bpm_memories")
    assert_rejected(fn -> insert_candidate(ctx, "crystal", orphan_memory) end)
  end

  test "captured observation identity requires the event and projection in the run partition",
       ctx do
    for mismatch <- mismatches() do
      foreign_event = insert_root(ctx.repo, ctx.prefix, "bpm_events", mismatch)
      insert_projection(ctx, foreign_event)
      assert_rejected(fn -> insert_candidate(ctx, "observation", foreign_event) end)

      local_event = insert_root(ctx.repo, ctx.prefix, "bpm_events")
      insert_projection(ctx, local_event, mismatch)
      assert_rejected(fn -> insert_candidate(ctx, "observation", local_event) end)
    end

    event_without_projection = insert_root(ctx.repo, ctx.prefix, "bpm_events")
    assert_rejected(fn -> insert_candidate(ctx, "observation", event_without_projection) end)
  end

  test "unchanged artifact kinds retain canonical checks and reject missing owners", ctx do
    for {kind, table} <- [
          {"memory", "bpm_memories"},
          {"lesson", "bpm_memories"},
          {"event", "bpm_events"},
          {"summary", "memory_summaries"},
          {"observation", "bpm_observations"}
        ] do
      local = insert_root(ctx.repo, ctx.prefix, table)
      assert insert_candidate(ctx, kind, local).num_rows == 1

      for mismatch <- mismatches() do
        foreign = insert_root(ctx.repo, ctx.prefix, table, mismatch)
        assert_rejected(fn -> insert_candidate(ctx, kind, foreign) end)
      end

      assert_rejected(fn -> insert_candidate(ctx, kind, Ecto.UUID.generate()) end)
    end

    memory_id = insert_root(ctx.repo, ctx.prefix, "bpm_memories")

    request_id =
      insert_root(ctx.repo, ctx.prefix, "bpm_memory_remember_requests", %{memory_id: memory_id})

    assert insert_candidate(ctx, "request", request_id).num_rows == 1

    for mismatch <- mismatches() do
      foreign_memory = insert_root(ctx.repo, ctx.prefix, "bpm_memories", mismatch)

      foreign_request =
        insert_root(ctx.repo, ctx.prefix, "bpm_memory_remember_requests", %{
          memory_id: foreign_memory
        })

      assert_rejected(fn -> insert_candidate(ctx, "request", foreign_request) end)
    end

    assert_rejected(fn -> insert_candidate(ctx, "unknown", memory_id) end)

    assert_rejected(fn ->
      insert_candidate(%{ctx | run_id: Ecto.UUID.generate()}, "memory", memory_id)
    end)
  end

  test "updates and incomplete run partitions cannot bypass the retained guard", ctx do
    memory_id = insert_root(ctx.repo, ctx.prefix, "bpm_memories")
    insert_candidate(ctx, "memory", memory_id)

    assert_rejected(fn ->
      ctx.repo.query!(
        ~s|UPDATE "#{ctx.prefix}".memory_recall_candidates SET candidate_id = $1|,
        [uuid(Ecto.UUID.generate())]
      )
    end)

    for mismatch <- mismatches() do
      other_run = insert_root(ctx.repo, ctx.prefix, "memory_recall_runs", mismatch)

      assert_rejected(fn ->
        insert_candidate(%{ctx | run_id: other_run}, "memory", memory_id)
      end)
    end
  end

  # Minimal pre-migration guard fixture preserves the old crystal-record and legacy
  # observation identities. Artifact host/client differ deliberately: canonical
  # sharing is memory_space_id + scope + namespace; those fields are provenance.
  defp install_original_guard(repo, p) do
    repo.query!("""
    CREATE FUNCTION "#{p}".bpm_assert_memory_recall_candidates_canonical_partition()
    RETURNS trigger AS $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM "#{p}".memory_recall_runs r
        LEFT JOIN "#{p}".memory_crystals c ON c.id = NEW.candidate_id
        LEFT JOIN "#{p}".bpm_observations o ON o.id = NEW.candidate_id
        WHERE r.id = NEW.recall_run_id AND r.memory_space_id IS NOT NULL
          AND CASE NEW.candidate_kind
            WHEN 'crystal' THEN (r.memory_space_id, r.scope, r.namespace) = (c.memory_space_id, c.scope, c.namespace)
            WHEN 'observation' THEN (r.memory_space_id, r.scope, r.namespace) = (o.memory_space_id, o.scope, o.namespace)
            ELSE false END
      ) THEN
        RAISE EXCEPTION 'candidate crosses canonical memory partition'
          USING ERRCODE = '23514', CONSTRAINT = 'memory_recall_candidates_canonical_partition';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    repo.query!("""
    CREATE CONSTRAINT TRIGGER bpm_memory_space_child_partition_guard
    AFTER INSERT OR UPDATE ON "#{p}".memory_recall_candidates
    DEFERRABLE INITIALLY IMMEDIATE FOR EACH ROW
    EXECUTE FUNCTION "#{p}".bpm_assert_memory_recall_candidates_canonical_partition()
    """)
  end

  defp create_tables(repo, p) do
    repo.query!("""
    CREATE FUNCTION "#{p}".bpm_memory_partitions_match(left_row jsonb, right_row jsonb)
    RETURNS boolean AS $$
      SELECT nullif(btrim(left_row ->> 'memory_space_id'), '') IS NOT NULL
         AND nullif(btrim(left_row ->> 'scope'), '') IS NOT NULL
         AND nullif(btrim(left_row ->> 'namespace'), '') IS NOT NULL
         AND left_row ->> 'memory_space_id' = right_row ->> 'memory_space_id'
         AND left_row ->> 'scope' = right_row ->> 'scope'
         AND left_row ->> 'namespace' = right_row ->> 'namespace'
    $$ LANGUAGE sql IMMUTABLE
    """)

    for table <-
          ~w(memory_recall_runs bpm_memories bpm_events bpm_observations memory_summaries bpm_memory_remember_requests memory_crystals) do
      repo.query!("""
      CREATE TABLE "#{p}".#{table} (
        id uuid PRIMARY KEY, memory_space_id uuid, scope text, namespace text,
        host_id text DEFAULT 'artifact-host', client_id text DEFAULT 'artifact-client', memory_id uuid
      )
      """)
    end

    repo.query!("""
    CREATE TABLE "#{p}".bpm_projected_observations (
      event_id uuid PRIMARY KEY, memory_space_id uuid, scope text, namespace text
    )
    """)

    repo.query!("""
    CREATE TABLE "#{p}".memory_recall_candidates (
      id uuid PRIMARY KEY, recall_run_id uuid, candidate_id uuid, candidate_kind text,
      host_id text DEFAULT 'run-host', client_id text DEFAULT 'run-client',
      scope text DEFAULT 'team', namespace text DEFAULT 'private'
    )
    """)
  end

  defp insert_root(repo, p, table, overrides \\ %{}) do
    attrs =
      Map.merge(Map.merge(@partition, %{id: Ecto.UUID.generate(), memory_id: nil}), overrides)

    repo.query!(
      """
      INSERT INTO "#{p}".#{table} (id, memory_space_id, scope, namespace, memory_id)
      VALUES ($1, $2, $3, $4, $5)
      """,
      [
        uuid(attrs.id),
        uuid(attrs.memory_space_id),
        attrs.scope,
        attrs.namespace,
        uuid(attrs.memory_id)
      ]
    )

    attrs.id
  end

  defp insert_projection(ctx, event_id, overrides \\ %{}) do
    attrs = Map.merge(@partition, overrides)

    ctx.repo.query!(
      """
      INSERT INTO "#{ctx.prefix}".bpm_projected_observations (event_id, memory_space_id, scope, namespace)
      VALUES ($1, $2, $3, $4)
      """,
      [uuid(event_id), uuid(attrs.memory_space_id), attrs.scope, attrs.namespace]
    )
  end

  defp insert_candidate(ctx, kind, id) do
    ctx.repo.query!(
      """
      INSERT INTO "#{ctx.prefix}".memory_recall_candidates (id, recall_run_id, candidate_id, candidate_kind)
      VALUES (gen_random_uuid(), $1, $2, $3)
      """,
      [uuid(ctx.run_id), uuid(id), kind]
    )
  end

  defp assert_rejected(fun) do
    error = assert_raise Postgrex.Error, fun
    assert error.postgres.code == :check_violation
    assert error.postgres.constraint == "memory_recall_candidates_canonical_partition"
  end

  defp mismatches do
    [
      %{memory_space_id: Ecto.UUID.generate()},
      %{scope: "foreign-scope"},
      %{namespace: "foreign-namespace"},
      %{memory_space_id: nil},
      %{scope: ""},
      %{namespace: nil}
    ]
  end

  defp uuid(nil), do: nil
  defp uuid(id), do: Ecto.UUID.dump!(id)
end

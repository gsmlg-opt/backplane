defmodule Backplane.Repo.Migrations.ClientCredentialCompatibilityTestRepo do
  use Ecto.Repo, otp_app: :backplane_system, adapter: Ecto.Adapters.Postgres
end

defmodule Backplane.Repo.Migrations.ReconcileIndexedClientCredentialsTest do
  use ExUnit.Case, async: false

  @repo Backplane.Repo.Migrations.ClientCredentialCompatibilityTestRepo
  @auth_version 20_261_020_000_001
  @version 20_261_020_000_007
  @migration Backplane.Repo.Migrations.ReconcileIndexedClientCredentials

  setup_all do
    for filename <- [
          "20260410000003_create_clients.exs",
          "20261020000001_index_client_credentials.exs",
          "20261020000007_reconcile_indexed_client_credentials.exs"
        ] do
      Code.require_file(Path.join(migrations_path(), filename))
    end

    :ok
  end

  setup do
    config =
      Application.fetch_env!(:backplane_system, Backplane.Repo)
      |> Keyword.delete(:pool)
      |> Keyword.put(:pool_size, 2)

    start_supervised!({@repo, config})
    prefix = "client_compat_#{System.unique_integer([:positive])}"
    decoy = prefix <> "_decoy"

    for schema <- [prefix, decoy] do
      @repo.query!(~s|CREATE SCHEMA "#{schema}"|)
    end

    on_exit(fn ->
      {:ok, pid} = @repo.start_link(config)

      try do
        for schema <- [prefix, decoy] do
          @repo.query!(~s|DROP SCHEMA IF EXISTS "#{schema}" CASCADE|)
        end
      after
        GenServer.stop(pid)
      end
    end)

    %{prefix: prefix, decoy: decoy, config: config}
  end

  test "fresh installs apply the executable chain with no superseded recall guard", c do
    assert [_ | _] =
             Ecto.Migrator.run(@repo, migrations_path(), :up,
               prefix: c.prefix,
               all: true,
               log: false
             )

    assert @auth_version in versions(c.prefix)
    assert @version in versions(c.prefix)
    assert digest_columns(c.prefix) == [["token_digest", "bytea", "YES"]]

    assert [[definition]] =
             @repo.query!(
               """
               SELECT pg_get_functiondef(p.oid)
               FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
               WHERE n.nspname = $1 AND p.proname = 'bpm_assert_memory_recall_candidates_canonical_partition'
               """,
               [c.prefix]
             ).rows

    assert definition =~ "bpm_memory_remember_requests"
    refute definition =~ ~r/(?<!bpm_)memory_remember_requests/

    assert [] =
             Ecto.Migrator.run(@repo, migrations_path(), :up,
               prefix: c.prefix,
               all: true,
               log: false
             )
  end

  test "pre-auth clients keep IDs, scopes and protection metadata while hashes are invalidated",
       c do
    create_clients(c.prefix)
    seed_clients(c.prefix)
    before = client_metadata(c.prefix)
    assert [@auth_version, @version] = migrate_auth(c.prefix)
    assert client_metadata(c.prefix) == before
    assert_all_unissued(c.prefix)
    assert_digest_constraints(c.prefix)
  end

  test "collided Memory history is preserved and hash-only clients reconcile under a decoy search path",
       c do
    create_clients(c.prefix)
    seed_clients(c.prefix)
    create_clients(c.decoy)
    seed_clients(c.decoy)
    seed_history(c.prefix)
    seed_memory_history(c.prefix)
    before = client_metadata(c.prefix)
    history_before = versions(c.prefix)
    memory_before = memory_history(c.prefix)
    decoy_before = table_snapshot(c.decoy, "clients")

    stop_supervised(@repo)
    start_supervised!({@repo, Keyword.put(c.config, :parameters, search_path: c.decoy)})

    assert [@version] = migrate_auth(c.prefix)
    assert versions(c.prefix) == history_before ++ [@version]
    assert client_metadata(c.prefix) == before
    assert memory_history(c.prefix) == memory_before
    assert_all_unissued(c.prefix)
    assert table_snapshot(c.decoy, "clients") == decoy_before
    assert digest_columns(c.decoy) == [["token_hash", "text", "NO"]]
    assert [] = migrate_auth(c.prefix)
    assert_digest_constraints(c.prefix)
  end

  test "already indexed credentials retain issued digests and permit repeat validation", c do
    create_clients(c.prefix)
    seed_clients(c.prefix)

    assert :ok =
             Ecto.Migrator.up(
               @repo,
               @auth_version,
               Backplane.Repo.Migrations.IndexClientCredentials,
               prefix: c.prefix,
               log: false
             )

    digest = :crypto.strong_rand_bytes(32)

    @repo.query!(~s|UPDATE "#{c.prefix}".clients SET token_digest = $1 WHERE name = 'active'|, [
      digest
    ])

    before = table_snapshot(c.prefix, "clients")

    assert [@version] = migrate_auth(c.prefix)
    assert table_snapshot(c.prefix, "clients") == before
    assert [] = migrate_auth(c.prefix)
    # A second invocation with a different receipt also exercises the schema-validation branch.
    assert :ok = Ecto.Migrator.up(@repo, @version + 1, @migration, prefix: c.prefix, log: false)
    assert table_snapshot(c.prefix, "clients") == before

    assert_raise Ecto.MigrationError, ~r/irreversible/, fn ->
      Ecto.Migrator.down(@repo, @version, @migration, prefix: c.prefix, log: false)
    end

    assert table_snapshot(c.prefix, "clients") == before
    assert_digest_constraints(c.prefix)
  end

  for {description, change} <- [
        {"both credential columns", "ADD COLUMN token_hash text"},
        {"wrong digest type", "ALTER COLUMN token_digest TYPE text"},
        {"non-null digest", "ALTER COLUMN token_digest SET NOT NULL"},
        {"digest default",
         "ALTER COLUMN token_digest SET DEFAULT decode(repeat('00', 32), 'hex')"},
        {"missing digest", "DROP COLUMN token_digest"},
        {"missing unique index", "DROP INDEX"},
        {"nonunique index", "NONUNIQUE INDEX"},
        {"partial index", "PARTIAL INDEX"},
        {"wrong constraint", "WRONG CONSTRAINT"},
        {"unvalidated constraint", "UNVALIDATED CONSTRAINT"},
        {"short digest data", "SHORT DIGEST"},
        {"duplicate digest data", "DUPLICATE DIGEST"}
      ] do
    @change change
    test "rejects #{description} atomically without a migration receipt", c do
      create_clients(c.prefix)

      assert :ok =
               Ecto.Migrator.up(
                 @repo,
                 @auth_version,
                 Backplane.Repo.Migrations.IndexClientCredentials,
                 prefix: c.prefix,
                 log: false
               )

      corrupt_digest_schema(c.prefix, @change)
      before = schema_snapshot(c.prefix)

      assert_raise Postgrex.Error, ~r/Client credential reconciliation:/, fn ->
        migrate_auth(c.prefix)
      end

      assert schema_snapshot(c.prefix) == before
      refute @version in versions(c.prefix)
    end
  end

  test "legacy conversion rolls back all DDL and rows on a conflicting index name", c do
    create_clients(c.prefix)
    seed_clients(c.prefix)
    seed_history(c.prefix)
    @repo.query!(~s|CREATE TABLE "#{c.prefix}".clients_token_digest_index (id integer)|)
    before = schema_snapshot(c.prefix)

    assert_raise Postgrex.Error, fn -> migrate_auth(c.prefix) end
    assert schema_snapshot(c.prefix) == before
    assert digest_columns(c.prefix) == [["token_hash", "text", "NO"]]
    refute @version in versions(c.prefix)
  end

  defp migrations_path, do: Application.app_dir(:backplane_system, "priv/repo/migrations")

  defp create_clients(prefix) do
    assert :ok =
             Ecto.Migrator.up(@repo, 20_260_410_000_003, Backplane.Repo.Migrations.CreateClients,
               prefix: prefix,
               log: false
             )
  end

  defp migrate_auth(prefix) do
    Ecto.Migrator.run(
      @repo,
      [
        {@auth_version, Backplane.Repo.Migrations.IndexClientCredentials},
        {@version, @migration}
      ],
      :up,
      prefix: prefix,
      all: true,
      log: false
    )
  end

  defp seed_clients(prefix) do
    @repo.query!("""
    INSERT INTO "#{prefix}".clients (name, token_hash, scopes, active, metadata, last_seen_at, inserted_at, updated_at)
    VALUES ('active', 'historical-bcrypt', ARRAY['mcp','memory'], true, '{"owner":"operator"}', now(), now(), now()),
           ('inactive', 'historical-bcrypt-disabled', ARRAY['memory'], false, '{}', NULL, now(), now())
    """)
  end

  defp seed_history(prefix) do
    for version <- @auth_version..(@version - 1) do
      @repo.query!(
        ~s|INSERT INTO "#{prefix}".schema_migrations (version, inserted_at) VALUES ($1, now())|,
        [version]
      )
    end
  end

  defp seed_memory_history(prefix) do
    for table <- ["bpm_memories", "bpm_memory_tombstones"] do
      @repo.query!(
        ~s|CREATE TABLE "#{prefix}".#{table} (id uuid PRIMARY KEY, host_id text, content jsonb)|
      )

      @repo.query!(
        ~s|INSERT INTO "#{prefix}".#{table} VALUES (gen_random_uuid(), 'host-a', '{"historical":true}'), (gen_random_uuid(), 'host-b', '{"historical":true}')|
      )
    end
  end

  defp memory_history(prefix),
    do: Enum.map(["bpm_memories", "bpm_memory_tombstones"], &table_snapshot(prefix, &1))

  defp versions(prefix),
    do:
      @repo.query!(~s|SELECT version FROM "#{prefix}".schema_migrations ORDER BY version|).rows
      |> List.flatten()

  defp client_metadata(prefix) do
    @repo.query!(
      ~s|SELECT id, name, scopes, active, metadata, last_seen_at, inserted_at, updated_at FROM "#{prefix}".clients ORDER BY id|
    ).rows
  end

  defp table_snapshot(prefix, table) do
    @repo.query!(~s|SELECT to_jsonb(t) FROM "#{prefix}".#{table} t ORDER BY to_jsonb(t)::text|).rows
  end

  defp digest_columns(prefix) do
    @repo.query!(
      "SELECT column_name, data_type, is_nullable FROM information_schema.columns WHERE table_schema = $1 AND table_name = 'clients' AND column_name IN ('token_hash', 'token_digest') ORDER BY column_name",
      [prefix]
    ).rows
  end

  defp schema_snapshot(prefix) do
    [
      table_snapshot(prefix, "clients"),
      digest_columns(prefix),
      versions(prefix),
      @repo.query!("SELECT indexdef FROM pg_indexes WHERE schemaname = $1 ORDER BY indexname", [
        prefix
      ]).rows,
      @repo.query!(
        "SELECT c.conname, pg_get_constraintdef(c.oid), c.convalidated FROM pg_constraint c JOIN pg_namespace n ON n.oid = c.connamespace WHERE n.nspname = $1 ORDER BY c.conname",
        [prefix]
      ).rows
    ]
  end

  defp assert_all_unissued(prefix) do
    assert digest_columns(prefix) == [["token_digest", "bytea", "YES"]]

    assert [[2]] =
             @repo.query!(~s|SELECT count(*) FROM "#{prefix}".clients WHERE token_digest IS NULL|).rows
  end

  defp assert_digest_constraints(prefix) do
    digest = :crypto.strong_rand_bytes(32)

    @repo.query!(
      ~s|INSERT INTO "#{prefix}".clients (name, token_digest, inserted_at, updated_at) VALUES ('issued', $1, now(), now())|,
      [digest]
    )

    assert_raise Postgrex.Error, fn ->
      @repo.query!(
        ~s|INSERT INTO "#{prefix}".clients (name, token_digest, inserted_at, updated_at) VALUES ('duplicate', $1, now(), now())|,
        [digest]
      )
    end

    assert_raise Postgrex.Error, fn ->
      @repo.query!(
        ~s|INSERT INTO "#{prefix}".clients (name, token_digest, inserted_at, updated_at) VALUES ('short', $1, now(), now())|,
        [<<1>>]
      )
    end

    @repo.query!(
      ~s|INSERT INTO "#{prefix}".clients (name, inserted_at, updated_at) VALUES ('unissued-1', now(), now()), ('unissued-2', now(), now())|
    )
  end

  defp corrupt_digest_schema(prefix, change) do
    case change do
      "DROP INDEX" ->
        @repo.query!(~s|DROP INDEX "#{prefix}".clients_token_digest_index|)

      type when type in ["NONUNIQUE INDEX", "PARTIAL INDEX", "DUPLICATE DIGEST"] ->
        @repo.query!(~s|DROP INDEX "#{prefix}".clients_token_digest_index|)

        case type do
          "NONUNIQUE INDEX" ->
            @repo.query!(
              ~s|CREATE INDEX clients_token_digest_index ON "#{prefix}".clients (token_digest)|
            )

          "PARTIAL INDEX" ->
            @repo.query!(
              ~s|CREATE UNIQUE INDEX clients_token_digest_index ON "#{prefix}".clients (token_digest) WHERE active|
            )

          "DUPLICATE DIGEST" ->
            @repo.query!(
              ~s|INSERT INTO "#{prefix}".clients (name, token_digest, inserted_at, updated_at) VALUES ('a', decode(repeat('ab',32),'hex'), now(), now()), ('b', decode(repeat('ab',32),'hex'), now(), now())|
            )
        end

      type when type in ["WRONG CONSTRAINT", "UNVALIDATED CONSTRAINT", "SHORT DIGEST"] ->
        @repo.query!(
          ~s|ALTER TABLE "#{prefix}".clients DROP CONSTRAINT clients_token_digest_length|
        )

        case type do
          "WRONG CONSTRAINT" ->
            @repo.query!(
              ~s|ALTER TABLE "#{prefix}".clients ADD CONSTRAINT clients_token_digest_length CHECK (true)|
            )

          "UNVALIDATED CONSTRAINT" ->
            @repo.query!(
              ~s|ALTER TABLE "#{prefix}".clients ADD CONSTRAINT clients_token_digest_length CHECK (token_digest IS NULL OR octet_length(token_digest) = 32) NOT VALID|
            )

          "SHORT DIGEST" ->
            @repo.query!(
              ~s|INSERT INTO "#{prefix}".clients (name, token_digest, inserted_at, updated_at) VALUES ('a', decode('ab','hex'), now(), now())|
            )
        end

      "ALTER COLUMN token_digest TYPE text" ->
        @repo.query!(
          ~s|ALTER TABLE "#{prefix}".clients DROP CONSTRAINT clients_token_digest_length|
        )

        @repo.query!(~s|ALTER TABLE "#{prefix}".clients #{change}|)

      _ ->
        @repo.query!(~s|ALTER TABLE "#{prefix}".clients #{change}|)
    end
  end
end

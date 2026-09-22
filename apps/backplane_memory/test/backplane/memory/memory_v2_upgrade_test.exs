defmodule Backplane.Memory.V2UpgradeTestRepo do
  use Ecto.Repo, otp_app: :backplane_system, adapter: Ecto.Adapters.Postgres
end

defmodule Backplane.Memory.V2UpgradeTest do
  use ExUnit.Case, async: false

  alias Backplane.Memory.V2UpgradeTestRepo, as: Repo
  alias Backplane.Memory.{Config, EdgeSync}

  @previous 20_260_905_000_009
  @current 20_260_905_000_010

  test "populated 00009 upgrades to 00010 without losing canonical data or frontier" do
    prefix = "memory_v2_upgrade_#{System.unique_integer([:positive])}"

    config =
      Application.fetch_env!(:backplane_memory, :repo).config()
      |> Keyword.delete(:pool)
      |> Keyword.put(:pool_size, 4)

    {:ok, setup_repo} = Repo.start_link(config)
    Repo.query!(~s|CREATE SCHEMA "#{prefix}"|)
    GenServer.stop(setup_repo)

    try do
      start_supervised!({Repo, Keyword.put(config, :parameters, search_path: prefix)})
      repo = Repo
      migrations = Application.app_dir(:backplane_system, "priv/repo/migrations")

      assert [_ | _] =
               Ecto.Migrator.run(Repo, migrations, :up, prefix: prefix, to: @previous, log: false)

      assert [[@previous]] =
               Repo.query!(~s|SELECT max(version) FROM "#{prefix}".schema_migrations|).rows

      host = Ecto.UUID.generate()
      space = Ecto.UUID.generate()
      episode = Ecto.UUID.generate()
      deduplicated = Ecto.UUID.generate()
      semantic = Ecto.UUID.generate()
      request = Ecto.UUID.generate()
      first_request = Ecto.UUID.generate()
      later_request = Ecto.UUID.generate()

      repo.query!(
        ~s|INSERT INTO "#{prefix}".skill_hosts(id,name,memory_scope,inserted_at,updated_at) VALUES ($1,'upgrade-host','memory.write',now(),now())|,
        [Ecto.UUID.dump!(host)]
      )

      repo.query!(
        ~s|INSERT INTO "#{prefix}".bpm_memory_spaces(id,kind,status,inserted_at,updated_at) VALUES ($1,'private','active',now(),now())|,
        [Ecto.UUID.dump!(space)]
      )

      repo.query!(
        ~s|INSERT INTO "#{prefix}".bpm_memory_space_entitlements(memory_space_id,host_id,scope,namespace,status,inserted_at,updated_at) VALUES ($1,$2,'project','private','active',now(),now())|,
        [Ecto.UUID.dump!(space), Ecto.UUID.dump!(host)]
      )

      insert_memory(repo, prefix, episode, space, host, "episodic", "legacy host episode", %{
        "host_memory" => %{"local_id" => "local-1"}
      })

      insert_memory(repo, prefix, semantic, space, host, "semantic", "canonical fact", %{})

      insert_memory(
        repo,
        prefix,
        deduplicated,
        space,
        host,
        "episodic",
        "deduplicated episode",
        %{
          "source" => "historical"
        }
      )

      repo.query!(
        ~s|INSERT INTO "#{prefix}".bpm_memory_remember_requests(id,idempotency_scope,idempotency_key,request_hash,memory_id,inserted_at,updated_at) VALUES ($1,$2,'local-1',$3,$4,now(),now())|,
        [
          Ecto.UUID.dump!(request),
          "host-memory.v1:#{host}",
          :crypto.hash(:sha256, "request"),
          Ecto.UUID.dump!(episode)
        ]
      )

      for {id, key, inserted_at} <- [
            {first_request, "early", "2026-01-01"},
            {later_request, "late", "2026-01-02"}
          ] do
        repo.query!(
          ~s|INSERT INTO "#{prefix}".bpm_memory_remember_requests(id,idempotency_scope,idempotency_key,request_hash,memory_id,inserted_at,updated_at) VALUES ($1,$2,$3,$4,$5,$6,$6)|,
          [
            Ecto.UUID.dump!(id),
            "host-memory.v1:#{host}",
            key,
            :crypto.hash(:sha256, key),
            Ecto.UUID.dump!(deduplicated),
            NaiveDateTime.from_iso8601!(inserted_at <> "T00:00:00")
          ]
        )
      end

      assert [[false], [false], [true]] =
               repo.query!(
                 ~s|SELECT "#{prefix}".bpm_memory_edge_eligible(m) FROM "#{prefix}".bpm_memories m ORDER BY memory_type, content|
               ).rows

      repo.query!(
        ~s|INSERT INTO "#{prefix}".bpm_host_memory_cursors(host_id,memory_space_id,scope,namespace,applied_revision,acknowledged_at) VALUES ($1,$2,'project','private',1,now())|,
        [Ecto.UUID.dump!(host), Ecto.UUID.dump!(space)]
      )

      repo.query!(
        ~s|INSERT INTO "#{prefix}".bpm_host_memory_deliveries(host_id,memory_space_id,scope,namespace,kind,from_revision,to_revision,payload,encoded_bytes) VALUES ($1,$2,'project','private','delta',1,1,'{}',2)|,
        [Ecto.UUID.dump!(host), Ecto.UUID.dump!(space)]
      )

      assert [[1]] =
               repo.query!(
                 ~s|SELECT current_revision FROM "#{prefix}".bpm_memory_partition_revisions|
               ).rows

      assert [_] =
               Ecto.Migrator.run(Repo, migrations, :up, prefix: prefix, to: @current, log: false)

      assert [[@current]] =
               repo.query!(~s|SELECT max(version) FROM "#{prefix}".schema_migrations|).rows

      assert [
               [^deduplicated, "episodic", true],
               [^episode, "episodic", true],
               [^semantic, "semantic", true]
             ] =
               repo.query!(
                 ~s|SELECT id::text,memory_type,"#{prefix}".bpm_memory_edge_eligible(m) FROM "#{prefix}".bpm_memories m ORDER BY memory_type, content|
               ).rows

      assert [[^first_request, "deduplicated episode", ^space, "project", "private", ^host]] =
               repo.query!(
                 ~s|SELECT metadata->>'host_memory_command_revision',content,memory_space_id::text,scope,namespace,host_id FROM "#{prefix}".bpm_memories WHERE id=$1|,
                 [Ecto.UUID.dump!(deduplicated)]
               ).rows

      assert [[^request, "legacy host episode", ^space, "project", "private", ^host]] =
               repo.query!(
                 ~s|SELECT r.id::text,m.content,m.memory_space_id::text,m.scope,m.namespace,m.host_id FROM "#{prefix}".bpm_memories m JOIN "#{prefix}".bpm_memory_remember_requests r ON r.memory_id=m.id WHERE m.id=$1|,
                 [Ecto.UUID.dump!(episode)]
               ).rows

      assert [[1, nil]] =
               repo.query!(
                 ~s|SELECT applied_revision,acknowledged_at FROM "#{prefix}".bpm_host_memory_cursors|
               ).rows

      assert [["expired"]] =
               repo.query!(~s|SELECT status FROM "#{prefix}".bpm_host_memory_deliveries|).rows

      assert [[2]] =
               repo.query!(
                 ~s|SELECT current_revision FROM "#{prefix}".bpm_memory_partition_revisions|
               ).rows

      assert [
               [1, "upsert", ^semantic, "canonical fact"],
               [2, "upsert", ^deduplicated, "deduplicated episode"]
             ] =
               repo.query!(
                 ~s|SELECT revision,op,memory_id::text,payload->>'content' FROM "#{prefix}".bpm_memory_changes ORDER BY revision|
               ).rows

      assert [[^first_request, "historical"]] =
               repo.query!(
                 ~s|SELECT payload->'metadata'->>'host_memory_command_revision',payload->'metadata'->>'source' FROM "#{prefix}".bpm_memory_changes WHERE revision=2|
               ).rows

      assert [[0]] =
               repo.query!(~s|SELECT count(*) FROM "#{prefix}".bpm_host_memory_command_receipts|).rows

      repo.query!(
        ~s|INSERT INTO "#{prefix}".bpm_host_memory_command_receipts(source_request_id,memory_id,edge_revision) VALUES ($1,$2,1)|,
        [Ecto.UUID.dump!(request), Ecto.UUID.dump!(episode)]
      )

      assert [[^request, ^episode, 1]] =
               repo.query!(
                 ~s|SELECT source_request_id::text,memory_id::text,edge_revision FROM "#{prefix}".bpm_host_memory_command_receipts|
               ).rows

      assert_raise Postgrex.Error, fn ->
        repo.query!(~s|UPDATE "#{prefix}".bpm_host_memory_command_receipts SET edge_revision=3|)
      end

      assert [] =
               Ecto.Migrator.run(Repo, migrations, :up, prefix: prefix, to: @current, log: false)

      assert [[3]] = repo.query!(~s|SELECT count(*) FROM "#{prefix}".bpm_memories|).rows

      assert [[2]] =
               repo.query!(
                 ~s|SELECT current_revision FROM "#{prefix}".bpm_memory_partition_revisions|
               ).rows

      # A schema upgrade alone must leave the rollout on v1 until the opt-in is set.
      keys = ~w(memory.host_sync_v1.enabled memory.host_sync_v2.enabled)
      previous = Map.new(keys, &{&1, :ets.lookup(:backplane_settings, &1)})

      try do
        Enum.each(keys, &:ets.insert(:backplane_settings, {&1, nil}))
        assert Config.host_sync_v1_enabled?()
        refute Config.host_sync_v2_enabled?()

        assert {:ok, %{selected: "host_memory.v1"}} =
                 EdgeSync.negotiate(host, %{"memory" => %{"protocol" => "host_memory.v1"}})

        assert {:error, %{code: :protocol_disabled}} =
                 EdgeSync.negotiate(host, %{
                   "selected" => "host_memory.v2",
                   "memory_v2" => %{
                     "offers" => ["host_memory.v2"],
                     "partitions" => [],
                     "max_frame_bytes" => 524_288
                   }
                 })
      after
        Enum.each(previous, fn
          {key, []} -> :ets.delete(:backplane_settings, key)
          {_key, [entry]} -> :ets.insert(:backplane_settings, entry)
        end)
      end
    after
      stop_supervised(Repo)
      {:ok, cleanup_repo} = Repo.start_link(config)
      Repo.query!(~s|DROP SCHEMA IF EXISTS "#{prefix}" CASCADE|)
      GenServer.stop(cleanup_repo)
    end
  end

  defp insert_memory(repo, prefix, id, space, host, type, content, metadata) do
    repo.query!(
      ~s|INSERT INTO "#{prefix}".bpm_memories(id,memory_space_id,host_id,client_id,scope,namespace,agent_id,content,content_hash,memory_type,lifecycle_state,metadata,inserted_at,updated_at) VALUES ($1,$2,$3,$4,'project','private','test',$5,$6,$7,'active',$8,now(),now())|,
      [
        Ecto.UUID.dump!(id),
        Ecto.UUID.dump!(space),
        host,
        "host:#{host}",
        content,
        :crypto.hash(:sha256, content),
        type,
        metadata
      ]
    )
  end
end

defmodule Backplane.Memory.EdgeSync.CaptureRepo do
  use Ecto.Repo, otp_app: :backplane_system, adapter: Ecto.Adapters.Postgres
end

defmodule Backplane.Memory.EdgeSync.ChangeCaptureTest do
  use ExUnit.Case, async: false
  alias Backplane.Memory.EdgeSync.CaptureRepo, as: Repo

  setup do
    config =
      Application.fetch_env!(:backplane_memory, :repo).config()
      |> Keyword.delete(:pool)
      |> Keyword.put(:pool_size, 10)

    start_supervised!({Repo, config})
    prefix = "edge_capture_#{System.unique_integer([:positive])}"
    Repo.query!(~s|CREATE SCHEMA "#{prefix}"|)

    on_exit(fn ->
      {:ok, pid} = Repo.start_link(config)
      Repo.query!(~s|DROP SCHEMA "#{prefix}" CASCADE|)
      GenServer.stop(pid)
    end)

    for table <-
          ~w(bpm_memory_spaces bpm_memory_space_entitlements bpm_memory_space_backfill_issues bpm_memories bpm_memory_remember_requests bpm_events bpm_projection_states oban_jobs system_settings) do
      Repo.query!(~s|CREATE TABLE "#{prefix}".#{table} (LIKE public.#{table} INCLUDING ALL)|)
    end

    Repo.query!("""
    CREATE FUNCTION "#{prefix}".bpm_reject_memory_provenance_mutation()
    RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN RAISE EXCEPTION 'memory provenance rows are immutable' USING ERRCODE = '55000'; END;
    $$
    """)

    space = Ecto.UUID.generate()
    host = Ecto.UUID.generate()

    Repo.query!(
      ~s|INSERT INTO "#{prefix}".bpm_memory_spaces (id,kind,status,inserted_at,updated_at) VALUES ($1,'private','active',now(),now())|,
      [Ecto.UUID.dump!(space)]
    )

    for scope <- ["a", "z"] do
      Repo.query!(
        ~s|INSERT INTO "#{prefix}".bpm_memory_space_entitlements (memory_space_id,host_id,scope,namespace,status,inserted_at,updated_at) VALUES ($1,$2,$3,'private','active',now(),now())|,
        [Ecto.UUID.dump!(space), Ecto.UUID.dump!(host), scope]
      )
    end

    for {version, file, module} <- [
          {20_260_905_000_004, "create_host_memory_edge_sync",
           Backplane.Repo.Migrations.CreateHostMemoryEdgeSync},
          {20_260_905_000_005, "install_memory_edge_change_capture",
           Backplane.Repo.Migrations.InstallMemoryEdgeChangeCapture},
          {20_260_905_000_006, "add_memory_edge_payload_priority",
           Backplane.Repo.Migrations.AddMemoryEdgePayloadPriority}
        ] do
      path = Application.app_dir(:backplane_system, "priv/repo/migrations/#{version}_#{file}.exs")
      assert File.exists?(path)
      Code.require_file(path)
      Ecto.Migrator.up(Repo, version, module, prefix: prefix, log: false)
    end

    %{prefix: prefix, space: space, host: host}
  end

  test "concurrent committed writes allocate contiguous revisions and rollback leaves no gap",
       ctx do
    tasks = for i <- 1..12, do: Task.async(fn -> insert(ctx, "fact #{i}") end)
    Enum.each(tasks, &Task.await(&1, 10_000))
    assert Enum.map(changes(ctx), &Enum.at(&1, 0)) == Enum.to_list(1..12)

    assert {:error, :abort} =
             Repo.transaction(fn ->
               insert(ctx, "rolled back")
               Repo.rollback(:abort)
             end)

    insert(ctx, "after rollback")
    assert Enum.map(changes(ctx), &Enum.at(&1, 0)) == Enum.to_list(1..13)
    refute inspect(changes(ctx)) =~ "rolled back"
  end

  test "immutable payloads, ignored counters, eligibility exits and reentry", ctx do
    id = insert(ctx, "first")

    update(
      ctx,
      id,
      "access_count = access_count + 1, application_count = application_count + 1, accessed_at = now(), embedding_model = 'other', updated_at = now()"
    )

    assert length(changes(ctx)) == 1

    assert [[1]] =
             Repo.query!(
               ~s|SELECT current_revision FROM "#{ctx.prefix}".bpm_memory_partition_revisions WHERE memory_space_id=$1 AND scope='a' AND namespace='private'|,
               [Ecto.UUID.dump!(ctx.space)]
             ).rows

    update(ctx, id, "content = 'second'")

    assert [[1, "upsert", %{"content" => "first"}], [2, "upsert", %{"content" => "second"}]] =
             changes(ctx)

    update(ctx, id, "lifecycle_state = 'archived'")
    assert List.last(changes(ctx)) == [3, "delete", %{"canonical_id" => id}]
    update(ctx, id, "lifecycle_state = 'disputed'")
    assert [4, "upsert", _] = List.last(changes(ctx))
    update(ctx, id, "deleted_at = now(), lifecycle_state = 'tombstoned'")
    assert [5, "delete", _] = List.last(changes(ctx))

    assert_raise Postgrex.Error, fn ->
      Repo.query!(~s|UPDATE "#{ctx.prefix}".bpm_memory_changes SET payload = '{}'|)
    end
  end

  test "wire payload emits server-owned priority and canonical update time", ctx do
    semantic = insert(ctx, "semantic")
    update(ctx, semantic, "confidence = 0.75, content = 'semantic updated'")
    [_, [_, "upsert", semantic_payload]] = changes(ctx)
    assert semantic_payload["edge_priority"] == 0.75

    procedural = insert(ctx, "procedure")
    update(ctx, procedural, "memory_type = 'procedural', confidence = 0.25")
    [_, [_, "upsert", procedural_payload]] = changes(ctx) |> Enum.drop(2)
    assert procedural_payload["edge_priority"] == 2.25

    assert [[1.0, 2.0]] =
             Repo.query!(
               ~s|SELECT
                    ("#{ctx.prefix}".bpm_memory_edge_payload(jsonb_populate_record(m, '{"memory_type":"semantic","confidence":2.5}'))->>'edge_priority')::float8,
                    ("#{ctx.prefix}".bpm_memory_edge_payload(jsonb_populate_record(m, '{"memory_type":"procedural","confidence":-1}'))->>'edge_priority')::float8
                  FROM "#{ctx.prefix}".bpm_memories m WHERE id=$1|,
               [Ecto.UUID.dump!(procedural)]
             ).rows

    assert [[true]] =
             Repo.query!(
               ~s|SELECT (c.payload->>'updated_at')::timestamptz = m.updated_at
                  FROM "#{ctx.prefix}".bpm_memory_changes c
                  JOIN "#{ctx.prefix}".bpm_memories m ON m.id=c.memory_id
                  WHERE c.memory_id=$1 ORDER BY c.revision DESC LIMIT 1|,
               [Ecto.UUID.dump!(procedural)]
             ).rows

    update(ctx, procedural, "confidence = 4.0, content = 'clamped high'")
    assert [_, "upsert", high_payload] = List.last(changes(ctx))
    assert high_payload["edge_priority"] == 3.0
    update(ctx, procedural, "confidence = -2.0, content = 'clamped low'")
    assert [_, "upsert", low_payload] = List.last(changes(ctx))
    assert low_payload["edge_priority"] == 2.0

    before_access = length(changes(ctx))

    update(
      ctx,
      procedural,
      "access_count = access_count + 1, accessed_at = now(), updated_at = now()"
    )

    assert length(changes(ctx)) == before_access
  end

  test "upgrade snapshots historical host episodic rows and captures later lifecycle changes",
       ctx do
    id = insert(ctx, "pre-upgrade host episode")

    update(
      ctx,
      id,
      ~s|memory_type = 'episodic', metadata = '{"host_memory":{"local_id":"local-before"}}'::jsonb|
    )

    assert [[2, "delete", _]] = Enum.drop(changes(ctx), 1)

    Repo.query!(
      ~s|INSERT INTO "#{ctx.prefix}".bpm_host_memory_cursors (host_id,memory_space_id,scope,namespace,applied_revision,acknowledged_at) VALUES ($1,$2,'a','private',2,now())|,
      [Ecto.UUID.dump!(ctx.host), Ecto.UUID.dump!(ctx.space)]
    )

    Repo.query!(
      ~s|INSERT INTO "#{ctx.prefix}".bpm_host_memory_cursors (host_id,memory_space_id,scope,namespace,applied_revision,acknowledged_at) VALUES ($1,$2,'z','private',0,now())|,
      [Ecto.UUID.dump!(ctx.host), Ecto.UUID.dump!(ctx.space)]
    )

    path =
      Application.app_dir(
        :backplane_system,
        "priv/repo/migrations/20260905000010_include_host_episodic_edge_memories.exs"
      )

    Code.require_file(path)

    Ecto.Migrator.up(
      Repo,
      20_260_905_000_010,
      Backplane.Repo.Migrations.IncludeHostEpisodicEdgeMemories,
      prefix: ctx.prefix,
      log: false
    )

    assert [["a", 2, nil], ["z", 0, %NaiveDateTime{}]] =
             Repo.query!(
               ~s|SELECT scope,applied_revision,acknowledged_at FROM "#{ctx.prefix}".bpm_host_memory_cursors ORDER BY scope|
             ).rows

    assert [[true]] =
             Repo.query!(
               ~s|SELECT "#{ctx.prefix}".bpm_memory_edge_eligible(m) FROM "#{ctx.prefix}".bpm_memories m WHERE id=$1|,
               [Ecto.UUID.dump!(id)]
             ).rows

    fresh_id = Ecto.UUID.generate()

    Repo.query!(
      ~s|INSERT INTO "#{ctx.prefix}".bpm_memories (id,memory_space_id,host_id,client_id,scope,namespace,agent_id,content,content_hash,memory_type,lifecycle_state,metadata,inserted_at,updated_at) VALUES ($1,$2,$3,$4,'z','private','test','new host episode',$5,'episodic','active','{"host_memory":{"local_id":"fresh"}}'::jsonb,now(),now())|,
      [
        Ecto.UUID.dump!(fresh_id),
        Ecto.UUID.dump!(ctx.space),
        ctx.host,
        "host:" <> ctx.host,
        :crypto.hash(:sha256, "new host episode")
      ]
    )

    assert [[1, "upsert", %{"canonical_id" => ^fresh_id}]] = changes(ctx, "z")

    update(ctx, id, "metadata = '{}'::jsonb")
    assert [3, "delete", %{"canonical_id" => ^id}] = List.last(changes(ctx))

    update(ctx, id, ~s|metadata = '{"host_memory":{"local_id":"local-before"}}'::jsonb|)
    assert [4, "upsert", %{"canonical_id" => ^id}] = List.last(changes(ctx))

    update(ctx, id, "deleted_at = now(), lifecycle_state = 'tombstoned'")
    assert [5, "delete", %{"canonical_id" => ^id}] = List.last(changes(ctx))

    Repo.query!(
      ~s|UPDATE "#{ctx.prefix}".bpm_host_memory_cursors SET acknowledged_at=now() WHERE scope='z'|
    )

    Ecto.Migrator.down(
      Repo,
      20_260_905_000_010,
      Backplane.Repo.Migrations.IncludeHostEpisodicEdgeMemories,
      prefix: ctx.prefix,
      log: false
    )

    assert [[nil]] =
             Repo.query!(
               ~s|SELECT acknowledged_at FROM "#{ctx.prefix}".bpm_host_memory_cursors WHERE scope='z'|
             ).rows

    assert [[false]] =
             Repo.query!(
               ~s|SELECT "#{ctx.prefix}".bpm_memory_edge_eligible(m) FROM "#{ctx.prefix}".bpm_memories m WHERE id=$1|,
               [Ecto.UUID.dump!(fresh_id)]
             ).rows
  end

  test "populated previous migration head upgrades without losing canonical rows or edge revisions",
       ctx do
    episode_id = insert(ctx, "remembered before migration")

    update(
      ctx,
      episode_id,
      ~s|memory_type = 'episodic', metadata = '{"host_memory":{"local_id":"old-local"}}'::jsonb|
    )

    semantic_id = insert(ctx, "semantic before migration")

    Repo.query!(
      ~s|INSERT INTO "#{ctx.prefix}".bpm_host_memory_cursors (host_id,memory_space_id,scope,namespace,applied_revision,acknowledged_at) VALUES ($1,$2,'a','private',3,now())|,
      [Ecto.UUID.dump!(ctx.host), Ecto.UUID.dump!(ctx.space)]
    )

    for {version, file, module} <- [
          {20_260_905_000_007, "enforce_complete_memory_partition",
           Backplane.Repo.Migrations.EnforceCompleteMemoryPartition},
          {20_260_905_000_008, "coalesce_projection_repairs",
           Backplane.Repo.Migrations.CoalesceProjectionRepairs},
          {20_260_905_000_009, "expand_memory_processing_states",
           Backplane.Repo.Migrations.ExpandMemoryProcessingStates}
        ] do
      path = Application.app_dir(:backplane_system, "priv/repo/migrations/#{version}_#{file}.exs")
      Code.require_file(path)
      Ecto.Migrator.up(Repo, version, module, prefix: ctx.prefix, log: false)
    end

    assert [[20_260_905_000_009]] =
             Repo.query!(~s|SELECT max(version) FROM "#{ctx.prefix}".schema_migrations|).rows

    assert [[^episode_id, "episodic"], [^semantic_id, "semantic"]] =
             Repo.query!(
               ~s|SELECT id::text,memory_type FROM "#{ctx.prefix}".bpm_memories ORDER BY content|
             ).rows

    assert [[3]] =
             Repo.query!(
               ~s|SELECT current_revision FROM "#{ctx.prefix}".bpm_memory_partition_revisions WHERE memory_space_id=$1 AND scope='a' AND namespace='private'|,
               [Ecto.UUID.dump!(ctx.space)]
             ).rows

    path =
      Application.app_dir(
        :backplane_system,
        "priv/repo/migrations/20260905000010_include_host_episodic_edge_memories.exs"
      )

    Code.require_file(path)

    Ecto.Migrator.up(
      Repo,
      20_260_905_000_010,
      Backplane.Repo.Migrations.IncludeHostEpisodicEdgeMemories,
      prefix: ctx.prefix,
      log: false
    )

    assert [[20_260_905_000_010]] =
             Repo.query!(~s|SELECT max(version) FROM "#{ctx.prefix}".schema_migrations|).rows

    assert [[^episode_id, "episodic"], [^semantic_id, "semantic"]] =
             Repo.query!(
               ~s|SELECT id::text,memory_type FROM "#{ctx.prefix}".bpm_memories ORDER BY content|
             ).rows

    assert [[3, nil]] =
             Repo.query!(
               ~s|SELECT applied_revision,acknowledged_at FROM "#{ctx.prefix}".bpm_host_memory_cursors WHERE scope='a'|
             ).rows

    assert [[true]] =
             Repo.query!(
               ~s|SELECT "#{ctx.prefix}".bpm_memory_edge_eligible(m) FROM "#{ctx.prefix}".bpm_memories m WHERE id=$1|,
               [Ecto.UUID.dump!(episode_id)]
             ).rows

    update(ctx, episode_id, "content = 'remembered after migration'")
    assert [4, "upsert", %{"canonical_id" => ^episode_id}] = List.last(changes(ctx))

    assert [[4]] =
             Repo.query!(
               ~s|SELECT current_revision FROM "#{ctx.prefix}".bpm_memory_partition_revisions WHERE memory_space_id=$1 AND scope='a' AND namespace='private'|,
               [Ecto.UUID.dump!(ctx.space)]
             ).rows
  end

  test "previous-head upgrade backfills a host crystal dedup with a bounded revision", ctx do
    crystal_id = insert(ctx, "historical crystal")
    update(ctx, crystal_id, ~s|memory_type = 'episodic', metadata = '{"crystal":true}'::jsonb|)
    assert [2, "delete", _] = List.last(changes(ctx))

    oversized_id = Ecto.UUID.generate()

    Repo.query!(
      ~s|INSERT INTO "#{ctx.prefix}".bpm_memories (id,memory_space_id,host_id,client_id,scope,namespace,agent_id,content,content_hash,memory_type,lifecycle_state,metadata,inserted_at,updated_at) VALUES ($1,$2,$3,$4,'a','private','test',repeat('x', 1000),$5,'episodic','active','{"crystal":true}'::jsonb,now(),now())|,
      [
        Ecto.UUID.dump!(oversized_id),
        Ecto.UUID.dump!(ctx.space),
        ctx.host,
        "host:" <> ctx.host,
        :crypto.hash(:sha256, String.duplicate("x", 1000))
      ]
    )

    [first_request, later_request, oversized_request] =
      Enum.map(1..3, fn _ -> Ecto.UUID.generate() end)

    for {request_id, key, memory_id, inserted_at} <- [
          {later_request, "later", crystal_id, "2026-01-02"},
          {first_request, "first", crystal_id, "2026-01-01"},
          {oversized_request, "oversized", oversized_id, "2026-01-01"}
        ] do
      Repo.query!(
        ~s|INSERT INTO "#{ctx.prefix}".bpm_memory_remember_requests (id,idempotency_scope,idempotency_key,request_hash,memory_id,inserted_at,updated_at) VALUES ($1,$2,$3,$4,$5,($6::text)::timestamp,($6::text)::timestamp)|,
        [
          Ecto.UUID.dump!(request_id),
          "host-memory.v1:" <> ctx.host,
          key,
          :crypto.hash(:sha256, key),
          Ecto.UUID.dump!(memory_id),
          inserted_at
        ]
      )
    end

    Repo.query!(
      ~s|INSERT INTO "#{ctx.prefix}".system_settings (key,value,value_type,updated_at) VALUES ('memory.host_sync_max_item_bytes','{"v":512}','integer',now())|
    )

    Repo.query!(
      ~s|INSERT INTO "#{ctx.prefix}".bpm_host_memory_cursors (host_id,memory_space_id,scope,namespace,applied_revision,acknowledged_at) VALUES ($1,$2,'a','private',2,now())|,
      [Ecto.UUID.dump!(ctx.host), Ecto.UUID.dump!(ctx.space)]
    )

    for {version, file, module} <- [
          {20_260_905_000_007, "enforce_complete_memory_partition",
           Backplane.Repo.Migrations.EnforceCompleteMemoryPartition},
          {20_260_905_000_008, "coalesce_projection_repairs",
           Backplane.Repo.Migrations.CoalesceProjectionRepairs},
          {20_260_905_000_009, "expand_memory_processing_states",
           Backplane.Repo.Migrations.ExpandMemoryProcessingStates}
        ] do
      path = Application.app_dir(:backplane_system, "priv/repo/migrations/#{version}_#{file}.exs")
      Code.require_file(path)
      Ecto.Migrator.up(Repo, version, module, prefix: ctx.prefix, log: false)
    end

    assert [[3]] =
             Repo.query!(~s|SELECT count(*) FROM "#{ctx.prefix}".bpm_memory_remember_requests|).rows

    path =
      Application.app_dir(
        :backplane_system,
        "priv/repo/migrations/20260905000010_include_host_episodic_edge_memories.exs"
      )

    Code.require_file(path)

    Ecto.Migrator.up(
      Repo,
      20_260_905_000_010,
      Backplane.Repo.Migrations.IncludeHostEpisodicEdgeMemories,
      prefix: ctx.prefix,
      log: false
    )

    assert [3, "upsert", %{"canonical_id" => ^crystal_id, "metadata" => metadata}] =
             List.last(changes(ctx))

    assert metadata["crystal"] == true
    assert metadata["host_memory_command_revision"] == first_request

    assert [[2, nil]] =
             Repo.query!(
               ~s|SELECT applied_revision,acknowledged_at FROM "#{ctx.prefix}".bpm_host_memory_cursors WHERE scope='a'|
             ).rows

    assert [
             [%{"crystal" => true, "host_memory_command_revision" => ^first_request}],
             [%{"crystal" => true}]
           ] =
             Repo.query!(
               ~s|SELECT metadata FROM "#{ctx.prefix}".bpm_memories WHERE id IN ($1,$2) ORDER BY content|,
               [Ecto.UUID.dump!(crystal_id), Ecto.UUID.dump!(oversized_id)]
             ).rows

    assert [[false]] =
             Repo.query!(
               ~s|SELECT "#{ctx.prefix}".bpm_memory_edge_eligible(m) FROM "#{ctx.prefix}".bpm_memories m WHERE id=$1|,
               [Ecto.UUID.dump!(oversized_id)]
             ).rows

    assert length(changes(ctx)) == 3

    Ecto.Migrator.down(
      Repo,
      20_260_905_000_010,
      Backplane.Repo.Migrations.IncludeHostEpisodicEdgeMemories,
      prefix: ctx.prefix,
      log: false
    )

    assert [[false]] =
             Repo.query!(
               ~s|SELECT "#{ctx.prefix}".bpm_memory_edge_eligible(m) FROM "#{ctx.prefix}".bpm_memories m WHERE id=$1|,
               [Ecto.UUID.dump!(crystal_id)]
             ).rows

    assert [[2, nil]] =
             Repo.query!(
               ~s|SELECT applied_revision,acknowledged_at FROM "#{ctx.prefix}".bpm_host_memory_cursors WHERE scope='a'|
             ).rows
  end

  test "host command receipts reject truncation", ctx do
    path =
      Application.app_dir(
        :backplane_system,
        "priv/repo/migrations/20260905000010_include_host_episodic_edge_memories.exs"
      )

    Code.require_file(path)

    Ecto.Migrator.up(
      Repo,
      20_260_905_000_010,
      Backplane.Repo.Migrations.IncludeHostEpisodicEdgeMemories,
      prefix: ctx.prefix,
      log: false
    )

    assert_raise Postgrex.Error, ~r/memory provenance rows are immutable/, fn ->
      Repo.query!(~s|TRUNCATE "#{ctx.prefix}".bpm_host_memory_command_receipts|)
    end
  end

  test "crystal dedup request is edge eligible only with its persisted revision marker", ctx do
    path =
      Application.app_dir(
        :backplane_system,
        "priv/repo/migrations/20260905000010_include_host_episodic_edge_memories.exs"
      )

    Code.require_file(path)

    Ecto.Migrator.up(
      Repo,
      20_260_905_000_010,
      Backplane.Repo.Migrations.IncludeHostEpisodicEdgeMemories,
      prefix: ctx.prefix,
      log: false
    )

    id = insert(ctx, "crystal dedup")
    update(ctx, id, "memory_type = 'episodic', metadata = '{\"crystal\":true}'::jsonb")
    assert [2, "delete", _] = List.last(changes(ctx))

    request_id = Ecto.UUID.generate()

    Repo.query!(
      ~s|INSERT INTO "#{ctx.prefix}".bpm_memory_remember_requests (id,idempotency_scope,idempotency_key,request_hash,memory_id,inserted_at,updated_at) VALUES ($1,$2,'crystal-local',$3,$4,now(),now())|,
      [
        Ecto.UUID.dump!(request_id),
        "host-memory.v1:" <> ctx.host,
        :crypto.hash(:sha256, "crystal dedup"),
        Ecto.UUID.dump!(id)
      ]
    )

    assert [[false]] =
             Repo.query!(
               ~s|SELECT "#{ctx.prefix}".bpm_memory_edge_eligible(m) FROM "#{ctx.prefix}".bpm_memories m WHERE id=$1|,
               [Ecto.UUID.dump!(id)]
             ).rows

    update(
      ctx,
      id,
      "metadata = jsonb_set(metadata, '{host_memory_command_revision}', to_jsonb('#{request_id}'::text), true)"
    )

    assert [3, "upsert", _] = List.last(changes(ctx))

    update(
      ctx,
      id,
      "metadata = jsonb_set(metadata, '{host_memory_command_revision}', to_jsonb('wrong'::text), true)"
    )

    assert [4, "delete", _] = List.last(changes(ctx))
  end

  test "down restores the prior payload and access-only trigger behavior", ctx do
    Ecto.Migrator.down(
      Repo,
      20_260_905_000_006,
      Backplane.Repo.Migrations.AddMemoryEdgePayloadPriority,
      prefix: ctx.prefix,
      log: false
    )

    id = insert(ctx, "before access")

    update(
      ctx,
      id,
      "access_count = access_count + 1, accessed_at = now(), updated_at = now()"
    )

    assert [[1, "upsert", payload]] = changes(ctx)
    refute Map.has_key?(payload, "edge_priority")
    refute Map.has_key?(payload, "updated_at")

    update(ctx, id, "content = 'after semantic change', updated_at = now()")

    assert [[1, "upsert", _], [2, "upsert", %{"content" => "after semantic change"}]] =
             changes(ctx)
  end

  test "exact namespaces, types and size bound exclude content and delete prior copies", ctx do
    id = insert(ctx, "eligible")
    update(ctx, id, "namespace = 'team:else'")
    assert [2, "delete", _] = List.last(changes(ctx))
    update(ctx, id, "namespace = 'private', memory_type = 'episodic'")
    assert length(changes(ctx)) == 2
    update(ctx, id, "memory_type = 'procedural'")
    assert [3, "upsert", _] = List.last(changes(ctx))

    Repo.query!(
      ~s|INSERT INTO "#{ctx.prefix}".system_settings (key,value,value_type,updated_at) VALUES ('memory.host_sync_max_item_bytes','{"v":512}','integer',now())|
    )

    update(ctx, id, "content = repeat('secret', 1000)")
    assert [4, "delete", _] = List.last(changes(ctx))
    refute inspect(changes(ctx)) =~ "secret"
    update(ctx, id, "content = 'small'")
    assert [5, "upsert", _] = List.last(changes(ctx))
  end

  test "opposing moves lock partitions lexically and emit old delete plus new upsert", ctx do
    a = insert(ctx, "a")
    z = insert(ctx, "z", "z")

    tasks = [
      Task.async(fn -> update(ctx, a, "scope = 'z'") end),
      Task.async(fn -> update(ctx, z, "scope = 'a'") end)
    ]

    Enum.each(tasks, &Task.await(&1, 10_000))

    for scope <- ["a", "z"] do
      rows = changes(ctx, scope)
      assert Enum.map(rows, &hd/1) == [1, 2, 3]
      assert Enum.sort(Enum.map(tl(rows), &Enum.at(&1, 1))) == ["delete", "upsert"]
    end
  end

  test "deliveries reject missing delta frontier and enforce one issued identity", ctx do
    p = ctx.prefix
    params = [Ecto.UUID.dump!(ctx.host), Ecto.UUID.dump!(ctx.space)]

    Repo.query!(
      ~s|INSERT INTO "#{p}".bpm_host_memory_cursors (host_id,memory_space_id,scope,namespace) VALUES ($1,$2,'a','private')|,
      params
    )

    sql =
      ~s|INSERT INTO "#{p}".bpm_host_memory_deliveries (host_id,memory_space_id,scope,namespace,kind,from_revision,to_revision,payload,encoded_bytes) VALUES ($1,$2,'a','private','delta',$3,1,'{}',2)|

    assert_raise Postgrex.Error, fn -> Repo.query!(sql, params ++ [nil]) end
    Repo.query!(sql, params ++ [1])
    assert_raise Postgrex.Error, fn -> Repo.query!(sql, params ++ [1]) end
    Repo.query!(~s|UPDATE "#{p}".bpm_host_memory_deliveries SET status='acknowledged'|)
    Repo.query!(sql, params ++ [1])
    assert [[2]] = Repo.query!(~s|SELECT count(*) FROM "#{p}".bpm_host_memory_deliveries|).rows
  end

  test "notifications arrive only after commit and never contain canonical content", ctx do
    config = Application.fetch_env!(:backplane_memory, :repo).config()
    listener = start_supervised!({Postgrex.Notifications, config})
    {:ok, ref} = Postgrex.Notifications.listen(listener, "bpm_memory_edge_available")

    Repo.transaction(fn ->
      insert(ctx, "private secret fact")
      refute_receive {:notification, ^listener, ^ref, _, _}, 50
    end)

    assert_receive {:notification, ^listener, ^ref, "bpm_memory_edge_available", payload}, 1000

    assert Map.keys(Jason.decode!(payload)) |> Enum.sort() ==
             ~w(current_revision memory_space_id namespace scope)

    refute payload =~ "secret"

    Repo.transaction(fn ->
      insert(ctx, "rollback secret")
      Repo.rollback(:abort)
    end)

    refute_receive {:notification, ^listener, ^ref, _, _}, 50
  end

  test "feed insertion failure rolls back canonical mutation and revision allocation", ctx do
    Repo.query!(~s|ALTER TABLE "#{ctx.prefix}".bpm_memory_changes ADD CHECK (op <> 'upsert')|)
    assert_raise Postgrex.Error, fn -> insert(ctx, "must rollback") end
    assert changes(ctx) == []

    assert [[0]] =
             Repo.query!(
               ~s|SELECT current_revision FROM "#{ctx.prefix}".bpm_memory_partition_revisions WHERE scope='a'|
             ).rows

    assert [[0]] = Repo.query!(~s|SELECT count(*) FROM "#{ctx.prefix}".bpm_memories|).rows
  end

  test "hard deletion emits a tombstone and owner never follows host provenance", ctx do
    id = insert(ctx, "original")
    update(ctx, id, "host_id = 'new-provenance', source_client_id = 'runtime-other'")
    assert length(changes(ctx)) == 1
    Repo.query!(~s|DELETE FROM "#{ctx.prefix}".bpm_memories WHERE id=$1|, [Ecto.UUID.dump!(id)])
    assert List.last(changes(ctx)) == [2, "delete", %{"canonical_id" => id}]
  end

  test "compaction cannot hide a formerly mirrored oversized or revoked copy", ctx do
    id = insert(ctx, "formerly mirrored")
    Repo.query!(~s|DELETE FROM "#{ctx.prefix}".bpm_memory_changes|)
    Repo.query!(~s|UPDATE "#{ctx.prefix}".bpm_memory_space_entitlements SET status='revoked'|)
    update(ctx, id, "content = 'revoked updated content'")
    assert [[2, "delete", %{"canonical_id" => ^id}]] = changes(ctx)
  end

  test "encoded UTF-8 payload size is inclusive and omission notifications are content-free",
       ctx do
    id = insert(ctx, "秘密🧠")
    [[bytes]] = Repo.query!(~s|SELECT payload_bytes FROM "#{ctx.prefix}".bpm_memory_changes|).rows

    Repo.query!(
      ~s|INSERT INTO "#{ctx.prefix}".system_settings (key,value,value_type,updated_at) VALUES ('memory.host_sync_max_item_bytes',jsonb_build_object('v',$1::integer),'integer',now())|,
      [bytes]
    )

    assert [[true]] =
             Repo.query!(
               ~s|SELECT "#{ctx.prefix}".bpm_memory_edge_eligible(m) FROM "#{ctx.prefix}".bpm_memories m|
             ).rows

    Repo.query!(
      ~s|UPDATE "#{ctx.prefix}".system_settings SET value=jsonb_build_object('v',$1::integer)|,
      [bytes - 1]
    )

    assert [[false]] =
             Repo.query!(
               ~s|SELECT "#{ctx.prefix}".bpm_memory_edge_eligible(m) FROM "#{ctx.prefix}".bpm_memories m|
             ).rows

    listener =
      start_supervised!(
        {Postgrex.Notifications, Application.fetch_env!(:backplane_memory, :repo).config()}
      )

    {:ok, ref} = Postgrex.Notifications.listen(listener, "bpm_memory_edge_omitted")
    update(ctx, id, "content = '秘密🧠!'")
    assert_receive {:notification, ^listener, ^ref, "bpm_memory_edge_omitted", payload}, 1000
    assert Jason.decode!(payload) == %{"reason" => "payload_too_large"}
    assert [2, "delete", _] = List.last(changes(ctx))
  end

  test "disabled owner and absent exact entitlement cannot publish new facts", ctx do
    Repo.query!(~s|UPDATE "#{ctx.prefix}".bpm_memory_spaces SET status='disabled'|)
    insert(ctx, "disabled")
    assert changes(ctx) == []
    Repo.query!(~s|UPDATE "#{ctx.prefix}".bpm_memory_spaces SET status='active'|)
    Repo.query!(~s|UPDATE "#{ctx.prefix}".bpm_memory_space_entitlements SET status='revoked'|)
    insert(ctx, "revoked")
    assert changes(ctx) == []
  end

  test "oversized optional wakeup cannot abort canonical and feed commits", ctx do
    scope = String.duplicate("s", 9000)

    Repo.query!(
      ~s|INSERT INTO "#{ctx.prefix}".bpm_memory_space_entitlements (memory_space_id,host_id,scope,namespace,status,inserted_at,updated_at) VALUES ($1,$2,$3,'private','active',now(),now())|,
      [Ecto.UUID.dump!(ctx.space), Ecto.UUID.dump!(ctx.host), scope]
    )

    listener =
      start_supervised!(
        {Postgrex.Notifications, Application.fetch_env!(:backplane_memory, :repo).config()}
      )

    {:ok, ref} = Postgrex.Notifications.listen(listener, "bpm_memory_edge_available")
    id = insert(ctx, "long partition fact", scope)
    assert [[1, "upsert", %{"canonical_id" => ^id}]] = changes(ctx, scope)

    assert [[1]] =
             Repo.query!(~s|SELECT count(*) FROM "#{ctx.prefix}".bpm_memories WHERE id=$1|, [
               Ecto.UUID.dump!(id)
             ]).rows

    refute_receive {:notification, ^listener, ^ref, _, _}, 50
  end

  defp insert(ctx, content, scope \\ "a") do
    id = Ecto.UUID.generate()

    Repo.query!(
      ~s|INSERT INTO "#{ctx.prefix}".bpm_memories (id,memory_space_id,host_id,client_id,scope,namespace,agent_id,content,content_hash,memory_type,lifecycle_state,inserted_at,updated_at) VALUES ($1,$2,$3,$4,$5,'private','test',$6,$7,'semantic','active',now(),now())|,
      [
        Ecto.UUID.dump!(id),
        Ecto.UUID.dump!(ctx.space),
        ctx.host,
        "host:" <> ctx.host,
        scope,
        content,
        :crypto.hash(:sha256, content)
      ]
    )

    id
  end

  defp update(ctx, id, sql) do
    Repo.query!(~s|UPDATE "#{ctx.prefix}".bpm_memories SET #{sql} WHERE id = $1|, [
      Ecto.UUID.dump!(id)
    ])
  end

  defp changes(ctx, scope \\ "a") do
    Repo.query!(
      ~s|SELECT revision,op,payload FROM "#{ctx.prefix}".bpm_memory_changes WHERE scope=$1 AND namespace='private' ORDER BY revision|,
      [scope]
    ).rows
  end
end

defmodule Backplane.Memory.ReadinessTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.Readiness
  alias Backplane.Memory.EdgeSync.SnapshotBuilder
  alias Backplane.MemorySpaces

  defmodule FailingRepo do
    def query!(_sql), do: raise(ArgumentError, "secret token must stay out of readiness reports")
  end

  test "query failures report a safe error type for each blocked category" do
    original_repo = Application.fetch_env!(:backplane_memory, :repo)
    Application.put_env(:backplane_memory, :repo, FailingRepo)

    try do
      assert {:error, report} = Readiness.edge_cutover()
      assert report.status == :blocked
      assert :host_mappings in report.failures
      assert report.error_types.host_mappings == "ArgumentError"
      refute inspect(report) =~ "secret token"
    after
      Application.put_env(:backplane_memory, :repo, original_repo)
    end
  end

  test "Mix cutover check exposes safe error types without exception messages" do
    original_repo = Application.fetch_env!(:backplane_memory, :repo)
    Application.put_env(:backplane_memory, :repo, FailingRepo)

    try do
      error =
        assert_raise Mix.Error, fn ->
          Mix.Tasks.Backplane.Memory.EdgeCutoverCheck.run([])
        end

      assert Exception.message(error) =~ "ArgumentError"
      refute Exception.message(error) =~ "secret token"
    after
      Application.put_env(:backplane_memory, :repo, original_repo)
    end
  end

  test "only resolved or approved issues with a completion time pass" do
    repo().query!("DELETE FROM bpm_memory_space_backfill_issues")
    assert clear?(Readiness.issue_dispositions_sql())

    repo().query!("""
    INSERT INTO bpm_memory_space_backfill_issues
      (source_table,source_id,reason,disposition,details,inserted_at,updated_at)
    VALUES ('readiness_test','pending','test','pending','{}',now(),now())
    """)

    refute clear?(Readiness.issue_dispositions_sql())

    repo().query!(
      "UPDATE bpm_memory_space_backfill_issues SET disposition='resolved' WHERE source_table='readiness_test'"
    )

    refute clear?(Readiness.issue_dispositions_sql())

    repo().query!(
      "UPDATE bpm_memory_space_backfill_issues SET resolved_at=now() WHERE source_table='readiness_test'"
    )

    assert clear?(Readiness.issue_dispositions_sql())

    repo().query!(
      "UPDATE bpm_memory_space_backfill_issues SET disposition='approved_waiver' WHERE source_table='readiness_test'"
    )

    assert clear?(Readiness.issue_dispositions_sql())

    repo().query!(
      "UPDATE bpm_memory_space_backfill_issues SET resolved_at=NULL WHERE source_table='readiness_test'"
    )

    refute clear?(Readiness.issue_dispositions_sql())
  end

  test "cross-partition relation blocks child inventory even when both memories are entitled" do
    first = memory!("first")
    second = memory!("second")
    repo().query!("DELETE FROM bpm_memory_relations")
    assert clear?(Enum.at(Readiness.child_inventory_sql(), 2))

    repo().query!("SET CONSTRAINTS ALL DEFERRED")

    repo().query!(
      """
      INSERT INTO bpm_memory_relations
        (source_memory_id,target_memory_id,domain,relation_type,classification,confidence,
         classifier_model,classifier_version,input_revision,correlation_id)
      VALUES ($1,$2,'knowledge','extends','extension',0.8,'readiness','1','1',$3)
      """,
      [
        Ecto.UUID.dump!(first.id),
        Ecto.UUID.dump!(second.id),
        Ecto.UUID.dump!(Ecto.UUID.generate())
      ]
    )

    refute clear?(Enum.at(Readiness.child_inventory_sql(), 2))

    [[source_id]] =
      repo().query!(
        "SELECT bpm_memory_backfill_source_id('bpm_memory_relations',to_jsonb(child)) FROM bpm_memory_relations child"
      ).rows

    assert_waiver_transition!(
      Enum.at(Readiness.child_inventory_sql(), 2),
      "bpm_memory_relations",
      source_id
    )
  end

  test "an unresolved root needs its own completed waiver" do
    memory = memory!("root-waiver")

    repo().query!(
      "UPDATE bpm_memory_space_entitlements SET status='revoked' WHERE memory_space_id=$1",
      [Ecto.UUID.dump!(memory.partition.memory_space_id)]
    )

    sql = Enum.at(Readiness.root_inventory_sql(), 2)
    refute clear?(sql)

    [[source_id]] =
      repo().query!(
        "SELECT bpm_memory_backfill_source_id('bpm_memories',to_jsonb(root)) FROM bpm_memories root WHERE root.id=$1",
        [Ecto.UUID.dump!(memory.id)]
      ).rows

    assert_waiver_transition!(sql, "bpm_memories", source_id)
    assert :host_mappings in failures()
  end

  test "all 13 child inventories execute against the migrated database" do
    assert length(Readiness.child_inventory_sql()) == 13

    Enum.each(Readiness.child_inventory_sql(), fn sql ->
      assert [[value]] = repo().query!(sql).rows
      assert is_boolean(value)
    end)
  end

  test "audit inventory includes coordination operations and requires one valid target partition" do
    memory = memory!("audit")
    audit_id = Ecto.UUID.dump!(Ecto.UUID.generate())

    selected = fn id ->
      String.replace(
        Readiness.audit_inventory_sql(),
        "WHERE audit.operation IN",
        "WHERE audit.id='#{id}' AND audit.operation IN"
      )
    end

    repo().query!(
      "INSERT INTO memory_audit_log (id,operation,target_ids,metadata) VALUES ($1,'coordination.heal','[]','{}')",
      [audit_id]
    )

    refute clear?(selected.(Ecto.UUID.load!(audit_id)))

    assert_waiver_transition!(
      selected.(Ecto.UUID.load!(audit_id)),
      "memory_audit_log",
      Ecto.UUID.load!(audit_id)
    )

    valid_id = Ecto.UUID.generate()

    repo().query!(
      "INSERT INTO memory_audit_log (id,operation,target_ids,metadata) VALUES ($1,'coordination.heal',jsonb_build_array($2::text),'{}')",
      [Ecto.UUID.dump!(valid_id), memory.id]
    )

    assert [[1]] =
             repo().query!("SELECT count(*) FROM bpm_memories WHERE id=$1", [
               Ecto.UUID.dump!(memory.id)
             ]).rows

    assert [[1]] =
             repo().query!(
               "SELECT count(*) FROM memory_audit_log WHERE id=$1 AND target_ids @> jsonb_build_array($2::text)",
               [Ecto.UUID.dump!(valid_id), memory.id]
             ).rows

    assert clear?(selected.(valid_id))
  end

  test "pending worker-specific jobs require their referenced owners" do
    repo().query!("DELETE FROM oban_jobs WHERE worker LIKE 'Elixir.Backplane.Memory.%'")
    assert clear?(Readiness.job_inventory_sql())

    for {worker, args} <- [
          {"EmbedWorker", %{"id" => Ecto.UUID.generate()}},
          {"AccessWritebackWorker", %{"memory_ids" => [Ecto.UUID.generate()]}},
          {"ProjectionRepairWorker", %{"event_id" => Ecto.UUID.generate()}},
          {"LessonCandidateWorker", %{"event_id" => Ecto.UUID.generate()}},
          {"EpisodicWorker", %{"summary_id" => Ecto.UUID.generate()}},
          {"RelationClassifierWorker", %{"memory_id" => Ecto.UUID.generate(), "partition" => %{}}}
        ] do
      job =
        args
        |> Oban.Job.new(worker: "Elixir.Backplane.Memory.Workers.#{worker}")
        |> repo().insert!()

      refute clear?(Readiness.job_inventory_sql()),
             "#{worker}: #{inspect(job.worker)} #{inspect(job.state)}"

      assert_waiver_transition!(
        Readiness.job_inventory_sql(),
        "oban_jobs",
        Integer.to_string(job.id)
      )

      repo().query!("UPDATE oban_jobs SET state='completed' WHERE id=$1", [job.id])
      assert clear?(Readiness.job_inventory_sql()), worker
    end
  end

  test "coalesced repair jobs require a frontier and a captured source in its entitled session" do
    repo().query!("DELETE FROM oban_jobs WHERE worker LIKE '%Backplane.Memory.%'")
    partition = empty_partition!()
    host_id = partition_host!(partition)
    session_id = "readiness-#{Ecto.UUID.generate()}"
    captured_source!(partition, session_id)
    worker = "Backplane.Memory.Workers.ProjectionRepairWorker"

    for spelling <- [worker, "Elixir." <> worker] do
      job =
        %{"host_id" => host_id, "session_id" => session_id}
        |> Oban.Job.new(worker: spelling)
        |> repo().insert!()

      repo().query!("UPDATE oban_jobs SET worker=$2 WHERE id=$1", [job.id, spelling])
      refute clear?(Readiness.job_inventory_sql()), "orphan frontier: #{spelling}"

      repair_frontier!(host_id, session_id)
      assert clear?(Readiness.job_inventory_sql()), "valid frontier: #{spelling}"

      repo().query!(
        "UPDATE oban_jobs SET args=args || jsonb_build_object('event_id',$2::text) WHERE id=$1",
        [job.id, Ecto.UUID.generate()]
      )

      assert clear?(Readiness.job_inventory_sql()), "converted legacy job: #{spelling}"

      repo().query!(
        "UPDATE oban_jobs SET args=jsonb_build_object('host_id',$2::text) WHERE id=$1",
        [job.id, host_id]
      )

      refute clear?(Readiness.job_inventory_sql()), "incomplete session identity: #{spelling}"

      for {wrong_host, wrong_session} <- [
            {host_id, "wrong-session-#{Ecto.UUID.generate()}"},
            {Ecto.UUID.generate(), session_id}
          ] do
        repair_frontier!(wrong_host, wrong_session)

        repo().query!(
          "UPDATE oban_jobs SET args=jsonb_build_object('host_id',$2::text,'session_id',$3::text) WHERE id=$1",
          [job.id, wrong_host, wrong_session]
        )

        refute clear?(Readiness.job_inventory_sql()),
               "frontier without exact captured source: #{wrong_host}/#{wrong_session}"
      end

      repo().query!(
        "UPDATE oban_jobs SET args=jsonb_build_object('host_id',$2::text,'session_id',$3::text) WHERE id=$1",
        [job.id, host_id, session_id]
      )

      repo().query!(
        "UPDATE bpm_memory_space_entitlements SET status='revoked' WHERE memory_space_id=$1",
        [Ecto.UUID.dump!(partition.memory_space_id)]
      )

      refute clear?(Readiness.job_inventory_sql()), "revoked entitlement: #{spelling}"

      repo().query!(
        "UPDATE bpm_memory_space_entitlements SET status='active' WHERE memory_space_id=$1",
        [Ecto.UUID.dump!(partition.memory_space_id)]
      )

      repo().query!("UPDATE oban_jobs SET state='completed' WHERE id=$1", [job.id])

      repo().query!(
        "DELETE FROM bpm_projection_repair_frontiers WHERE host_id=$1 AND session_id=$2",
        [host_id, session_id]
      )
    end
  end

  test "legacy repair event jobs remain valid for an entitled captured event" do
    repo().query!("DELETE FROM oban_jobs WHERE worker LIKE '%Backplane.Memory.%'")
    partition = empty_partition!()
    event_id = captured_source!(partition, "legacy-#{Ecto.UUID.generate()}")

    job =
      %{"event_id" => event_id}
      |> Oban.Job.new(worker: "Backplane.Memory.Workers.ProjectionRepairWorker")
      |> repo().insert!()

    assert clear?(Readiness.job_inventory_sql())

    repo().query!(
      "UPDATE oban_jobs SET args=jsonb_build_object('event_id',$2::text) WHERE id=$1",
      [
        job.id,
        Ecto.UUID.generate()
      ]
    )

    refute clear?(Readiness.job_inventory_sql())
  end

  test "a host without its private mapping fails closed" do
    id = Ecto.UUID.generate()

    repo().query!(
      "INSERT INTO skill_hosts (id,name,memory_scope,inserted_at,updated_at) VALUES ($1,$2,'global',now(),now())",
      [Ecto.UUID.dump!(id), "readiness-#{id}"]
    )

    assert {:error, %{failures: failures}} = Readiness.edge_cutover()
    assert :host_mappings in failures
  end

  test "Mix wrapper rejects arguments before querying" do
    assert_raise Mix.Error, fn ->
      Mix.Tasks.Backplane.Memory.EdgeCutoverCheck.run(["unexpected"])
    end
  end

  test "a valid empty current snapshot passes integrity qualification" do
    isolate_snapshot_entitlements!()
    partition = empty_partition!()
    snapshot = build_snapshot!(partition)

    assert snapshot.chunk_count == 1
    assert snapshot.item_count == 0
    refute :initial_snapshots in failures()
  end

  test "a populated current snapshot passes and a corrupt newer snapshot cannot be masked" do
    isolate_snapshot_entitlements!()
    %{partition: partition} = memory!("populated")
    first = build_snapshot!(partition)
    assert first.item_count == 1
    refute :initial_snapshots in failures()

    second = build_snapshot!(partition)
    assert second.id != first.id

    repo().query!(
      "UPDATE bpm_memory_snapshots SET integrity_hash='sha256:wrong',inserted_at=now()+interval '1 second' WHERE id=$1",
      [Ecto.UUID.dump!(second.id)]
    )

    assert :initial_snapshots in failures()
  end

  test "missing, building, and expired current snapshots fail closed" do
    isolate_snapshot_entitlements!()
    partition = empty_partition!()
    assert :initial_snapshots in failures()

    snapshot = build_snapshot!(partition)
    refute :initial_snapshots in failures()

    repo().query!("UPDATE bpm_memory_snapshots SET status='building' WHERE id=$1", [
      Ecto.UUID.dump!(snapshot.id)
    ])

    assert :initial_snapshots in failures()

    repo().query!(
      "UPDATE bpm_memory_snapshots SET status='ready',expires_at=now()-interval '1 second' WHERE id=$1",
      [Ecto.UUID.dump!(snapshot.id)]
    )

    assert :initial_snapshots in failures()
  end

  test "payload, encoded byte, chunk hash, and manifest corruption each fail closed" do
    isolate_snapshot_entitlements!()
    snapshot = empty_partition!() |> build_snapshot!()
    id = Ecto.UUID.dump!(snapshot.id)
    refute :initial_snapshots in failures()

    [[original_payload, original_bytes, original_hash]] =
      repo().query!(
        "SELECT payload,encoded_bytes,chunk_hash FROM bpm_memory_snapshot_chunks WHERE snapshot_id=$1",
        [id]
      ).rows

    for {column, value} <- [
          {"payload", "'{\"items\":[1]}'::jsonb"},
          {"encoded_bytes", "999"},
          {"chunk_hash", "'sha256:wrong'"}
        ] do
      repo().query!(
        "UPDATE bpm_memory_snapshot_chunks SET #{column}=#{value} WHERE snapshot_id=$1",
        [id]
      )

      assert :initial_snapshots in failures(), column

      repo().query!(
        "UPDATE bpm_memory_snapshot_chunks SET payload=$2,encoded_bytes=$3,chunk_hash=$4 WHERE snapshot_id=$1",
        [id, original_payload, original_bytes, original_hash]
      )
    end

    repo().query!("UPDATE bpm_memory_snapshots SET integrity_hash='sha256:wrong' WHERE id=$1", [
      id
    ])

    assert :initial_snapshots in failures()
  end

  test "a chunk index gap and an invalid second partition fail closed" do
    isolate_snapshot_entitlements!()
    first = empty_partition!() |> build_snapshot!()
    second_partition = empty_partition!()
    second = build_snapshot!(second_partition)
    refute :initial_snapshots in failures()

    repo().query!("UPDATE bpm_memory_snapshot_chunks SET chunk_index=1 WHERE snapshot_id=$1", [
      Ecto.UUID.dump!(second.id)
    ])

    assert :initial_snapshots in failures()

    repo().query!("UPDATE bpm_memory_snapshot_chunks SET chunk_index=0 WHERE snapshot_id=$1", [
      Ecto.UUID.dump!(second.id)
    ])

    refute :initial_snapshots in failures()
    assert first.id != second.id
  end

  test "a corrupt huge declared chunk count blocks without expanding a SQL sequence" do
    isolate_snapshot_entitlements!()
    snapshot = empty_partition!() |> build_snapshot!()
    refute :initial_snapshots in failures()

    repo().query!("UPDATE bpm_memory_snapshots SET chunk_count=2147483647 WHERE id=$1", [
      Ecto.UUID.dump!(snapshot.id)
    ])

    repo().query!("SET LOCAL statement_timeout='1000ms'")
    assert [[true]] = repo().query!(Readiness.initial_snapshots_sql()).rows
    assert :initial_snapshots in failures()
  end

  defp clear?(sql), do: repo().query!(sql).rows == [[false]]

  defp assert_waiver_transition!(sql, table, source_id) do
    repo().query!(
      """
      INSERT INTO bpm_memory_space_backfill_issues
        (source_table,source_id,reason,disposition,details,inserted_at,updated_at)
      VALUES ($1,$2,'readiness_waiver_test','pending','{}',now(),now())
      """,
      [table, source_id]
    )

    refute clear?(sql), "pending issue incorrectly exempted #{table}"

    repo().query!(
      "UPDATE bpm_memory_space_backfill_issues SET disposition='approved_waiver' WHERE source_table=$1 AND source_id=$2",
      [table, source_id]
    )

    refute clear?(sql), "waiver without resolved_at incorrectly exempted #{table}"

    repo().query!(
      "UPDATE bpm_memory_space_backfill_issues SET resolved_at=now() WHERE source_table=$1 AND source_id=$2",
      [table, source_id]
    )

    assert clear?(sql), "completed waiver did not exempt #{table}"

    repo().query!(
      "UPDATE bpm_memory_space_backfill_issues SET disposition='resolved' WHERE source_table=$1 AND source_id=$2",
      [table, source_id]
    )

    refute clear?(sql), "resolved issue incorrectly exempted unresolved #{table}"
  end

  defp failures do
    case Readiness.edge_cutover() do
      {:ok, report} -> report.failures
      {:error, report} -> report.failures
    end
  end

  defp isolate_snapshot_entitlements! do
    repo().query!(
      "UPDATE bpm_memory_space_entitlements SET status='revoked' WHERE status='active'"
    )
  end

  defp empty_partition! do
    host = Ecto.UUID.generate()

    repo().query!(
      "INSERT INTO skill_hosts (id,name,memory_scope,inserted_at,updated_at) VALUES ($1,$2,'global',now(),now())",
      [Ecto.UUID.dump!(host), "readiness-empty-#{host}"]
    )

    {:ok, partition} = MemorySpaces.provision_private_host(host, "global")
    partition
  end

  defp build_snapshot!(partition) do
    {:ok, snapshot} =
      repo().transaction(fn ->
        SnapshotBuilder.build_locked(partition, %{max_changes: 2, max_frame_bytes: 2000})
      end)

    snapshot
  end

  defp captured_source!(partition, session_id) do
    stream_id = "readiness-stream-#{Ecto.UUID.generate()}"
    event_id = Ecto.UUID.generate()
    host_id = partition_host!(partition)

    repo().query!(
      """
      INSERT INTO bpm_streams
        (stream_id,host_id,session_id,memory_space_id,scope,namespace,inserted_at,updated_at)
      VALUES ($1,$2,$3,$4,$5,$6,now(),now())
      """,
      [
        stream_id,
        host_id,
        session_id,
        Ecto.UUID.dump!(partition.memory_space_id),
        partition.scope,
        partition.namespace
      ]
    )

    repo().query!(
      """
      INSERT INTO bpm_events
        (id,stream_id,sequence,host_id,session_id,memory_space_id,scope,namespace,
         schema_version,event_type,occurred_at,source_sequence,payload_hash)
      VALUES ($1,$2,1,$3,$4,$5,$6,$7,1,'agent.session.started',now(),1,'readiness')
      """,
      [
        Ecto.UUID.dump!(event_id),
        stream_id,
        host_id,
        session_id,
        Ecto.UUID.dump!(partition.memory_space_id),
        partition.scope,
        partition.namespace
      ]
    )

    event_id
  end

  defp partition_host!(partition) do
    [[host_id]] =
      repo().query!(
        "SELECT host_id::text FROM bpm_memory_space_entitlements WHERE memory_space_id=$1 AND status='active' LIMIT 1",
        [Ecto.UUID.dump!(partition.memory_space_id)]
      ).rows

    host_id
  end

  defp repair_frontier!(host_id, session_id) do
    repo().query!(
      """
      INSERT INTO bpm_projection_repair_frontiers (host_id,session_id,inserted_at,updated_at)
      VALUES ($1,$2,now(),now()) ON CONFLICT DO NOTHING
      """,
      [host_id, session_id]
    )
  end

  defp memory!(label) do
    host = Ecto.UUID.generate()

    repo().query!(
      "INSERT INTO skill_hosts (id,name,memory_scope,inserted_at,updated_at) VALUES ($1,$2,'global',now(),now())",
      [Ecto.UUID.dump!(host), label <> host]
    )

    {:ok, partition} = MemorySpaces.provision_private_host(host, "global")
    id = Ecto.UUID.generate()
    content = "readiness #{label}"

    repo().query!(
      """
      INSERT INTO bpm_memories
        (id,memory_space_id,host_id,client_id,scope,namespace,agent_id,content,content_hash,
         memory_type,lifecycle_state,inserted_at,updated_at)
      VALUES ($1,$2,$3,$4,'global','private','test',$5,$6,'semantic','active',now(),now())
      """,
      [
        Ecto.UUID.dump!(id),
        Ecto.UUID.dump!(partition.memory_space_id),
        host,
        "host:" <> host,
        content,
        :crypto.hash(:sha256, content)
      ]
    )

    %{id: id, partition: partition}
  end
end

Code.require_file(
  "../../../../backplane_system/priv/repo/migration_support/memory_legacy_cutover.exs",
  __DIR__
)

defmodule Backplane.Memory.LegacyObservationCutoverTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.Events.{Event, Store}
  alias Backplane.Memory.Projections.{ProjectedObservation, Rebuild}
  alias Backplane.Repo.MemoryLegacyCutover

  defmodule NonTransactionalRepo do
    def in_transaction?, do: false
  end

  setup do
    host_id = Ecto.UUID.generate()
    partition = canonical_partition(host_id)
    space = Ecto.UUID.dump!(partition.memory_space_id)
    host = Ecto.UUID.dump!(host_id)

    repo().query!(
      """
      INSERT INTO bpm_memory_space_legacy_aliases(alias_type,alias_value,memory_space_id,inserted_at,updated_at)
      VALUES('host',$1,$2,now(),now())
      """,
      ["host:" <> host_id, space]
    )

    repo().query!(
      """
      INSERT INTO bpm_memory_space_entitlements(memory_space_id,host_id,scope,namespace,inserted_at,updated_at)
      VALUES($1,$2,'global','private',now(),now())
      """,
      [space, host]
    )

    # Restore both pre-retirement constraints. Fixture inserts must pass their
    # original immediate guard, exactly as committed historical rows did.
    [[definition]] =
      repo().query!("""
      SELECT pg_get_functiondef('bpm_assert_bpm_memory_evidence_canonical_partition'::regproc)
      """).rows

    original_guard =
      Regex.replace(
        ~r/\bbpm_events\b(?="?\s+AS\s+source_observation\b)/i,
        definition,
        "bpm_observations"
      )

    assert original_guard != definition
    repo().query!(original_guard)

    [[recall_guard]] =
      repo().query!("""
      SELECT pg_get_functiondef('bpm_assert_memory_recall_candidates_canonical_partition'::regproc)
      """).rows

    original_recall_guard =
      Regex.replace(
        ~r/(OR EXISTS\s*\(\s*SELECT 1 FROM\s+(?:"[^"]+"|[a-zA-Z_]\w*)\.)bpm_events(\s+AS\s+artifact)/i,
        recall_guard,
        "\\1bpm_observations\\2"
      )

    assert original_recall_guard != recall_guard
    repo().query!(original_recall_guard)

    repo().query!(
      "ALTER TABLE bpm_memory_evidence DROP CONSTRAINT bpm_memory_evidence_source_observation_id_fkey"
    )

    repo().query!("""
    ALTER TABLE bpm_memory_evidence ADD CONSTRAINT bpm_memory_evidence_source_observation_id_fkey
      FOREIGN KEY(source_observation_id) REFERENCES bpm_observations(id) ON DELETE RESTRICT
    """)

    %{partition: partition, space: space}
  end

  test "converts mixed history once, preserves evidence and reserves old request keys", %{
    partition: partition,
    space: space
  } do
    session_id = "retired-mixed-session"
    started_at = ~U[2025-01-01 01:00:00.000000Z]
    observation_at = ~U[2025-01-01 01:10:00.000000Z]
    ended_at = ~U[2025-01-01 02:00:00.000000Z]
    orphan_id = Ecto.UUID.generate()
    linked_id = Ecto.UUID.generate()

    insert_session(partition, session_id, started_at, ended_at)
    insert_observation(partition, session_id, orphan_id, observation_at, false)
    insert_observation(partition, session_id, linked_id, DateTime.add(observation_at, 1), true)

    assert {:ok, linked_event} =
             Store.append(
               Map.merge(partition, %{
                 session_id: session_id,
                 event_type: "legacy.observation",
                 content: "historic lib/example.ex",
                 status: "error",
                 idempotency_key: "old-observation-request",
                 occurred_at: DateTime.add(observation_at, 1),
                 payload: %{
                   "paths" => ["lib/example.ex"],
                   "_backplane" => %{"legacy_observation_id" => linked_id}
                 }
               })
             )

    source_ids = Enum.map([orphan_id, linked_id], &Ecto.UUID.dump!/1)

    assert [[graph_id]] =
             repo().query!(
               """
               INSERT INTO memory_graph_nodes(type,name,memory_space_id,host_id,client_id,
                 source_client_id,scope,namespace,source_observation_ids)
               VALUES('File','lib/example.ex',$1,$2,$3,$3,'global','private',$4) RETURNING id
               """,
               [space, partition.host_id, partition.client_id, source_ids]
             ).rows

    assert [[action_id]] =
             repo().query!(
               """
               INSERT INTO memory_actions(title,memory_space_id,host_id,client_id,
                 source_client_id,scope,namespace,source_observation_ids)
               VALUES('Historic action',$1,$2,$3,$3,'global','private',$4) RETURNING id
               """,
               [space, partition.host_id, partition.client_id, source_ids]
             ).rows

    {:ok, memory} =
      Backplane.Memory.Memories.remember(
        "historic evidence owner",
        canonical_memory_opts(partition.host_id, agent_id: "migration-fixture")
      )

    evidence_id = Ecto.UUID.generate()

    repo().query!(
      """
      INSERT INTO bpm_memory_evidence(id,memory_id,source_observation_id,
        host_id,evidence_kind,support_score)
      VALUES($1,$2,$3,$4,'supports',1.0)
      """,
      [
        Ecto.UUID.dump!(evidence_id),
        Ecto.UUID.dump!(memory.id),
        Ecto.UUID.dump!(linked_id),
        partition.host_id
      ]
    )

    original_evidence = evidence_row(evidence_id)
    recall_id = insert_recall_candidate(partition, linked_id)

    before = MemoryLegacyCutover.inventory(repo: repo())
    assert before.observations == 2
    assert before.sessions == 1
    assert before.invalid_observation_owners == 0

    # Historical rows were committed before an upgrade. Validate the complete
    # fixture at that boundary, including initially deferred crystal evidence
    # checks, before the migration changes its foreign key and partition guard.
    repo().query!("SET CONSTRAINTS ALL IMMEDIATE")

    repo().query!(
      "ALTER TABLE bpm_memory_evidence ENABLE ALWAYS TRIGGER bpm_memory_evidence_immutable_row"
    )

    assert {:ok, :ok} = repo().transaction(fn -> MemoryLegacyCutover.migrate(repo(), nil) end)

    converted = repo().get!(Event, linked_event.id)
    assert converted.schema_version == 1
    assert converted.event_type == "observation.recorded"
    assert converted.occurred_at == DateTime.add(observation_at, 1)
    assert converted.status == "failed"
    assert converted.host_id == partition.host_id
    assert converted.memory_space_id == partition.memory_space_id
    assert converted.client_id == partition.client_id
    assert converted.idempotency_key =~ "memory-api:"
    assert repo().get!(Event, orphan_id).occurred_at == observation_at

    assert [[event_id]] =
             repo().query!("SELECT source_observation_id FROM bpm_memory_evidence WHERE id=$1", [
               Ecto.UUID.dump!(evidence_id)
             ]).rows

    assert Ecto.UUID.load!(event_id) == linked_event.id

    assert Map.delete(evidence_row(evidence_id), "source_observation_id") ==
             Map.delete(original_evidence, "source_observation_id")

    assert [[Ecto.UUID.dump!(linked_event.id)]] ==
             repo().query!("SELECT candidate_id FROM memory_recall_candidates WHERE id=$1", [
               recall_id
             ]).rows

    for {table, id} <- [{"memory_graph_nodes", graph_id}, {"memory_actions", action_id}] do
      assert [[ids]] =
               repo().query!("SELECT source_observation_ids FROM #{table} WHERE id=$1", [id]).rows

      assert Enum.map(ids, &Ecto.UUID.load!/1) == [orphan_id, linked_event.id]
    end

    assert [["old-observation-request"]] =
             repo().query!(
               "SELECT original_idempotency_key FROM bpm_observation_event_migrations WHERE observation_id=$1",
               [Ecto.UUID.dump!(linked_id)]
             ).rows

    assert {:error, :idempotency_conflict} =
             Backplane.Memory.Observations.record(
               session_id,
               "historic lib/example.ex",
               Map.to_list(partition) ++ [idempotency_key: "old-observation-request"]
             )

    assert {:ok, _} = Rebuild.session(partition.host_id, session_id)

    assert %ProjectedObservation{is_error: true, file_paths: ["lib/example.ex"]} =
             repo().get!(ProjectedObservation, linked_event.id)

    count = repo().aggregate(Event, :count)
    assert {:ok, :ok} = repo().transaction(fn -> MemoryLegacyCutover.migrate(repo(), nil) end)
    assert repo().aggregate(Event, :count) == count
    assert [[2]] = repo().query!("SELECT count(*) FROM bpm_observation_event_migrations").rows
    assert [[2]] = repo().query!("SELECT count(*) FROM bpm_observations").rows
    assert evidence_trigger_mode() == "A"
    assert_evidence_immutable(evidence_id)

    assert [["bpm_events"]] =
             repo().query!("""
             SELECT confrelid::regclass::text FROM pg_constraint
             WHERE conname='bpm_memory_evidence_source_observation_id_fkey'
               AND conrelid='bpm_memory_evidence'::regclass
             """).rows
  end

  test "refuses nontransactional callers before issuing SQL" do
    assert_raise Ecto.MigrationError, ~r/requires an existing transaction/, fn ->
      MemoryLegacyCutover.migrate(NonTransactionalRepo, nil)
    end
  end

  test "overlapping observation and event IDs are remapped only once", %{partition: partition} do
    first = Ecto.UUID.generate()
    insert_observation(partition, "overlapping", first, DateTime.utc_now(), false)
    first_event = insert_linked_event(partition, "overlapping", first)
    insert_observation(partition, "overlapping", first_event.id, DateTime.utc_now(), false)
    second_event = insert_linked_event(partition, "overlapping", first_event.id)
    evidence_id = insert_evidence(partition, first)
    graph_id = insert_graph(partition, [first, first_event.id, first])
    recall_id = insert_recall_candidate(partition, first)
    repo().query!("SET CONSTRAINTS ALL IMMEDIATE")

    for _ <- 1..2 do
      assert {:ok, :ok} = repo().transaction(fn -> MemoryLegacyCutover.migrate(repo(), nil) end)
      assert evidence_row(evidence_id)["source_observation_id"] == first_event.id

      assert [[Enum.map([first_event.id, second_event.id, first_event.id], &Ecto.UUID.dump!/1)]] ==
               repo().query!(
                 "SELECT source_observation_ids FROM memory_graph_nodes WHERE id=$1",
                 [
                   graph_id
                 ]
               ).rows

      assert [[Ecto.UUID.dump!(first_event.id)]] ==
               repo().query!("SELECT candidate_id FROM memory_recall_candidates WHERE id=$1", [
                 recall_id
               ]).rows
    end

    assert evidence_trigger_mode() == "O"
    assert_evidence_immutable(evidence_id)
  end

  test "foreign graph provenance aborts and restores rows, guards and foreign key", %{
    partition: partition
  } do
    observation_id = Ecto.UUID.generate()
    insert_observation(partition, "rollback-reference", observation_id, DateTime.utc_now(), false)
    event = insert_linked_event(partition, "rollback-reference", observation_id)
    evidence_id = insert_evidence(partition, observation_id)
    foreign = canonical_partition(Ecto.UUID.generate())
    graph_id = insert_graph(foreign, [observation_id])
    repo().query!("SET CONSTRAINTS ALL IMMEDIATE")
    original_evidence = evidence_row(evidence_id)
    original_event = repo().get!(Event, event.id)

    [[original_guard]] =
      repo().query!("""
      SELECT pg_get_functiondef('bpm_assert_bpm_memory_evidence_canonical_partition'::regproc)
      """).rows

    assert_raise Ecto.MigrationError, ~r/references in memory_graph_nodes/, fn ->
      repo().transaction(fn -> MemoryLegacyCutover.migrate(repo(), nil) end)
    end

    assert evidence_row(evidence_id) == original_evidence
    assert repo().get!(Event, event.id) == original_event
    assert [[0]] = repo().query!("SELECT count(*) FROM bpm_observation_event_migrations").rows

    assert [["bpm_observations"]] =
             repo().query!("""
             SELECT confrelid::regclass::text FROM pg_constraint
             WHERE conname='bpm_memory_evidence_source_observation_id_fkey'
               AND conrelid='bpm_memory_evidence'::regclass
             """).rows

    assert [[original_guard]] ==
             repo().query!("""
             SELECT pg_get_functiondef('bpm_assert_bpm_memory_evidence_canonical_partition'::regproc)
             """).rows

    assert [[Enum.map([observation_id], &Ecto.UUID.dump!/1)]] ==
             repo().query!("SELECT source_observation_ids FROM memory_graph_nodes WHERE id=$1", [
               graph_id
             ]).rows

    assert evidence_trigger_mode() == "O"
    assert_evidence_immutable(evidence_id)
  end

  test "missing authoritative host mappings are reported without inventing an owner", %{
    partition: partition
  } do
    insert_observation(partition, "unmapped", Ecto.UUID.generate(), DateTime.utc_now(), false)

    repo().query!("DELETE FROM bpm_memory_space_legacy_aliases WHERE alias_value=$1", [
      "host:" <> partition.host_id
    ])

    assert MemoryLegacyCutover.inventory(repo: repo()).invalid_observation_owners == 1

    assert_raise Ecto.MigrationError, ~r/verified historical ownership/, fn ->
      repo().transaction(fn -> MemoryLegacyCutover.migrate(repo(), nil) end)
    end

    assert repo().aggregate(Event, :count) == 0
    assert [[1]] = repo().query!("SELECT count(*) FROM bpm_observations").rows
  end

  test "already canonical linked events remain immutable", %{partition: partition} do
    id = Ecto.UUID.generate()
    insert_observation(partition, "canonical-linked", id, DateTime.utc_now(), false)

    assert {:ok, event} =
             Store.append(
               Map.merge(partition, %{
                 schema_version: 1,
                 integration: "capture-fixture",
                 session_id: "canonical-linked",
                 event_type: "agent.tool.completed",
                 source_sequence: 1,
                 payload: %{"_backplane" => %{"legacy_observation_id" => id}},
                 occurred_at: ~U[2025-02-01 00:00:00.000000Z]
               })
             )

    persisted = repo().get!(Event, event.id)
    assert {:ok, :ok} = repo().transaction(fn -> MemoryLegacyCutover.migrate(repo(), nil) end)
    assert repo().get!(Event, event.id) == persisted

    assert [[mapped]] =
             repo().query!(
               "SELECT event_id FROM bpm_observation_event_migrations WHERE observation_id=$1",
               [Ecto.UUID.dump!(id)]
             ).rows

    assert Ecto.UUID.load!(mapped) == event.id

    assert repo().get_by!(Backplane.Memory.Projections.RepairFrontier,
             host_id: partition.host_id,
             session_id: "canonical-linked"
           )

    assert [_job] =
             Styx.Testing.all_enqueued(repo(),
               worker: Backplane.Memory.Workers.ProjectionRepairWorker,
               args: %{"host_id" => partition.host_id, "session_id" => "canonical-linked"}
             )
  end

  test "a linked event from another canonical partition aborts the conversion", %{
    partition: partition
  } do
    id = Ecto.UUID.generate()
    insert_observation(partition, "foreign-linked", id, DateTime.utc_now(), false)
    foreign = canonical_partition(Ecto.UUID.generate())

    assert {:ok, event} =
             Store.append(
               Map.merge(foreign, %{
                 session_id: "foreign-linked",
                 event_type: "legacy.observation",
                 payload: %{"_backplane" => %{"legacy_observation_id" => id}}
               })
             )

    assert_raise Ecto.MigrationError, ~r/crosses its original partition/, fn ->
      repo().transaction(fn -> MemoryLegacyCutover.migrate(repo(), nil) end)
    end

    assert repo().get!(Event, event.id).schema_version == nil
    assert [[0]] = repo().query!("SELECT count(*) FROM bpm_observation_event_migrations").rows
  end

  test "ambiguous source provenance is reported before importing unreadable subjects", %{
    partition: partition
  } do
    insert_session(partition, "ambiguous-source", DateTime.utc_now(), nil)

    insert_observation(
      %{partition | source_client_id: "other-source"},
      "ambiguous-source",
      Ecto.UUID.generate(),
      DateTime.utc_now(),
      false
    )

    assert MemoryLegacyCutover.inventory(repo: repo()).ambiguous_subjects == 1

    assert_raise Ecto.MigrationError, ~r/verified historical ownership/, fn ->
      repo().transaction(fn -> MemoryLegacyCutover.migrate(repo(), nil) end)
    end

    assert repo().aggregate(Event, :count) == 0
  end

  defp insert_session(partition, session_id, started_at, ended_at) do
    repo().query!(
      """
      INSERT INTO memory_sessions(session_id,memory_space_id,host_id,source_client_id,
        scope,namespace,project,started_at,ended_at)
      VALUES($1,$2,$3,$4,'global','private','historic-project',$5,$6)
      """,
      [
        session_id,
        Ecto.UUID.dump!(partition.memory_space_id),
        partition.host_id,
        partition.source_client_id,
        started_at,
        ended_at
      ]
    )
  end

  defp insert_linked_event(partition, session_id, observation_id) do
    {:ok, event} =
      Store.append(
        Map.merge(partition, %{
          session_id: session_id,
          event_type: "legacy.observation",
          content: "historic lib/example.ex",
          occurred_at: DateTime.utc_now(),
          payload: %{"_backplane" => %{"legacy_observation_id" => observation_id}}
        })
      )

    event
  end

  defp insert_evidence(partition, observation_id) do
    {:ok, memory} =
      Backplane.Memory.Memories.remember(
        "historic evidence #{observation_id}",
        canonical_memory_opts(partition.host_id, agent_id: "migration-fixture")
      )

    id = Ecto.UUID.generate()

    repo().query!(
      """
      INSERT INTO bpm_memory_evidence(id,memory_id,source_observation_id,
        host_id,evidence_kind,support_score)
      VALUES($1,$2,$3,$4,'supports',1.0)
      """,
      [
        Ecto.UUID.dump!(id),
        Ecto.UUID.dump!(memory.id),
        Ecto.UUID.dump!(observation_id),
        partition.host_id
      ]
    )

    id
  end

  defp insert_graph(partition, sources) do
    [[id]] =
      repo().query!(
        """
        INSERT INTO memory_graph_nodes(type,name,memory_space_id,host_id,client_id,
          source_client_id,scope,namespace,source_observation_ids)
        VALUES('File','lib/example.ex',$1,$2,$3,$4,$5,$6,$7) RETURNING id
        """,
        [
          Ecto.UUID.dump!(partition.memory_space_id),
          partition.host_id,
          partition.client_id,
          partition.source_client_id,
          partition.scope,
          partition.namespace,
          Enum.map(sources, &Ecto.UUID.dump!/1)
        ]
      ).rows

    id
  end

  defp insert_recall_candidate(partition, observation_id) do
    run_id = Ecto.UUID.dump!(Ecto.UUID.generate())
    candidate_id = Ecto.UUID.dump!(Ecto.UUID.generate())

    repo().query!(
      """
      INSERT INTO memory_recall_runs(id,memory_space_id,host_id,client_id,scope,namespace,
        request_id,correlation_id,query_hash,token_budget,expires_at,inserted_at,updated_at)
      VALUES($1,$2,$3,$4,$5,$6,$7,$7,$8,100,now()+interval '1 day',now(),now())
      """,
      [
        run_id,
        Ecto.UUID.dump!(partition.memory_space_id),
        partition.host_id,
        partition.client_id,
        partition.scope,
        partition.namespace,
        Ecto.UUID.generate(),
        :crypto.hash(:sha256, "legacy recall")
      ]
    )

    repo().query!(
      """
      INSERT INTO memory_recall_candidates(id,host_id,client_id,scope,namespace,recall_run_id,
        candidate_id,candidate_kind,memory_type,source_ids,selected,token_estimate,
        inserted_at,updated_at)
      VALUES($1,$2,$3,$4,$5,$6,$7,'observation','episodic',$8,true,1,now(),now())
      """,
      [
        candidate_id,
        partition.host_id,
        partition.client_id,
        partition.scope,
        partition.namespace,
        run_id,
        Ecto.UUID.dump!(observation_id),
        [Ecto.UUID.dump!(observation_id)]
      ]
    )

    candidate_id
  end

  defp evidence_row(id) do
    [[row]] =
      repo().query!("SELECT to_jsonb(evidence) FROM bpm_memory_evidence evidence WHERE id=$1", [
        Ecto.UUID.dump!(id)
      ]).rows

    row
  end

  defp evidence_trigger_mode do
    [[mode]] =
      repo().query!("""
      SELECT tgenabled::text FROM pg_trigger
      WHERE tgrelid='bpm_memory_evidence'::regclass AND tgname='bpm_memory_evidence_immutable_row'
      """).rows

    mode
  end

  defp assert_evidence_immutable(id) do
    for statement <- [
          "UPDATE bpm_memory_evidence SET support_score=0.5 WHERE id=$1",
          "DELETE FROM bpm_memory_evidence WHERE id=$1"
        ] do
      error =
        assert_raise Postgrex.Error, fn ->
          repo().transaction(
            fn -> repo().query!(statement, [Ecto.UUID.dump!(id)]) end,
            mode: :savepoint
          )
        end

      assert error.postgres.pg_code == "55000"
    end
  end

  defp insert_observation(partition, session_id, id, time, error?) do
    repo().query!(
      """
      INSERT INTO bpm_observations(id,memory_space_id,host_id,source_client_id,scope,
        namespace,session_id,content,is_error,files,created_at)
      VALUES($1,$2,$3,$4,'global','private',$5,'historic lib/example.ex',$6,$7,$8)
      """,
      [
        Ecto.UUID.dump!(id),
        Ecto.UUID.dump!(partition.memory_space_id),
        partition.host_id,
        partition.source_client_id,
        session_id,
        error?,
        %{"paths" => ["lib/example.ex"]},
        time
      ]
    )
  end
end

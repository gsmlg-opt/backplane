defmodule Backplane.Repo.MemoryLegacyCutover do
  @moduledoc """
  One-time, transactional retirement of historical observation/session storage.

  This module is a migration tool, never an ingestion or retrieval fallback. It
  preserves old rows for review and rejects missing or ambiguous ownership rather
  than assigning historical data to a synthetic owner.

  Call `migrate/2` inside the migration's transaction, with committed historical
  input. Any exception must abort that transaction, including its trigger DDL.
  """

  @page_size 250

  def inventory(opts \\ []) do
    repo = Keyword.fetch!(opts, :repo)
    p = prefix(Keyword.get(opts, :prefix))

    %{
      observations: count(repo, "SELECT count(*) FROM #{p}.bpm_observations"),
      sessions: count(repo, "SELECT count(*) FROM #{p}.memory_sessions"),
      invalid_observation_owners: count(repo, invalid_owners_sql(p, "bpm_observations")),
      invalid_session_owners: count(repo, invalid_owners_sql(p, "memory_sessions")),
      ambiguous_subjects: count(repo, ambiguous_subjects_sql(p))
    }
  end

  @doc false
  def migrate(repo, migration_prefix) do
    unless repo.in_transaction?() do
      raise Ecto.MigrationError, message: "Memory retirement requires an existing transaction"
    end

    p = prefix(migration_prefix)

    repo.query!("""
    LOCK TABLE #{p}.bpm_events, #{p}.bpm_streams, #{p}.bpm_observations,
      #{p}.memory_sessions, #{p}.bpm_memory_evidence,
      #{p}.memory_graph_nodes, #{p}.memory_actions,
      #{p}.memory_recall_candidates IN SHARE ROW EXCLUSIVE MODE
    """)

    reference_target = reference_target!(repo, p)
    restore_trigger = evidence_trigger_mode!(repo, p)
    report = inventory(repo: repo, prefix: migration_prefix)

    if report.invalid_observation_owners > 0 or report.invalid_session_owners > 0 or
         report.ambiguous_subjects > 0 do
      raise Ecto.MigrationError,
        message: "Memory retirement requires verified historical ownership: #{inspect(report)}"
    end

    repo.query!("""
    CREATE TABLE IF NOT EXISTS #{p}.bpm_observation_event_migrations (
      observation_id uuid PRIMARY KEY,
      event_id uuid NOT NULL UNIQUE REFERENCES #{p}.bpm_events(id) ON DELETE RESTRICT,
      original_idempotency_key text,
      original_event_fingerprint text,
      migrated_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    migrate_sessions(repo, p, nil, :start)
    migrate_observations(repo, p, 0)
    migrate_sessions(repo, p, nil, :end)
    install_canonical_guards(repo, p)
    if reference_target == :legacy, do: remap_references(repo, p, restore_trigger)
    qualify_evidence(repo, p)
    qualify_artifact_references(repo, p)
    queue_projection_repairs(repo, p)
    :ok
  end

  defp migrate_sessions(repo, p, cursor, phase) do
    rows =
      query_maps(
        repo,
        """
        SELECT session.* FROM #{p}.memory_sessions session
        WHERE ($1::text IS NULL OR session.session_id > $1)
        ORDER BY session.session_id LIMIT #{@page_size}
        """,
        [cursor]
      )

    Enum.each(rows, fn row ->
      partition = historical_partition(row)
      stream = ensure_stream(repo, p, row["session_id"], partition, row["project"])

      case phase do
        :start ->
          lifecycle(repo, p, row, partition, stream, "session.started", row["started_at"])

        :end ->
          if row["ended_at"],
            do: lifecycle(repo, p, row, partition, stream, "session.ended", row["ended_at"])
      end
    end)

    if length(rows) == @page_size,
      do: migrate_sessions(repo, p, List.last(rows)["session_id"], phase)
  end

  defp lifecycle(repo, p, row, partition, stream, type, time) do
    existing =
      query_maps(
        repo,
        """
        SELECT * FROM #{p}.bpm_events
        WHERE memory_space_id=$1 AND scope=$2 AND namespace=$3 AND host_id=$4
          AND session_id=$5 AND event_type=$6
        ORDER BY sequence LIMIT 2
        """,
        [
          partition.memory_space_id,
          partition.scope,
          partition.namespace,
          partition.host_id,
          row["session_id"],
          type
        ]
      )

    case existing do
      [] ->
        insert_event(repo, p, stream, partition, %{
          "id" => Ecto.UUID.dump!(Ecto.UUID.generate()),
          "session_id" => row["session_id"],
          "project" => row["project"],
          "event_type" => type,
          "payload" => %{},
          "occurred_at" => time || row["ended_at"]
        })

      [%{"schema_version" => version}] when not is_nil(version) ->
        :ok

      [event] ->
        canonicalize_event(repo, p, stream, partition, event)

      _ambiguous ->
        raise Ecto.MigrationError, message: "Ambiguous historical session lifecycle"
    end
  end

  defp migrate_observations(repo, p, offset) do
    rows =
      query_maps(
        repo,
        """
        SELECT observation.* FROM #{p}.bpm_observations observation
        ORDER BY observation.created_at,observation.id LIMIT #{@page_size} OFFSET $1
        """,
        [offset]
      )

    Enum.each(rows, fn row ->
      migrated? =
        count(
          repo,
          "SELECT count(*) FROM #{p}.bpm_observation_event_migrations WHERE observation_id=$1",
          [row["id"]]
        ) > 0

      unless migrated? do
        partition = historical_partition(row)
        stream = ensure_stream(repo, p, row["session_id"], partition, nil)
        linked = linked_events(repo, p, row)

        event_id =
          case linked do
            [] ->
              insert_event(repo, p, stream, partition, %{
                "id" => row["id"],
                "session_id" => row["session_id"],
                "event_type" => observation_type(row),
                "content" => row["content"],
                "tool_name" => row["tool_name"],
                "status" => if(row["is_error"], do: "failed", else: "ok"),
                "payload" => row["files"] || %{},
                "occurred_at" => row["created_at"]
              })

            [%{"schema_version" => version} = event] when not is_nil(version) ->
              assert_same_owner!(row, event)
              event["id"]

            [event] ->
              assert_same_owner!(row, event)
              canonicalize_event(repo, p, stream, partition, event)

            _ambiguous ->
              raise Ecto.MigrationError, message: "Ambiguous observation to event mapping"
          end

        repo.query!(
          """
          INSERT INTO #{p}.bpm_observation_event_migrations(observation_id,event_id,
            original_idempotency_key,original_event_fingerprint)
          VALUES($1,$2,$3,$4) ON CONFLICT(observation_id) DO NOTHING
          """,
          [
            row["id"],
            event_id,
            linked |> List.first(%{}) |> Map.get("idempotency_key"),
            linked
            |> List.first(%{})
            |> Map.get("payload", %{})
            |> get_in(["_backplane", "event_fingerprint"])
          ]
        )
      end
    end)

    if length(rows) == @page_size,
      do: migrate_observations(repo, p, offset + @page_size)
  end

  defp linked_events(repo, p, row) do
    query_maps(
      repo,
      """
      SELECT * FROM #{p}.bpm_events
      WHERE payload->'_backplane'->>'legacy_observation_id'=$1
      ORDER BY id LIMIT 2
      """,
      [Ecto.UUID.load!(row["id"])]
    )
  end

  defp historical_partition(row) do
    %{
      memory_space_id: row["memory_space_id"],
      host_id: row["host_id"],
      client_id: "host:" <> row["host_id"],
      source_client_id: row["source_client_id"],
      scope: row["scope"],
      namespace: row["namespace"]
    }
  end

  defp ensure_stream(repo, p, session_id, partition, project) do
    identity = [
      Ecto.UUID.load!(partition.memory_space_id),
      partition.scope,
      partition.namespace,
      partition.host_id,
      session_id
    ]

    stream_id = "memory-api:" <> Base.url_encode64(Jason.encode!(identity), padding: false)

    repo.query!(
      """
      INSERT INTO #{p}.bpm_streams(stream_id,memory_space_id,host_id,client_id,
        source_client_id,scope,namespace,session_id,project,next_sequence,
        last_window_sequence,inserted_at,updated_at)
      VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,1,0,now(),now())
      ON CONFLICT(stream_id) DO NOTHING
      """,
      [
        stream_id,
        partition.memory_space_id,
        partition.host_id,
        partition.client_id,
        partition.source_client_id,
        partition.scope,
        partition.namespace,
        session_id,
        project
      ]
    )

    stream_id
  end

  defp canonicalize_event(repo, p, stream, partition, event) do
    insert_event(repo, p, stream, partition, event, :update)
  end

  defp insert_event(repo, p, stream, partition, event, operation \\ :insert) do
    if is_nil(event["occurred_at"]) do
      raise Ecto.MigrationError, message: "Historical memory event has no valid occurrence time"
    end

    sequence =
      count(repo, "SELECT next_sequence FROM #{p}.bpm_streams WHERE stream_id=$1", [stream])

    source_sequence =
      count(
        repo,
        """
        SELECT coalesce(max(source_sequence),0)+1 FROM #{p}.bpm_events
        WHERE host_id=$1 AND session_id=$2
        """,
        [partition.host_id, event["session_id"]]
      )

    payload = event["payload"] || %{}

    event_type =
      if event["event_type"] == "legacy.observation",
        do: "observation.recorded",
        else: event["event_type"]

    status = if event["status"] == "error", do: "failed", else: event["status"] || "ok"
    id = event["id"]

    params = [
      id,
      stream,
      sequence,
      partition.memory_space_id,
      partition.host_id,
      partition.client_id,
      partition.source_client_id,
      partition.scope,
      partition.namespace,
      event["session_id"],
      event["project"],
      event_type,
      event["content"],
      event["tool_name"],
      status,
      payload,
      event["occurred_at"],
      source_sequence,
      payload_hash(payload),
      namespaced_key(event["idempotency_key"], partition)
    ]

    sql =
      case operation do
        :insert ->
          """
          INSERT INTO #{p}.bpm_events(id,stream_id,sequence,memory_space_id,host_id,
            client_id,source_client_id,scope,namespace,session_id,project,event_type,
            content,tool_name,status,payload,occurred_at,source_sequence,payload_hash,
            schema_version,integration,actor_type,role,importance,privacy,trace,
            raw_envelope,captured_at,inserted_at,idempotency_key)
          VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,
            1,'memory-api','system','system',0,'{}','{}','{}',$17,now(),$20)
          """

        :update ->
          """
          UPDATE #{p}.bpm_events SET stream_id=$2,sequence=$3,memory_space_id=$4,
            host_id=$5,client_id=$6,source_client_id=$7,scope=$8,namespace=$9,
            session_id=$10,project=$11,event_type=$12,content=$13,tool_name=$14,
            status=$15,payload=$16,occurred_at=$17,source_sequence=$18,payload_hash=$19,
            schema_version=1,integration='memory-api',captured_at=coalesce(captured_at,$17),
            idempotency_key=$20
          WHERE id=$1 AND schema_version IS NULL
          """
      end

    repo.query!(sql, params)

    repo.query!(
      """
      UPDATE #{p}.bpm_streams SET next_sequence=$2,last_event_at=greatest(last_event_at,$3),
        project=coalesce(project,$4),updated_at=now() WHERE stream_id=$1
      """,
      [stream, sequence + 1, event["occurred_at"], event["project"]]
    )

    id
  end

  defp reference_target!(repo, p) do
    case repo.query!(
           """
           SELECT CASE
             WHEN confrelid=$2::text::regclass THEN 'legacy'
             WHEN confrelid=$3::text::regclass THEN 'canonical'
             ELSE 'unexpected' END
           FROM pg_constraint
           WHERE conrelid=$1::text::regclass AND contype='f' AND convalidated
             AND conname='bpm_memory_evidence_source_observation_id_fkey'
           """,
           ["#{p}.bpm_memory_evidence", "#{p}.bpm_observations", "#{p}.bpm_events"]
         ).rows do
      [["legacy"]] ->
        :legacy

      [["canonical"]] ->
        :canonical

      _ ->
        raise Ecto.MigrationError, message: "Unexpected Memory observation evidence foreign key"
    end
  end

  defp evidence_trigger_mode!(repo, p) do
    case repo.query!(
           """
           SELECT tgenabled::text FROM pg_trigger
           WHERE tgrelid=$1::text::regclass AND NOT tgisinternal AND tgtype=27
             AND tgname='bpm_memory_evidence_immutable_row'
             AND tgfoid=$2::text::regproc
           """,
           ["#{p}.bpm_memory_evidence", "#{p}.bpm_reject_memory_provenance_mutation"]
         ).rows do
      [["O"]] -> "ENABLE"
      [["A"]] -> "ENABLE ALWAYS"
      [["R"]] -> "ENABLE REPLICA"
      _ -> raise Ecto.MigrationError, message: "Memory evidence immutability guard is not enabled"
    end
  end

  defp remap_references(repo, p, restore_trigger) do
    repo.query!(
      "ALTER TABLE #{p}.bpm_memory_evidence DROP CONSTRAINT bpm_memory_evidence_source_observation_id_fkey"
    )

    # Only this table's unconditional row guard is suspended. Its partition,
    # source, crystal and truncate guards remain active. Failure rolls the DDL
    # back with the transaction; a failed SQL transaction cannot run cleanup SQL.
    repo.query!(
      "ALTER TABLE #{p}.bpm_memory_evidence DISABLE TRIGGER bpm_memory_evidence_immutable_row"
    )

    [[expected, updated, invalid]] =
      repo.query!("""
      WITH original AS MATERIALIZED (
        SELECT evidence.id,to_jsonb(evidence) AS document,mapping.event_id
        FROM #{p}.bpm_memory_evidence evidence
        JOIN #{p}.bpm_observation_event_migrations mapping
          ON evidence.source_observation_id=mapping.observation_id
        WHERE evidence.source_observation_id<>mapping.event_id
      ), remapped AS (
        UPDATE #{p}.bpm_memory_evidence evidence SET source_observation_id=original.event_id
        FROM original WHERE evidence.id=original.id
        RETURNING to_jsonb(evidence) AS document,original.document AS old_document,original.event_id
      )
      SELECT (SELECT count(*) FROM original),count(*),count(*) FILTER (
        WHERE document-'source_observation_id' IS DISTINCT FROM old_document-'source_observation_id'
          OR document->>'source_observation_id' IS DISTINCT FROM event_id::text)
      FROM remapped
      """).rows

    if expected != updated or invalid != 0 do
      raise Ecto.MigrationError, message: "Memory evidence remap changed immutable provenance"
    end

    repo.query!(
      "ALTER TABLE #{p}.bpm_memory_evidence #{restore_trigger} TRIGGER bpm_memory_evidence_immutable_row"
    )

    Enum.each(~w(memory_graph_nodes memory_actions), fn table ->
      repo.query!("""
      UPDATE #{p}.#{table} artifact SET source_observation_ids=ARRAY(
        SELECT coalesce(mapping.event_id,source.id)
        FROM unnest(artifact.source_observation_ids) WITH ORDINALITY source(id,position)
        LEFT JOIN #{p}.bpm_observation_event_migrations mapping ON mapping.observation_id=source.id
        ORDER BY source.position)
      WHERE EXISTS (SELECT 1 FROM unnest(artifact.source_observation_ids) source(id)
                    JOIN #{p}.bpm_observation_event_migrations mapping ON mapping.observation_id=source.id)
      """)
    end)

    repo.query!("""
    UPDATE #{p}.memory_recall_candidates candidate SET candidate_id=mapping.event_id
    FROM #{p}.bpm_observation_event_migrations mapping
    WHERE candidate.candidate_kind='observation' AND candidate.candidate_id=mapping.observation_id
      AND candidate.candidate_id<>mapping.event_id
    """)

    repo.query!("""
    ALTER TABLE #{p}.bpm_memory_evidence ADD CONSTRAINT bpm_memory_evidence_source_observation_id_fkey
      FOREIGN KEY(source_observation_id) REFERENCES #{p}.bpm_events(id) ON DELETE RESTRICT
    """)
  end

  defp install_canonical_guards(repo, p) do
    # The original partition guards are preserved, replacing only their retired
    # observation relation. No authorization predicate is removed.
    Enum.each(
      ~w(bpm_assert_bpm_memory_evidence_canonical_partition bpm_assert_memory_recall_candidates_canonical_partition),
      fn name ->
        definition =
          repo.query!("SELECT pg_get_functiondef($1::text::regproc)", ["#{p}.#{name}"]).rows
          |> hd()
          |> hd()

        definition = String.replace(definition, ~r/\bbpm_observations\b/, "bpm_events")
        repo.query!(definition)
      end
    )
  end

  defp qualify_evidence(repo, p) do
    invalid =
      count(repo, """
      SELECT count(*) FROM #{p}.bpm_memory_evidence evidence
      LEFT JOIN #{p}.bpm_events event ON event.id=evidence.source_observation_id
      LEFT JOIN #{p}.bpm_memories owner ON owner.id=evidence.memory_id
      WHERE evidence.source_observation_id IS NOT NULL
        AND (event.schema_version IS NULL OR
             #{p}.bpm_memory_partitions_match(to_jsonb(owner),to_jsonb(event)) IS NOT TRUE)
      """)

    if invalid > 0,
      do:
        raise(Ecto.MigrationError,
          message: "Unresolved canonical observation evidence: #{invalid}"
        )
  end

  defp qualify_artifact_references(repo, p) do
    Enum.each(~w(memory_graph_nodes memory_actions), fn table ->
      invalid =
        count(repo, """
        SELECT count(*) FROM #{p}.#{table} artifact
        CROSS JOIN LATERAL unnest(artifact.source_observation_ids) source(id)
        LEFT JOIN #{p}.bpm_events event ON event.id=source.id
        WHERE event.schema_version IS NULL OR
          #{p}.bpm_memory_partitions_match(to_jsonb(artifact),to_jsonb(event)) IS NOT TRUE
        """)

      if invalid > 0 do
        raise Ecto.MigrationError,
          message: "Unresolved canonical observation references in #{table}: #{invalid}"
      end
    end)

    invalid =
      count(repo, """
      SELECT count(*) FROM #{p}.memory_recall_candidates candidate
      LEFT JOIN #{p}.memory_recall_runs owner ON owner.id=candidate.recall_run_id
      LEFT JOIN #{p}.bpm_events event ON event.id=candidate.candidate_id
      WHERE candidate.candidate_kind='observation' AND (
        event.schema_version IS NULL OR
        candidate.scope IS DISTINCT FROM owner.scope OR
        candidate.namespace IS DISTINCT FROM owner.namespace OR
        #{p}.bpm_memory_partitions_match(to_jsonb(owner),to_jsonb(event)) IS NOT TRUE)
      """)

    if invalid > 0 do
      raise Ecto.MigrationError,
        message: "Unresolved canonical observation recall candidates: #{invalid}"
    end
  end

  defp queue_projection_repairs(repo, p) do
    repo.query!("""
    UPDATE #{p}.bpm_streams stream SET closed_at=ended.occurred_at
    FROM #{p}.bpm_events ended WHERE ended.stream_id=stream.stream_id
      AND ended.schema_version IS NOT NULL AND ended.event_type='session.ended'
    """)

    # The normal repair worker owns complete deterministic rebuilding. A durable
    # frontier is sufficient to recover if the migration process exits here.
    repo.query!("""
    INSERT INTO #{p}.bpm_projection_repair_frontiers AS frontier(host_id,session_id,requested_generation,
      requested_revision,inserted_at,updated_at)
    SELECT DISTINCT host_id,session_id,1,'legacy-cutover-pending',now(),now()
    FROM #{p}.bpm_events event
    WHERE event.schema_version IS NOT NULL AND (
      event.integration='memory-api' OR EXISTS (
        SELECT 1 FROM #{p}.bpm_observation_event_migrations mapping WHERE mapping.event_id=event.id))
    ON CONFLICT(host_id,session_id) DO UPDATE
      SET requested_generation=frontier.requested_generation+1,
          requested_revision='legacy-cutover-pending',updated_at=now()
    """)

    repo.query!("""
    INSERT INTO #{p}.styx_jobs(queue,worker,args,max_attempts)
    SELECT 'memory','Backplane.Memory.Workers.ProjectionRepairWorker',
           jsonb_build_object('host_id',frontier.host_id,'session_id',frontier.session_id),5
    FROM #{p}.bpm_projection_repair_frontiers frontier
    WHERE frontier.requested_revision='legacy-cutover-pending'
      AND NOT EXISTS (
        SELECT 1 FROM #{p}.styx_jobs job
        WHERE job.worker='Backplane.Memory.Workers.ProjectionRepairWorker'
          AND job.state IN ('available','scheduled','retryable','executing','suspended')
          AND job.args->>'host_id'=frontier.host_id
          AND job.args->>'session_id'=frontier.session_id)
    """)
  end

  defp invalid_owners_sql(p, table) do
    """
    SELECT count(*) FROM #{p}.#{table} artifact
    WHERE artifact.memory_space_id IS NULL OR nullif(btrim(artifact.host_id),'') IS NULL
      OR nullif(btrim(artifact.session_id),'') IS NULL
      OR nullif(btrim(artifact.scope),'') IS NULL OR nullif(btrim(artifact.namespace),'') IS NULL
      OR NOT EXISTS (
        SELECT 1 FROM #{p}.bpm_memory_space_legacy_aliases alias
        JOIN #{p}.bpm_memory_space_entitlements entitlement
          ON entitlement.memory_space_id=alias.memory_space_id
        WHERE alias.memory_space_id=artifact.memory_space_id
          AND alias.alias_type='host' AND alias.alias_value='host:'||artifact.host_id
          AND entitlement.host_id::text=artifact.host_id
          AND entitlement.scope=artifact.scope AND entitlement.namespace=artifact.namespace)
    """
  end

  defp ambiguous_subjects_sql(p) do
    """
    WITH historical AS (
      SELECT memory_space_id,host_id,'host:'||host_id AS client_id,
             source_client_id,scope,namespace,session_id
      FROM #{p}.bpm_observations
      UNION ALL
      SELECT memory_space_id,host_id,'host:'||host_id AS client_id,
             source_client_id,scope,namespace,session_id
      FROM #{p}.memory_sessions
    ), subjects AS (
      SELECT DISTINCT host_id,session_id FROM historical
    ), inputs AS (
      SELECT * FROM historical
      UNION ALL
      SELECT event.memory_space_id,event.host_id,event.client_id,event.source_client_id,
             event.scope,event.namespace,event.session_id
      FROM #{p}.bpm_events event
      JOIN subjects ON subjects.host_id=event.host_id AND subjects.session_id=event.session_id
      WHERE event.schema_version IS NOT NULL
    )
    SELECT count(*) FROM (
      SELECT host_id,session_id FROM inputs GROUP BY host_id,session_id
      HAVING count(DISTINCT jsonb_build_array(memory_space_id,host_id,client_id,
               source_client_id,scope,namespace)) <> 1
    ) ambiguous
    """
  end

  defp assert_same_owner!(left, right) do
    if Enum.any?(~w(memory_space_id host_id scope namespace session_id), &(left[&1] != right[&1])) do
      raise Ecto.MigrationError,
        message: "Historical observation event crosses its original partition"
    end
  end

  defp observation_type(%{"tool_name" => tool, "is_error" => error?})
       when is_binary(tool) and byte_size(tool) > 0,
       do: if(error?, do: "tool.call.failed", else: "tool.call.completed")

  defp observation_type(_row), do: "observation.recorded"

  defp query_maps(repo, sql, params) do
    result = repo.query!(sql, params)
    Enum.map(result.rows, &Map.new(Enum.zip(result.columns, &1)))
  end

  defp count(repo, sql, params \\ []), do: repo.query!(sql, params).rows |> hd() |> hd()
  defp prefix(nil), do: ~s("public")
  defp prefix(value), do: ~s("#{String.replace(value, "\"", "\"\"")}")

  defp payload_hash(payload) do
    "sha256:" <>
      (:crypto.hash(:sha256, Jason.encode!(canonical_json(payload)))
       |> Base.encode16(case: :lower))
  end

  defp namespaced_key(nil, _partition), do: nil

  defp namespaced_key(key, partition) do
    "memory-api:" <>
      Base.url_encode64(
        Jason.encode!([
          Ecto.UUID.load!(partition.memory_space_id),
          partition.scope,
          partition.namespace,
          partition.host_id,
          key
        ]),
        padding: false
      )
  end

  defp canonical_json(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested} -> {to_string(key), canonical_json(nested)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Jason.OrderedObject.new()
  end

  defp canonical_json(value) when is_list(value), do: Enum.map(value, &canonical_json/1)
  defp canonical_json(value), do: value
end

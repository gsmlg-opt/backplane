defmodule Backplane.Memory.Projections.ProductionReadCutoverTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.Ingest
  alias Backplane.Memory.Observations.{Observation, Session}

  alias Backplane.Memory.Projections.{
    ProjectedObservation,
    ReadModels,
    Rebuild,
    Revision,
    Snapshot,
    Source,
    State
  }

  alias Backplane.Memory.Service

  import Backplane.Memory.IngestFixtures

  test "canonical projections are the bounded production reads and keep host/session subjects distinct" do
    session_id = unique("shared-session")
    project = unique("project")

    ingest_session!("host-a", session_id, project, "Read", "2026-08-04T01:00:00.000Z")
    ingest_session!("host-b", session_id, project, "Bash", "2026-08-04T02:00:00.000Z")

    decoy_session = unique("legacy-decoy")

    repo().insert!(%Session{
      session_id: decoy_session,
      project: project,
      started_at: ~U[2030-01-01 00:00:00.000000Z]
    })

    repo().insert!(%Observation{
      session_id: decoy_session,
      tool_name: "LegacyOnly",
      content: "legacy decoy",
      created_at: ~U[2030-01-01 00:00:00.000000Z]
    })

    assert {:ok, %{sessions: [host_b]}} =
             Service.trusted_call("memory::sessions", %{
               "project" => project,
               "host_id" => "host-b",
               "limit" => 1,
               "offset" => 0
             })

    assert %{
             subject_id: subject_b,
             host_id: "host-b",
             session_id: ^session_id,
             project: ^project,
             observation_count: 3,
             processing_status: "complete",
             processing_version: "session-v1",
             input_revision: input_revision,
             output_revision: output_revision
           } = host_b

    assert subject_b == Source.subject_id!("host-b", session_id)
    assert is_binary(input_revision)
    assert is_binary(output_revision)

    assert {:ok, %{sessions: first_page}} =
             Service.trusted_call("memory::sessions", %{
               "project" => project,
               "limit" => 1,
               "offset" => 0
             })

    assert {:ok, %{sessions: second_page}} =
             Service.trusted_call("memory::sessions", %{
               "project" => project,
               "limit" => 1,
               "offset" => 1
             })

    assert [%{host_id: "host-b"}] = first_page
    assert [%{host_id: "host-a"}] = second_page
    refute Enum.any?(first_page ++ second_page, &(&1.session_id == decoy_session))

    assert {:ok, %{timeline: timeline}} =
             Service.trusted_call("memory::timeline", %{"session_id" => session_id, "limit" => 20})

    assert [
             %{host_id: "host-a", subject_id: subject_a, observations: host_a_observations},
             %{host_id: "host-b", subject_id: ^subject_b, observations: host_b_observations}
           ] = timeline

    assert subject_a == Source.subject_id!("host-a", session_id)
    assert Enum.map(host_a_observations, & &1.tool_name) == [nil, "Read", nil]
    assert Enum.map(host_b_observations, & &1.tool_name) == [nil, "Bash", nil]
    assert Enum.all?(timeline, &(&1.processing_status == "complete"))
    refute inspect(timeline) =~ "legacy decoy"

    assert {:ok, %{top_tools: [%{tool_name: "Read", count: 1}]}} =
             Service.trusted_call("memory::patterns", %{
               "session_id" => session_id,
               "host_id" => "host-a",
               "limit" => 1
             })

    assert {:ok, %{top_tools: all_tools}} =
             Service.trusted_call("memory::patterns", %{"session_id" => session_id, "limit" => 10})

    assert all_tools == [%{tool_name: "Bash", count: 1}, %{tool_name: "Read", count: 1}]
    refute Enum.any?(all_tools, &(&1.tool_name == "LegacyOnly"))
  end

  test "timeline limit and offset are stable and late repair changes the production result" do
    host_id = unique("late-host")
    session_id = unique("late-session")
    project = unique("late-project")

    first = event(host_id, session_id, project, 1, "agent.session.started")
    third = event(host_id, session_id, project, 3, "agent.session.ended")
    ingest!(first)
    ingest!(third)

    assert {:ok, %{states: %{"observations" => %{status: "pending"}}}} =
             Rebuild.session(host_id, session_id)

    assert {:ok, %{timeline: [%{processing_status: "pending", observations: first_page}]}} =
             Service.trusted_call("memory::timeline", %{
               "host_id" => host_id,
               "session_id" => session_id,
               "limit" => 1,
               "offset" => 0
             })

    assert [%{id: first_id}] = first_page
    assert first_id == first["event_id"]

    assert {:ok, %{timeline: [%{observations: second_page}]}} =
             Service.trusted_call("memory::timeline", %{
               "host_id" => host_id,
               "session_id" => session_id,
               "limit" => 1,
               "offset" => 1
             })

    assert [%{id: third_id}] = second_page
    assert third_id == third["event_id"]

    second =
      event(host_id, session_id, project, 2, "agent.tool.completed", %{
        "source" => %{"tool_name" => "Read", "tool_response" => "repaired"}
      })

    ingest!(second)

    assert {:ok, %{states: %{"observations" => %{status: "complete"}}}} =
             Rebuild.session(host_id, session_id)

    assert {:ok,
            %{
              timeline: [
                %{
                  processing_status: "complete",
                  processing_version: "observations-v1",
                  observations: observations
                }
              ]
            }} =
             Service.trusted_call("memory::timeline", %{
               "host_id" => host_id,
               "session_id" => session_id,
               "limit" => 3
             })

    assert Enum.map(observations, & &1.id) ==
             Enum.map([first, second, third], & &1["event_id"])
  end

  test "active sessions resource reads only canonical session projections" do
    host_id = unique("active-host")
    active_session = unique("active-session")
    project = unique("active-project")

    ingest!(event(host_id, active_session, project, 1, "agent.session.started"))
    assert {:ok, _result} = Rebuild.session(host_id, active_session)

    repo().insert!(%Session{
      session_id: unique("legacy-active"),
      project: project,
      started_at: ~U[2030-01-01 00:00:00.000000Z]
    })

    assert {:ok,
            [
              %{
                host_id: ^host_id,
                session_id: ^active_session,
                subject_id: subject_id,
                processing_status: "complete"
              }
            ]} =
             ReadModels.active_sessions(
               host_id: host_id,
               client_id: "host:#{host_id}",
               scope: "project:backplane",
               namespace: "private"
             )

    assert subject_id == Source.subject_id!(host_id, active_session)
  end

  test "session, timeline, and pattern reads enforce the exact canonical partition" do
    host_id = unique("partition-host")
    client_id = unique("partition-client")
    scope = unique("partition-scope")

    private = insert_read_partition!(host_id, client_id, scope, "private", "PrivateTool")
    team = insert_read_partition!(host_id, client_id, scope, "team:alpha", "TeamTool")
    insert_legacy_read_partition!(host_id)

    partition_opts = [host_id: host_id, client_id: client_id, scope: scope, limit: 100]

    assert {:ok, sessions} = ReadModels.sessions(partition_opts)
    assert MapSet.new(Enum.map(sessions, & &1.session_id)) == MapSet.new([private, team])

    assert {:ok, [session]} =
             ReadModels.sessions(
               host_id: host_id,
               client_id: client_id,
               scope: scope,
               namespace: "private"
             )

    assert session.session_id == private

    assert {:ok, timeline} = ReadModels.timeline(partition_opts)
    assert MapSet.new(Enum.map(timeline, & &1.session_id)) == MapSet.new([private, team])

    assert {:ok, [%{session_id: ^team, observations: [%{tool_name: "TeamTool"}]}]} =
             ReadModels.timeline(
               host_id: host_id,
               client_id: client_id,
               scope: scope,
               namespace: "team:alpha"
             )

    assert {:ok, [%{tool_name: "PrivateTool", count: 1}]} =
             ReadModels.patterns(
               host_id: host_id,
               client_id: client_id,
               scope: scope,
               namespace: "private"
             )

    assert {:ok, tools} = ReadModels.patterns(partition_opts)
    assert MapSet.new(Enum.map(tools, & &1.tool_name)) == MapSet.new(["PrivateTool", "TeamTool"])
  end

  test "read model API rejects unbounded and invalid pagination" do
    for opts <- [
          [limit: 0],
          [limit: 101],
          [offset: -1],
          [offset: 10_001],
          [host_id: ""],
          [is_error: "true"],
          [minimum_importance: 1.5],
          [occurred_from: "not-a-time"],
          [occurred_from: "2026-08-05T00:00:00Z", occurred_to: "2026-08-04T00:00:00Z"]
        ] do
      assert {:error, :invalid_options} = ReadModels.sessions(opts)
      assert {:error, :invalid_options} = ReadModels.timeline(opts)
      assert {:error, :invalid_options} = ReadModels.patterns(opts)
    end
  end

  test "session, project, and canonical observation filters run before bounded pagination" do
    host_id = unique("filter-host")
    session_id = unique("filter-session")
    project = unique("filter-project")
    base_time = ~U[2026-08-04 04:00:00.000000Z]

    events = [
      event(host_id, session_id, project, 1, "agent.session.started", %{}, base_time),
      event(
        host_id,
        session_id,
        project,
        2,
        "agent.tool.completed",
        %{
          "source" => %{
            "tool_name" => "Read",
            "tool_response" => "read ok",
            "file_path" => "lib/filter_a.ex"
          }
        },
        DateTime.add(base_time, 1, :second)
      ),
      event(
        host_id,
        session_id,
        project,
        3,
        "agent.tool.failed",
        %{
          "source" => %{
            "tool_name" => "Bash",
            "error" => "failed",
            "file_path" => "lib/filter_b.ex"
          }
        },
        DateTime.add(base_time, 2, :second)
      ),
      event(
        host_id,
        session_id,
        project,
        4,
        "agent.session.ended",
        %{},
        DateTime.add(base_time, 3, :second)
      )
    ]

    Enum.zip(events, [1, 7, 9, 0])
    |> Enum.each(fn {captured, importance} ->
      captured |> Map.put("importance", importance) |> ingest!()
    end)

    assert {:ok, _result} = Rebuild.session(host_id, session_id)

    other_project = unique("other-project")
    ingest_session!("other-host", session_id, other_project, "Other", "2026-08-04T05:00:00.000Z")

    repo().insert!(%Observation{
      session_id: session_id,
      tool_name: "LegacyOnly",
      content: "legacy filtered decoy",
      created_at: ~U[2026-08-04 04:00:01.000000Z]
    })

    assert {:ok, %{sessions: [session]}} =
             Service.trusted_call("memory::sessions", %{
               "session_id" => session_id,
               "project" => project,
               "host_id" => host_id,
               "limit" => 1
             })

    assert session.host_id == host_id
    assert session.agent_id == "agent-1"

    assert [read] =
             timeline_observations(%{
               "project" => project,
               "host_id" => host_id,
               "session_id" => session_id,
               "tool_name" => "Read",
               "limit" => 1
             })

    assert read.source_sequence == 2
    assert read.importance == 7

    assert [failed] =
             timeline_observations(%{
               "project" => project,
               "host_id" => host_id,
               "session_id" => session_id,
               "event_type" => "agent.tool.failed",
               "minimum_importance" => 8,
               "is_error" => true,
               "file_path" => "lib/filter_b.ex",
               "limit" => 1
             })

    assert failed.source_sequence == 3
    assert failed.importance == 9
    assert failed.is_error

    assert [second, third] =
             timeline_observations(%{
               "project" => project,
               "host_id" => host_id,
               "session_id" => session_id,
               "occurred_from" => DateTime.to_iso8601(DateTime.add(base_time, 1, :second)),
               "occurred_to" => DateTime.to_iso8601(DateTime.add(base_time, 2, :second)),
               "limit" => 2
             })

    assert {second.source_sequence, third.source_sequence} == {2, 3}

    assert {:ok, %{top_tools: tools}} =
             Service.trusted_call("memory::patterns", %{
               "project" => project,
               "session_id" => session_id,
               "limit" => 10
             })

    assert tools == [%{tool_name: "Bash", count: 1}, %{tool_name: "Read", count: 1}]
  end

  test "read responses distinguish a failed newer state revision from its retained snapshot" do
    host_id = unique("failed-host")
    session_id = unique("failed-session")
    project = unique("failed-project")

    ingest!(event(host_id, session_id, project, 1, "agent.session.started"))
    assert {:ok, first} = Rebuild.session(host_id, session_id)
    old_snapshot_revision = first.output_revisions["session"]

    ingest!(event(host_id, session_id, project, 2, "agent.session.ended"))
    assert {:ok, current_events} = Source.events(host_id, session_id)
    newer_input_revision = Revision.input_revision(current_events)

    assert :ok =
             Rebuild.record_failed(
               host_id,
               session_id,
               first.subject_id,
               newer_input_revision,
               RuntimeError.exception("new projection failed")
             )

    assert {:ok, %{sessions: [session]}} =
             Service.trusted_call("memory::sessions", %{
               "host_id" => host_id,
               "session_id" => session_id
             })

    assert session.processing_status == "failed"
    assert session.stale
    assert session.input_revision == newer_input_revision
    assert session.output_revision == nil
    assert session.snapshot_input_revision == first.input_revision
    assert session.snapshot_output_revision == old_snapshot_revision
    assert session.last_error == "new projection failed"

    assert {:ok, %{timeline: [%{observations: [_], stale: true} = timeline]}} =
             Service.trusted_call("memory::timeline", %{
               "host_id" => host_id,
               "session_id" => session_id
             })

    assert timeline.input_revision == newer_input_revision
    assert timeline.output_revision == nil
    assert timeline.snapshot_input_revision == first.input_revision
    assert is_binary(timeline.snapshot_output_revision)

    assert {:ok, %{top_tools: []}} =
             Service.trusted_call("memory::patterns", %{
               "host_id" => host_id,
               "session_id" => session_id
             })
  end

  test "patterns aggregate only a bounded recent candidate set and plans use row indexes" do
    host_id = unique("bounded-host")
    session_id = unique("bounded-session")
    subject_id = Source.subject_id!(host_id, session_id)
    input_revision = "input-#{subject_id}"
    output_revision = "output-#{subject_id}"

    repo().insert!(%State{
      projector: "observations",
      subject_type: "captured_session",
      subject_id: subject_id,
      processing_version: "observations-v1",
      input_revision: input_revision,
      output_revision: output_revision,
      status: "complete",
      attempt_count: 1
    })

    repo().insert!(%Snapshot{
      projector: "observations",
      subject_type: "captured_session",
      subject_id: subject_id,
      input_revision: input_revision,
      output_revision: output_revision,
      read_model: %{
        "host_id" => host_id,
        "client_id" => "host:#{host_id}",
        "scope" => "bounded-project",
        "namespace" => "private"
      }
    })

    base = ~U[2026-08-04 00:00:00.000000Z]
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    rows =
      Enum.map(1..10_005, fn sequence ->
        %{
          event_id: Ecto.UUID.generate(),
          subject_id: subject_id,
          host_id: host_id,
          client_id: "host:#{host_id}",
          scope: "bounded-project",
          namespace: "private",
          session_id: session_id,
          project: if(sequence <= 5, do: "legacy-mixed-project", else: "bounded-project"),
          source_sequence: sequence,
          event_type: "agent.tool.completed",
          occurred_at: DateTime.add(base, sequence, :microsecond),
          tool_name: if(sequence <= 5, do: "Old", else: "Recent"),
          importance: 0,
          is_error: false,
          file_paths: [],
          processing_version: "observations-v1",
          input_revision: input_revision,
          inserted_at: now,
          updated_at: now
        }
      end)

    rows
    |> Enum.chunk_every(1_000)
    |> Enum.each(&repo().insert_all(ProjectedObservation, &1))

    assert {:ok, [%{tool_name: "Recent", count: 10_000}]} =
             ReadModels.patterns(host_id: host_id, session_id: session_id, limit: 10)

    assert {:ok, [%{observations: legacy_rows}]} =
             ReadModels.timeline(
               host_id: host_id,
               session_id: session_id,
               project: "legacy-mixed-project",
               limit: 10
             )

    assert length(legacy_rows) == 5
    assert Enum.all?(legacy_rows, &(&1.tool_name == "Old"))

    assert {:ok, [%{observations: [%{tool_name: "Recent"}]}]} =
             ReadModels.timeline(
               host_id: host_id,
               session_id: session_id,
               project: "bounded-project",
               limit: 1
             )

    repo().query!("SET LOCAL enable_seqscan = off")

    {timeline_sql, timeline_params} =
      capture_sql(fn ->
        ReadModels.timeline(host_id: host_id, session_id: session_id, limit: 50)
      end)

    {pattern_sql, pattern_params} =
      capture_sql(fn ->
        ReadModels.patterns(host_id: host_id, session_id: session_id, limit: 10)
      end)

    timeline_plan = explain(timeline_sql, timeline_params)
    pattern_plan = explain(pattern_sql, pattern_params)

    assert timeline_sql =~ ~s(FROM "bpm_projected_observations")
    assert pattern_sql =~ ~s(FROM "bpm_projected_observations")
    assert pattern_sql =~ "LIMIT $"
    assert timeline_plan =~ "bpm_projected_observations_host_session_time_idx"
    assert pattern_plan =~ "bpm_projected_observations_host_session_time_idx"
    assert pattern_plan =~ "Limit"
    refute timeline_plan =~ "Function Scan"
    refute pattern_plan =~ "Function Scan"
    refute timeline_plan =~ "jsonb_array_elements"
    refute pattern_plan =~ "jsonb_array_elements"
  end

  test "offset accepts its documented boundary and rejects the next value" do
    assert {:ok, []} = ReadModels.sessions(offset: 10_000)
    assert {:ok, []} = ReadModels.timeline(offset: 10_000)
    assert {:ok, []} = ReadModels.patterns(offset: 10_000)

    assert {:error, :invalid_options} = ReadModels.sessions(offset: 10_001)
    assert {:error, :invalid_options} = ReadModels.timeline(offset: 10_001)
    assert {:error, :invalid_options} = ReadModels.patterns(offset: 10_001)
  end

  test "minimum importance is bounded to the stored int32 domain" do
    assert {:ok, []} = ReadModels.timeline(minimum_importance: -2_147_483_648)
    assert {:ok, []} = ReadModels.timeline(minimum_importance: 2_147_483_647)

    assert {:error, :invalid_options} =
             ReadModels.timeline(minimum_importance: -2_147_483_649)

    assert {:error, :invalid_options} =
             ReadModels.timeline(minimum_importance: 2_147_483_648)

    assert {:error, :invalid_options} = ReadModels.timeline(minimum_importance: 10 ** 100)
  end

  defp ingest_session!(host_id, session_id, project, tool_name, started_at) do
    {:ok, started, _offset} = DateTime.from_iso8601(started_at)

    [
      event(host_id, session_id, project, 1, "agent.session.started", %{}, started),
      event(
        host_id,
        session_id,
        project,
        2,
        "agent.tool.completed",
        %{"source" => %{"tool_name" => tool_name, "tool_response" => "ok"}},
        DateTime.add(started, 1, :second)
      ),
      event(
        host_id,
        session_id,
        project,
        3,
        "agent.session.ended",
        %{},
        DateTime.add(started, 2, :second)
      )
    ]
    |> Enum.each(&ingest!/1)

    assert {:ok, _result} = Rebuild.session(host_id, session_id)
  end

  defp event(host_id, session_id, project, sequence, event_type, payload \\ %{}, time \\ nil) do
    occurred_at = time || DateTime.add(~U[2026-08-04 01:00:00.000000Z], sequence, :second)

    valid_event(%{
      "event_id" => Ecto.UUID.generate(),
      "host_id" => host_id,
      "session_id" => session_id,
      "project" => project,
      "sequence" => sequence,
      "event_type" => event_type,
      "occurred_at" => DateTime.to_iso8601(occurred_at),
      "captured_at" => DateTime.to_iso8601(occurred_at),
      "idempotency_key" => "#{host_id}:#{session_id}:#{sequence}:#{event_type}",
      "payload" => payload,
      "payload_hash" => Backplane.Memory.Ingest.EventValidator.payload_hash(payload)
    })
  end

  defp ingest!(event) do
    auth = %{
      host_id: event["host_id"],
      auth_token_id: "token-#{event["host_id"]}",
      scopes: ["host_agent.capture"]
    }

    assert {:ok, %{"results" => [%{"status" => "accepted"}]}} =
             Ingest.ingest_batch(auth, %{
               "batch_id" => Ecto.UUID.generate(),
               "host_id" => event["host_id"],
               "events" => [event]
             })
  end

  defp timeline_observations(args) do
    assert {:ok, %{timeline: timeline}} = Service.trusted_call("memory::timeline", args)
    Enum.flat_map(timeline, & &1.observations)
  end

  defp insert_read_partition!(host_id, client_id, scope, namespace, tool_name) do
    session_id = unique("partition-session")
    subject_id = Source.subject_id!(host_id, session_id)
    input_revision = unique("partition-input")
    output_revision = unique("partition-output")

    partition = %{
      "host_id" => host_id,
      "client_id" => client_id,
      "scope" => scope,
      "namespace" => namespace,
      "session_id" => session_id,
      "project" => scope
    }

    insert_projection_pair!(
      "session",
      subject_id,
      input_revision,
      output_revision,
      Map.merge(partition, %{
        "status" => "active",
        "counts" => %{"events" => 1}
      })
    )

    insert_projection_pair!(
      "observations",
      subject_id,
      input_revision,
      output_revision,
      partition
    )

    repo().insert!(%ProjectedObservation{
      event_id: Ecto.UUID.generate(),
      subject_id: subject_id,
      host_id: host_id,
      client_id: client_id,
      scope: scope,
      namespace: namespace,
      session_id: session_id,
      project: scope,
      event_type: "agent.tool.completed",
      occurred_at: DateTime.utc_now(),
      tool_name: tool_name,
      importance: 0,
      is_error: false,
      file_paths: [],
      processing_version: "observations-v1",
      input_revision: input_revision
    })

    session_id
  end

  defp insert_legacy_read_partition!(host_id) do
    session_id = unique("legacy-partition-session")
    subject_id = Source.subject_id!(host_id, session_id)
    input_revision = unique("legacy-partition-input")
    output_revision = unique("legacy-partition-output")
    read_model = %{"host_id" => host_id, "session_id" => session_id, "status" => "active"}

    insert_projection_pair!("session", subject_id, input_revision, output_revision, read_model)

    insert_projection_pair!(
      "observations",
      subject_id,
      input_revision,
      output_revision,
      read_model
    )

    repo().insert!(%ProjectedObservation{
      event_id: Ecto.UUID.generate(),
      subject_id: subject_id,
      host_id: host_id,
      session_id: session_id,
      event_type: "agent.tool.completed",
      occurred_at: DateTime.utc_now(),
      tool_name: "LegacyTool",
      importance: 0,
      is_error: false,
      file_paths: [],
      processing_version: "observations-v1",
      input_revision: input_revision
    })
  end

  defp insert_projection_pair!(projector, subject_id, input_revision, output_revision, read_model) do
    repo().insert!(%State{
      projector: projector,
      subject_type: "captured_session",
      subject_id: subject_id,
      processing_version: "#{projector}-v1",
      input_revision: input_revision,
      output_revision: output_revision,
      status: "complete",
      attempt_count: 1
    })

    repo().insert!(%Snapshot{
      projector: projector,
      subject_type: "captured_session",
      subject_id: subject_id,
      input_revision: input_revision,
      output_revision: output_revision,
      read_model: read_model
    })
  end

  defp explain(sql, params) do
    repo().query!("EXPLAIN " <> sql, params).rows
    |> Enum.map_join("\n", &hd/1)
  end

  defp capture_sql(fun) do
    handler_id = "production-read-plan-#{System.unique_integer([:positive])}"
    event = (repo().config()[:telemetry_prefix] || [:backplane, :repo]) ++ [:query]
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        event,
        fn _event, _measurements, metadata, pid ->
          send(pid, {:production_read_sql, metadata.query, metadata.params})
        end,
        parent
      )

    try do
      fun.()
      assert_receive {:production_read_sql, sql, params}
      {sql, params}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end

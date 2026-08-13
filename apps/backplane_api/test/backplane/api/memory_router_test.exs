defmodule Backplane.Api.MemoryRouterTest do
  use Backplane.Api.ConnCase, async: false

  import Ecto.Query

  alias Backplane.Memory.Events.{Event, Store, Stream}
  alias Backplane.Memory.Graph
  alias Backplane.Memory.Profiles.Profile
  alias Backplane.Memory.Coordination.Lease
  alias Backplane.Memory.Observations.{Observation, Session}
  alias Backplane.Memory.Recall.QueryPlan
  alias Backplane.Memory.Recall.Store, as: RecallStore
  alias Backplane.Skills.Host

  defmodule QueryLLM do
    def expand_query(query), do: {:ok, [query, query <> " expanded"]}
  end

  @settings_table :backplane_settings
  @settings_keys [
    "memory.pipeline.enabled",
    "memory.events.enabled",
    "memory.events.dual_write",
    "memory.inject_context",
    "memory.replay_enabled",
    "memory.replay_import_enabled",
    "memory.tools"
  ]

  setup do
    snapshot =
      Map.new(@settings_keys, fn key ->
        {key, :ets.lookup(@settings_table, key)}
      end)

    llm_module = Application.fetch_env(:backplane_memory, :llm_module)

    :ets.insert(@settings_table, {"memory.pipeline.enabled", true})
    :ets.insert(@settings_table, {"memory.events.enabled", true})
    :ets.insert(@settings_table, {"memory.events.dual_write", true})
    :ets.insert(@settings_table, {"memory.inject_context", false})
    :ets.insert(@settings_table, {"memory.replay_enabled", true})
    :ets.insert(@settings_table, {"memory.replay_import_enabled", false})
    :ets.insert(@settings_table, {"memory.tools", "all"})
    Application.put_env(:backplane_memory, :llm_module, QueryLLM)

    host =
      repo().insert!(
        Host.changeset(%Host{}, %{
          name: "memory-router-#{System.unique_integer([:positive])}",
          memory_scope: "scope:memory-router"
        })
      )

    on_exit(fn ->
      Enum.each(snapshot, fn {key, rows} ->
        :ets.delete(@settings_table, key)
        if rows != [], do: :ets.insert(@settings_table, rows)
      end)

      case llm_module do
        {:ok, module} -> Application.put_env(:backplane_memory, :llm_module, module)
        :error -> Application.delete_env(:backplane_memory, :llm_module)
      end
    end)

    %{host: host}
  end

  test "observation endpoint passes only the additive event whitelist", %{conn: conn, host: host} do
    causation_id = Ecto.UUID.generate()
    forbidden_id = Ecto.UUID.generate()

    observation_conn =
      post(conn, "/api/memory/observations", %{
        "session_id" => "http-explicit-event",
        "content" => "explicit event",
        "tool_name" => "Bash",
        "is_error" => true,
        "event_type" => "task.created",
        "payload" => %{"input" => %{"value" => 1}},
        "stream_id" => "http-explicit-stream",
        "project" => "explicit-project",
        "agent_id" => "explicit-agent",
        "host_id" => host.id,
        "client_id" => "host:#{host.id}",
        "run_id" => "explicit-run",
        "correlation_id" => "explicit-correlation",
        "causation_id" => causation_id,
        "occurred_at" => "2026-07-16T04:00:00.000000Z",
        "idempotency_key" => "http-explicit-key",
        "id" => forbidden_id,
        "namespace" => "private",
        "importance" => 100,
        "actor_type" => "user",
        "role" => "user",
        "status" => "forged",
        "unknown_option" => "ignored"
      })

    assert %{"id" => observation_id} = body = json_response(observation_conn, 201)
    assert Map.keys(body) == ["id"]

    event = repo().get_by!(Event, idempotency_key: "http-explicit-key")

    assert event.id != forbidden_id
    assert event.stream_id == "http-explicit-stream"
    assert event.session_id == "http-explicit-event"
    assert event.project == "explicit-project"
    assert event.agent_id == "explicit-agent"
    assert event.host_id == host.id
    assert event.client_id == "host:#{host.id}"
    assert event.scope == host.memory_scope
    assert event.run_id == "explicit-run"
    assert event.event_type == "task.created"
    assert event.tool_name == "Bash"
    assert event.correlation_id == "explicit-correlation"
    assert event.causation_id == causation_id
    assert event.occurred_at == ~U[2026-07-16 04:00:00.000000Z]
    assert event.namespace == "private"
    assert event.importance == 0
    assert event.actor_type == "system"
    assert event.role == "system"
    assert event.status == "error"
    assert event.payload["input"] == %{"value" => 1}
    assert event.payload["_backplane"]["legacy_observation_id"] == observation_id
  end

  test "REST rejects caller-supplied cross-partition ownership", %{conn: conn} do
    conn =
      post(conn, "/api/memory/observations", %{
        "session_id" => "spoofed-rest-owner",
        "content" => "must not persist",
        "host_id" => Ecto.UUID.generate(),
        "namespace" => "team"
      })

    assert json_response(conn, 403) == %{"error" => "Forbidden"}
    refute repo().get_by(Event, session_id: "spoofed-rest-owner")
  end

  test "activity and replay REST routes use the same exact-partition service results", %{
    conn: conn,
    host: host
  } do
    partition = %{
      host_id: host.id,
      client_id: "host:#{host.id}",
      scope: host.memory_scope,
      namespace: "private"
    }

    session = "rest-replay-#{System.unique_integer([:positive])}"

    assert {:ok, {:inserted, _}} =
             Store.append_tagged(%{
               id: Ecto.UUID.generate(),
               stream_id: "capture:#{host.id}:#{session}",
               host_id: host.id,
               client_id: partition.client_id,
               scope: partition.scope,
               namespace: partition.namespace,
               session_id: session,
               sequence: 1,
               source_sequence: 1,
               event_type: "agent.session.started",
               occurred_at: ~U[2026-08-12 00:00:01.000000Z],
               idempotency_key: "#{session}:1",
               payload: %{},
               payload_hash: "sha256:#{session}:1",
               schema_version: 1
             })

    assert {:ok, {:inserted, _}} =
             Store.append_tagged(%{
               id: Ecto.UUID.generate(),
               stream_id: "capture:#{host.id}:#{session}",
               host_id: host.id,
               client_id: partition.client_id,
               scope: partition.scope,
               namespace: partition.namespace,
               session_id: session,
               sequence: 2,
               source_sequence: 2,
               event_type: "conversation.agent_message",
               occurred_at: ~U[2026-08-12 00:00:02.000000Z],
               idempotency_key: "#{session}:2",
               payload: %{},
               payload_hash: "sha256:#{session}:2",
               schema_version: 1
             })

    assert {:ok, _} = Backplane.Memory.Projections.Rebuild.session(host.id, session)

    assert %{
             "session_id" => ^session,
             "host_id" => host_id,
             "observation_count" => 2,
             "event_type_breakdown" => %{
               "agent.session.started" => 1,
               "conversation.agent_message" => 1
             },
             "processing" => processing,
             "links" => links
           } =
             conn
             |> get("/api/memory/sessions/#{session}")
             |> json_response(200)

    assert host_id == host.id

    assert Map.keys(processing) |> Enum.sort() ==
             ~w(crystal embeddings graph lessons profile summary)

    assert Map.keys(links) |> Enum.sort() == ~w(actions crystals lessons memories)

    assert %{"sessions" => [%{"session_id" => ^session}]} =
             conn
             |> get("/api/memory/replay/sessions")
             |> json_response(200)

    assert %{"events" => [%{"kind" => "session_boundary"}, _]} =
             conn
             |> recycle()
             |> get("/api/memory/replay/sessions/#{session}")
             |> json_response(200)

    assert %{"events" => [_], "next_cursor" => next_cursor} =
             conn
             |> recycle()
             |> get("/api/memory/replay/sessions/#{session}?limit=1")
             |> json_response(200)

    assert is_binary(next_cursor)

    assert %{"summary" => %{"event_count" => count}} =
             conn
             |> recycle()
             |> get("/api/memory/activity/summary")
             |> json_response(200)

    assert count >= 1
  end

  test "replay REST pagination normalizes integers and rejects unknown query fields", %{
    conn: conn
  } do
    assert %{"limit" => 1, "sessions" => sessions} =
             conn
             |> get("/api/memory/replay/sessions?limit=1&offset=0")
             |> json_response(200)

    assert length(sessions) <= 1

    assert %{"error" => "invalid_arguments"} =
             conn
             |> recycle()
             |> get("/api/memory/replay/sessions?unknown=true")
             |> json_response(400)
  end

  test "Recall Inspector trace REST parity is exact-partition and strict", %{
    conn: conn,
    host: host
  } do
    assert {:ok, plan} =
             QueryPlan.new(%{
               query: "explain the selected recall",
               host_id: host.id,
               client_id: "host:#{host.id}",
               scope: host.memory_scope,
               namespace: "private"
             })

    assert {:ok, run} =
             RecallStore.create(plan,
               request_id: Ecto.UUID.generate(),
               correlation_id: Ecto.UUID.generate()
             )

    assert %{"run" => %{"id" => run_id}, "candidates" => []} =
             conn
             |> get("/api/memory/recall/#{run.id}/trace")
             |> json_response(200)

    assert run_id == run.id

    assert %{"error" => "invalid_arguments"} =
             conn
             |> recycle()
             |> get("/api/memory/recall/#{run.id}/trace?unknown=true")
             |> json_response(400)
  end

  test "session handoff REST parity reads the dynamic data-backed resource", %{
    conn: conn,
    host: host
  } do
    session_id = "rest-handoff-#{System.unique_integer([:positive])}"

    assert {:ok, {:inserted, _}} =
             Store.append_tagged(%{
               id: Ecto.UUID.generate(),
               stream_id: "capture:#{host.id}:#{session_id}",
               host_id: host.id,
               client_id: "host:#{host.id}",
               scope: host.memory_scope,
               namespace: "private",
               project: "backplane",
               session_id: session_id,
               sequence: 1,
               source_sequence: 1,
               event_type: "agent.session.started",
               occurred_at: ~U[2026-08-12 00:00:01.000000Z],
               idempotency_key: "#{session_id}:1",
               payload: %{},
               payload_hash: "sha256:#{session_id}:1",
               schema_version: 1
             })

    assert %{"uri" => uri, "handoff" => handoff} =
             conn
             |> get("/api/memory/sessions/#{session_id}/handoff")
             |> json_response(200)

    assert uri == "memory://session/#{session_id}/handoff"
    assert inspect(handoff) =~ session_id

    assert %{"error" => "invalid_arguments"} =
             conn
             |> recycle()
             |> get("/api/memory/sessions/#{session_id}/handoff?unknown=true")
             |> json_response(400)
  end

  test "observation endpoint preserves absent payload versus explicit null", %{conn: conn} do
    absent =
      post(conn, "/api/memory/observations", %{
        "session_id" => "http-payload-absent",
        "content" => "updated lib/absent.ex",
        "idempotency_key" => "http-payload-absent"
      })

    assert %{"id" => _} = json_response(absent, 201)

    explicit_null =
      post(recycle(conn), "/api/memory/observations", %{
        "session_id" => "http-payload-null",
        "content" => "updated lib/null.ex",
        "payload" => nil,
        "idempotency_key" => "http-payload-null"
      })

    assert json_response(explicit_null, 422) == %{"error" => ":invalid_payload"}

    absent_event = repo().get_by!(Event, idempotency_key: "http-payload-absent")

    assert absent_event.payload["paths"] == ["lib/absent.ex"]
    refute repo().get_by(Event, idempotency_key: "http-payload-null")
  end

  test "invalid event keeps the existing 422 inspect response", %{conn: conn} do
    conn =
      post(conn, "/api/memory/observations", %{
        "session_id" => "http-invalid-event",
        "content" => "invalid event",
        "event_type" => "not.accepted"
      })

    assert json_response(conn, 422) == %{"error" => ":invalid_event_type"}
    refute repo().exists?(from(o in Observation, where: o.session_id == "http-invalid-event"))
  end

  test "session start persistence conflict returns retryable 503 without a session", %{conn: conn} do
    session_id = "http-start-conflict"

    assert {:ok, _event} =
             Store.append(
               %{
                 stream_id: "other-start-stream",
                 event_type: "session.started",
                 idempotency_key: "session.started:" <> session_id
               },
               telemetry: false
             )

    response =
      post(conn, "/api/memory/session/start", %{
        "session_id" => session_id,
        "project" => "backplane"
      })

    assert json_response(response, 503) == %{"error" => "memory persistence unavailable"}
    refute repo().get(Session, session_id)
  end

  test "session end persistence conflict returns retryable 503 and rolls back", %{conn: conn} do
    session_id = "http-end-conflict"

    assert conn
           |> post("/api/memory/session/start", %{
             "session_id" => session_id,
             "project" => "backplane"
           })
           |> json_response(200) == %{"session_id" => session_id}

    assert {:ok, _event} =
             Store.append(
               %{
                 stream_id: "other-end-stream",
                 event_type: "session.ended",
                 idempotency_key: "session.ended:" <> session_id
               },
               telemetry: false
             )

    response =
      Oban.Testing.with_testing_mode(:manual, fn ->
        post(conn, "/api/memory/session/end", %{"session_id" => session_id})
      end)

    assert json_response(response, 503) == %{"error" => "memory persistence unavailable"}
    assert repo().get!(Session, session_id).ended_at == nil
    assert repo().get!(Stream, "session:" <> session_id).closed_at == nil
  end

  test "repeat session end is idempotent and unknown sessions are hidden", %{conn: conn} do
    session_id = "http-repeat-end"

    assert conn
           |> post("/api/memory/session/start", %{
             "session_id" => session_id,
             "project" => "backplane"
           })
           |> json_response(200) == %{"session_id" => session_id}

    {first, repeat, unknown} =
      Oban.Testing.with_testing_mode(:manual, fn ->
        first = post(conn, "/api/memory/session/end", %{"session_id" => session_id})
        repeat = post(recycle(conn), "/api/memory/session/end", %{"session_id" => session_id})
        unknown = post(recycle(conn), "/api/memory/session/end", %{"session_id" => "unknown"})
        {first, repeat, unknown}
      end)

    assert json_response(first, 200) == %{"session_id" => session_id, "status" => "ended"}
    assert json_response(repeat, 200) == %{"session_id" => session_id, "status" => "ended"}
    assert json_response(unknown, 404) == %{"error" => "session not found"}
  end

  test "activated read and maintenance routes preserve their response bodies", %{
    conn: conn,
    host: host
  } do
    partition = %{
      host_id: host.id,
      client_id: "host:#{host.id}",
      scope: host.memory_scope,
      namespace: "private"
    }

    {:ok, source} = Graph.upsert_node(%{type: "Module", name: "Source"}, partition)
    {:ok, target} = Graph.upsert_node(%{type: "File", name: "lib/target.ex"}, partition)

    {:ok, _edge} =
      Graph.insert_edge(
        %{source_id: source.id, target_id: target.id, relation: "uses"},
        partition
      )

    updated_at = ~U[2026-07-16 05:00:00.000000Z]

    %Profile{}
    |> Profile.changeset(%{
      project: "backplane",
      top_concepts: %{"events" => 3},
      top_files: %{"lib/router.ex" => 2},
      patterns: %{"testing" => 1},
      session_count: 4,
      total_observations: 9,
      updated_at: updated_at,
      host_id: partition.host_id,
      client_id: partition.client_id,
      scope: partition.scope,
      namespace: partition.namespace
    })
    |> repo().insert!()

    assert {:ok, file_observation} =
             Backplane.Memory.Observations.record(
               "file-history-session",
               "updated lib/router.ex",
               Map.to_list(partition) ++ [trusted_partition: partition]
             )

    audit_id = "11111111-2222-4333-8444-555555555555"
    created_at = ~U[2026-07-16 05:30:00.000000Z]

    {1, nil} =
      repo().insert_all("memory_audit_log", [
        %{
          id: Ecto.UUID.dump!(audit_id),
          operation: "forget",
          actor: "tester",
          target_ids: %{"ids" => ["memory-1"]},
          metadata:
            Map.merge(
              %{"reason" => "test"},
              Map.new(partition, fn {k, v} -> {to_string(k), v} end)
            ),
          created_at: created_at
        }
      ])

    %Lease{}
    |> Lease.changeset(%{
      action_id: Ecto.UUID.generate(),
      holder_agent_id: "expired-agent",
      acquired_at: DateTime.add(created_at, -120, :second),
      expires_at: DateTime.add(DateTime.utc_now(), -60, :second),
      host_id: partition.host_id,
      client_id: partition.client_id,
      scope: partition.scope,
      namespace: partition.namespace
    })
    |> repo().insert!()

    assert get(conn, "/api/memory/graph/stats") |> json_response(200) == %{
             "node_count_by_type" => %{"File" => 1, "Module" => 1},
             "edge_count_by_relation" => %{"uses" => 1},
             "relation_count_by_domain" => %{
               "knowledge" => 0,
               "lifecycle" => 0,
               "provenance" => 0
             }
           }

    assert get(recycle(conn), "/api/memory/profile?project=backplane") |> json_response(200) == %{
             "project" => "backplane",
             "top_concepts" => %{"events" => 3},
             "top_files" => %{"lib/router.ex" => 2},
             "patterns" => %{"testing" => 1},
             "session_count" => 4,
             "total_observations" => 9,
             "updated_at" => DateTime.to_iso8601(updated_at)
           }

    assert post(recycle(conn), "/api/memory/query/expand", %{"query" => "event store"})
           |> json_response(200) == %{
             "query" => "event store",
             "expansions" => ["event store", "event store expanded"]
           }

    file_body =
      get(recycle(conn), "/api/memory/file-history?files=lib/router.ex")
      |> json_response(200)

    assert %{
             "results" => [
               %{
                 "id" => file_id,
                 "session_id" => "file-history-session",
                 "tool_name" => nil,
                 "content" => "updated lib/router.ex",
                 "created_at" => created_at_string
               }
             ]
           } = file_body

    assert file_id == file_observation.id
    assert {:ok, _datetime, 0} = DateTime.from_iso8601(created_at_string)

    assert get(recycle(conn), "/api/memory/audit") |> json_response(200) == %{
             "results" => [
               %{
                 "id" => audit_id,
                 "operation" => "forget",
                 "actor" => "tester",
                 "target_ids" => %{"ids" => ["memory-1"]},
                 "metadata" => %{
                   "reason" => "test",
                   "host_id" => host.id,
                   "client_id" => "host:#{host.id}",
                   "scope" => host.memory_scope,
                   "namespace" => "private"
                 },
                 "created_at" => created_at |> DateTime.to_naive() |> NaiveDateTime.to_iso8601()
               }
             ]
           }

    assert get(recycle(conn), "/api/memory/diagnose") |> json_response(200) == %{
             "status" => "ok",
             "circuit_breaker" => "closed",
             "memory_stats" => [],
             "active_leases" => 1,
             "processing" => %{
               "bounded" => true,
               "content_exposed" => false,
               "lesson_candidates" => 0,
               "projections" => %{},
               "relation_candidates" => 0,
               "unembedded_memories" => 0
             }
           }

    assert post(recycle(conn), "/api/memory/heal", %{}) |> json_response(200) == %{
             "status" => "healed",
             "expired_leases_cleared" => 1,
             "circuit_breaker" => "closed"
           }
  end

  test "memory unknown paths use JSON 404 while unrelated paths keep the public catch-all", %{
    conn: conn
  } do
    assert get(conn, "/api/memory/not-a-route") |> json_response(404) == %{
             "error" => "not found"
           }

    assert get(recycle(conn), "/not-a-route") |> response(404) == "not found"
  end

  test "public endpoint persists an ordered session lifecycle", %{conn: conn} do
    session_id = "http-lifecycle"

    assert conn
           |> post("/api/memory/session/start", %{
             "session_id" => session_id,
             "project" => "backplane"
           })
           |> json_response(200) == %{"session_id" => session_id}

    observation_conn =
      post(recycle(conn), "/api/memory/observations", %{
        "session_id" => session_id,
        "content" => "updated lib/router.ex",
        "tool_name" => "Bash"
      })

    assert %{"id" => observation_id} = json_response(observation_conn, 201)
    assert {:ok, _uuid} = Ecto.UUID.cast(observation_id)

    end_conn =
      Oban.Testing.with_testing_mode(:manual, fn ->
        post(recycle(conn), "/api/memory/session/end", %{"session_id" => session_id})
      end)

    assert json_response(end_conn, 200) == %{
             "session_id" => session_id,
             "status" => "ended"
           }

    assert %Session{project: "backplane", ended_at: %DateTime{}} =
             repo().get!(Session, session_id)

    assert %Observation{id: ^observation_id, content: "updated lib/router.ex"} =
             repo().get!(Observation, observation_id)

    events =
      repo().all(
        from(e in Event,
          where: e.session_id == ^session_id,
          order_by: e.sequence
        )
      )

    assert Enum.map(events, &{&1.sequence, &1.event_type}) == [
             {1, "session.started"},
             {2, "tool.call.completed"},
             {3, "session.ended"}
           ]

    assert Enum.at(events, 1).payload["_backplane"]["legacy_observation_id"] ==
             observation_id

    assert %Stream{closed_at: %DateTime{}, next_sequence: 4} =
             repo().get!(Stream, "session:" <> session_id)
  end

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)
end

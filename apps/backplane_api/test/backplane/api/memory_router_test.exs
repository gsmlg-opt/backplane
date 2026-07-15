defmodule Backplane.Api.MemoryRouterTest do
  use Backplane.Api.ConnCase, async: false

  import Ecto.Query

  alias Backplane.Memory.Events.{Event, Store, Stream}
  alias Backplane.Memory.Graph
  alias Backplane.Memory.Profiles.Profile
  alias Backplane.Memory.Coordination.Lease
  alias Backplane.Memory.Observations.{Observation, Session}

  defmodule QueryLLM do
    def expand_query(query), do: {:ok, [query, query <> " expanded"]}
  end

  @settings_table :backplane_settings
  @settings_keys [
    "memory.pipeline.enabled",
    "memory.events.enabled",
    "memory.events.dual_write",
    "memory.inject_context"
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
    Application.put_env(:backplane_memory, :llm_module, QueryLLM)

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

    :ok
  end

  test "observation endpoint passes only the additive event whitelist", %{conn: conn} do
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
        "host_id" => "explicit-host",
        "client_id" => "explicit-client",
        "run_id" => "explicit-run",
        "correlation_id" => "explicit-correlation",
        "causation_id" => causation_id,
        "occurred_at" => "2026-07-16T04:00:00.000000Z",
        "idempotency_key" => "http-explicit-key",
        "id" => forbidden_id,
        "namespace" => "public",
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
    assert event.host_id == "explicit-host"
    assert event.client_id == "explicit-client"
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

    assert {:ok, _session} =
             Backplane.Memory.Observations.register_session(session_id, "backplane")

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

  test "repeat and unknown session ends preserve the existing 200 body", %{conn: conn} do
    session_id = "http-repeat-end"

    assert {:ok, _session} =
             Backplane.Memory.Observations.register_session(session_id, "backplane")

    responses =
      Oban.Testing.with_testing_mode(:manual, fn ->
        first = post(conn, "/api/memory/session/end", %{"session_id" => session_id})
        repeat = post(recycle(conn), "/api/memory/session/end", %{"session_id" => session_id})
        unknown = post(recycle(conn), "/api/memory/session/end", %{"session_id" => "unknown"})
        [first, repeat, unknown]
      end)

    assert Enum.map(responses, &json_response(&1, 200)) == [
             %{"session_id" => session_id, "status" => "ended"},
             %{"session_id" => session_id, "status" => "ended"},
             %{"session_id" => "unknown", "status" => "ended"}
           ]
  end

  test "activated read and maintenance routes preserve their response bodies", %{conn: conn} do
    {:ok, source} = Graph.upsert_node(%{type: "Module", name: "Source"})
    {:ok, target} = Graph.upsert_node(%{type: "File", name: "lib/target.ex"})

    {:ok, _edge} =
      Graph.insert_edge(%{source_id: source.id, target_id: target.id, relation: "uses"})

    updated_at = ~U[2026-07-16 05:00:00.000000Z]

    %Profile{}
    |> Profile.changeset(%{
      project: "backplane",
      top_concepts: %{"events" => 3},
      top_files: %{"lib/router.ex" => 2},
      patterns: %{"testing" => 1},
      session_count: 4,
      total_observations: 9,
      updated_at: updated_at
    })
    |> repo().insert!()

    assert {:ok, file_observation} =
             Backplane.Memory.Observations.record("file-history-session", "updated lib/router.ex")

    audit_id = "11111111-2222-4333-8444-555555555555"
    created_at = ~U[2026-07-16 05:30:00.000000Z]

    {1, nil} =
      repo().insert_all("memory_audit_log", [
        %{
          id: Ecto.UUID.dump!(audit_id),
          operation: "forget",
          actor: "tester",
          target_ids: %{"ids" => ["memory-1"]},
          metadata: %{"reason" => "test"},
          created_at: created_at
        }
      ])

    %Lease{}
    |> Lease.changeset(%{
      action_id: Ecto.UUID.generate(),
      holder_agent_id: "expired-agent",
      acquired_at: DateTime.add(created_at, -120, :second),
      expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
    })
    |> repo().insert!()

    assert get(conn, "/api/memory/graph/stats") |> json_response(200) == %{
             "node_count_by_type" => %{"File" => 1, "Module" => 1},
             "edge_count_by_relation" => %{"uses" => 1}
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
                 "metadata" => %{"reason" => "test"},
                 "created_at" => created_at |> DateTime.to_naive() |> NaiveDateTime.to_iso8601()
               }
             ]
           }

    assert get(recycle(conn), "/api/memory/diagnose") |> json_response(200) == %{
             "status" => "ok",
             "circuit_breaker" => "closed",
             "memory_stats" => [],
             "active_leases" => 1
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

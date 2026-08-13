defmodule Backplane.Api.MemoryLessonsRouterTest do
  use Backplane.Api.ConnCase, async: false

  alias Backplane.Skills.Host
  alias Backplane.Clients

  setup do
    previous_tools = :ets.lookup(:backplane_settings, "memory.tools")
    :ets.insert(:backplane_settings, {"memory.tools", "all"})

    on_exit(fn ->
      :ets.delete(:backplane_settings, "memory.tools")
      if previous_tools != [], do: :ets.insert(:backplane_settings, previous_tools)
    end)

    host =
      Backplane.Repo.insert!(
        Host.changeset(%Host{}, %{
          name: "memory-lessons-router-#{System.unique_integer([:positive])}",
          memory_scope: "lesson-rest"
        })
      )

    token = "lesson-rest-#{System.unique_integer([:positive])}"

    {:ok, _client} =
      Clients.create_client(%{
        name: "Memory lesson REST client",
        token: token,
        scopes: ["memory.read", "memory.write", "memory.admin"],
        active: true,
        metadata: %{"memory_partition_id" => "host:#{host.id}"}
      })

    %{host: host, token: token}
  end

  test "REST save and recall use the canonical lesson service boundary", %{
    conn: conn,
    token: token
  } do
    conn = put_req_header(conn, "authorization", "Bearer #{token}")

    saved =
      post(conn, "/api/memory/lessons", %{
        "rule" => "Always verify REST parity",
        "context" => "api contract",
        "project" => "backplane",
        "idempotency_key" => "rest-lesson"
      })

    assert %{"memory_id" => memory_id, "status" => "active", "source_kind" => "manual"} =
             json_response(saved, 200)

    recalled =
      post(recycle(conn), "/api/memory/lessons/recall", %{
        "query" => "REST parity",
        "project" => "backplane"
      })

    assert %{
             "results" => [
               %{"memory_id" => ^memory_id, "kind" => "lesson", "status" => "active"}
             ]
           } = json_response(recalled, 200)
  end

  test "REST strengthen, promote, and archive use the canonical lesson service boundary", %{
    conn: conn,
    token: token,
    host: host
  } do
    partition = %{
      host_id: host.id,
      client_id: "host:#{host.id}",
      scope: host.memory_scope,
      namespace: "private"
    }

    trace = %{actor: "seed", request_id: "rest-seed", correlation_id: "rest-seed"}

    assert {:ok, candidate} =
             Backplane.Memory.Lessons.create_candidate(
               %{
                 rule: "REST governed candidate",
                 context: "api",
                 project: "backplane",
                 source_kind: "correction",
                 confidence: 0.9,
                 idempotency_key: "rest-candidate"
               },
               partition,
               trace
             )

    conn = put_req_header(conn, "authorization", "Bearer #{token}")

    promoted =
      post(conn, "/api/memory/lessons/promote", %{
        "memory_id" => candidate.memory_id,
        "reason" => "reviewed",
        "idempotency_key" => "rest-promote"
      })

    assert %{"status" => "active"} = json_response(promoted, 200)

    assert {:ok, source_memory} =
             Backplane.Memory.Memories.remember("REST independent evidence",
               type: "semantic",
               host_id: partition.host_id,
               client_id: partition.client_id,
               scope: partition.scope,
               namespace: partition.namespace,
               agent_id: "rest-source",
               idempotency_scope: "rest-source",
               idempotency_key: "rest-source"
             )

    source_request =
      Backplane.Repo.get_by!(Backplane.Memory.Memories.RememberRequest,
        memory_id: source_memory.id
      )

    strengthened =
      post(recycle(conn), "/api/memory/lessons/strengthen", %{
        "memory_id" => candidate.memory_id,
        "mode" => "explicit_confirmation",
        "idempotency_key" => "rest-strengthen",
        "source_request_id" => source_request.id
      })

    assert %{"applied" => true, "reinforcement_count" => 1} = json_response(strengthened, 200)

    archived =
      post(recycle(conn), "/api/memory/lessons/archive", %{
        "memory_id" => candidate.memory_id,
        "action" => "archive",
        "reason" => "retired",
        "idempotency_key" => "rest-archive"
      })

    assert %{"status" => "archived"} = json_response(archived, 200)
  end
end

defmodule Backplane.Admin.MemoryOperatorPagesLiveTest do
  use Backplane.Admin.LiveCase, async: false

  alias Backplane.Memory.Coordination.Action
  alias Backplane.Memory.Coordination.Lease
  alias Backplane.Memory.Audit
  alias Backplane.Memory.Ingest
  alias Backplane.Memory.Projections.Rebuild

  import Backplane.Memory.IngestFixtures

  @partition %{
    "host" => "operator-host",
    "client" => "operator-client",
    "scope" => "operator-scope",
    "namespace" => "operator-namespace"
  }

  test "partitioned operator pages fail closed until all four identity fields are selected", %{
    conn: conn
  } do
    for {path, gate_id} <- [
          {"/memory/sessions", "sessions-partition"},
          {"/memory/timeline", "timeline-partition"},
          {"/memory/memories", "memories-partition"},
          {"/memory/graph", "graph-partition"},
          {"/memory/profile", "profile-partition"},
          {"/memory/actions", "actions-partition"},
          {"/memory/audit", "audit-partition"}
        ] do
      {:ok, view, _html} = live(recycle(conn), path)
      assert has_element?(view, "##{gate_id}")
      assert has_element?(view, "##{gate_id}-host[required]")
      assert has_element?(view, "##{gate_id}-client[required]")
      assert has_element?(view, "##{gate_id}-scope[required]")
      assert has_element?(view, "##{gate_id}-namespace[required]")
    end
  end

  test "bounded read pages accept exact partitions and explicit empty states", %{conn: conn} do
    for {path, root, empty} <- [
          {"/memory/sessions", "memory-sessions", "sessions-empty"},
          {"/memory/timeline", "memory-timeline", "timeline-empty"},
          {"/memory/memories", "memory-memories", "memories-empty"},
          {"/memory/audit", "memory-audit", "audit-empty"}
        ] do
      {:ok, view, _html} = live(recycle(conn), path <> "?" <> URI.encode_query(@partition))
      assert has_element?(view, "##{root}")
      assert has_element?(view, "##{empty}")
    end
  end

  test "profile and actions expose bounded exact-partition states", %{
    conn: conn
  } do
    profile_query = Map.put(@partition, "project", "operator-project")
    {:ok, profile, _html} = live(conn, "/memory/profile?" <> URI.encode_query(profile_query))
    assert has_element?(profile, "#profile-pending")

    partition = %{
      host_id: @partition["host"],
      client_id: @partition["client"],
      scope: @partition["scope"],
      namespace: @partition["namespace"]
    }

    assert {:ok, action} =
             Action.create(
               %{"title" => "Visible completed action", "status" => "done"},
               [],
               partition
             )

    assert {:ok, _foreign} =
             Action.create(%{"title" => "Foreign action"}, [], %{partition | client_id: "foreign"})

    {:ok, actions, _html} =
      live(recycle(conn), "/memory/actions?" <> URI.encode_query(@partition))

    assert has_element?(actions, "#memory-actions-table", action.title)
    refute render(actions) =~ "Foreign action"
  end

  test "action detail shows every origin and its active lease", %{conn: conn} do
    partition = %{
      host_id: @partition["host"],
      client_id: @partition["client"],
      scope: @partition["scope"],
      namespace: @partition["namespace"]
    }

    observation_id = Ecto.UUID.generate()
    memory_id = Ecto.UUID.generate()
    lesson_id = Ecto.UUID.generate()
    crystal_id = Ecto.UUID.generate()

    assert {:ok, action} =
             Action.create(
               %{
                 "title" => "Traceable action",
                 "source_observation_ids" => [observation_id],
                 "source_memory_ids" => [memory_id],
                 "source_session_ids" => ["session-a"],
                 "source_lesson_ids" => [lesson_id],
                 "source_crystal_ids" => [crystal_id]
               },
               [],
               partition
             )

    assert {:ok, _lease_id} = Lease.acquire(action.id, "agent-a", 300, partition)

    query = Map.put(@partition, "action", action.id)
    {:ok, view, _html} = live(conn, "/memory/actions?" <> URI.encode_query(query))

    assert has_element?(view, "#action-detail", "Traceable action")
    assert has_element?(view, "#action-provenance", observation_id)
    assert render(view) =~ memory_id
    assert render(view) =~ "session-a"
    assert render(view) =~ lesson_id
    assert render(view) =~ crystal_id
    assert has_element?(view, "#action-lease", "agent-a")
  end

  test "graph distinguishes disabled and provider-unavailable from an empty graph", %{conn: conn} do
    snapshots =
      for key <- ["memory.pipeline.enabled", "memory.relation_classifier.enabled"],
          into: %{},
          do: {key, :ets.lookup(:backplane_settings, key)}

    previous_llm = Application.get_env(:backplane_memory, :llm_client)

    on_exit(fn ->
      Enum.each(snapshots, fn {key, rows} ->
        :ets.delete(:backplane_settings, key)
        if rows != [], do: :ets.insert(:backplane_settings, rows)
      end)

      if previous_llm,
        do: Application.put_env(:backplane_memory, :llm_client, previous_llm),
        else: Application.delete_env(:backplane_memory, :llm_client)
    end)

    path = "/memory/graph?" <> URI.encode_query(@partition)
    :ets.insert(:backplane_settings, {"memory.pipeline.enabled", false})
    {:ok, disabled, _html} = live(conn, path)
    assert has_element?(disabled, "#graph-disabled")

    :ets.insert(:backplane_settings, {"memory.pipeline.enabled", true})
    :ets.insert(:backplane_settings, {"memory.relation_classifier.enabled", true})
    Application.delete_env(:backplane_memory, :llm_client)
    {:ok, unavailable, _html} = live(recycle(conn), path)
    assert has_element?(unavailable, "#graph-provider-unavailable")

    Application.put_env(:backplane_memory, :llm_client, __MODULE__.FakeLLM)
    {:ok, empty, _html} = live(recycle(conn), path)
    assert has_element?(empty, "#graph-empty")
  end

  test "graph offers distinct relation-domain filters", %{conn: conn} do
    previous_llm = Application.get_env(:backplane_memory, :llm_client)

    snapshots =
      for key <- ["memory.pipeline.enabled", "memory.relation_classifier.enabled"],
          into: %{},
          do: {key, :ets.lookup(:backplane_settings, key)}

    on_exit(fn ->
      Enum.each(snapshots, fn {key, rows} ->
        :ets.delete(:backplane_settings, key)
        if rows != [], do: :ets.insert(:backplane_settings, rows)
      end)

      if previous_llm,
        do: Application.put_env(:backplane_memory, :llm_client, previous_llm),
        else: Application.delete_env(:backplane_memory, :llm_client)
    end)

    :ets.insert(:backplane_settings, {"memory.pipeline.enabled", true})
    :ets.insert(:backplane_settings, {"memory.relation_classifier.enabled", true})
    Application.put_env(:backplane_memory, :llm_client, __MODULE__.FakeLLM)

    {:ok, view, _html} = live(conn, "/memory/graph?" <> URI.encode_query(@partition))

    for domain <- ~w(knowledge lifecycle provenance),
        do: assert(has_element?(view, "#graph-domain-#{domain}"))
  end

  test "memory evidence links to exact event, replay, and session summary destinations" do
    event_id = Ecto.UUID.generate()

    partition = %{
      host_id: @partition["host"],
      client_id: @partition["client"],
      scope: @partition["scope"],
      namespace: @partition["namespace"]
    }

    html =
      render_component(&Backplane.Admin.MemoryMemoriesLive.render/1, %{
        partition: partition,
        rows: [],
        selected: %{
          memory: %{id: Ecto.UUID.generate(), content: "Memory", session_id: "session-a"},
          evidence: [
            %{
              source_type: "event",
              source_id: event_id,
              session_id: "session-a",
              evidence_kind: "supports",
              excerpt: "event"
            },
            %{
              source_type: "summary",
              source_id: Ecto.UUID.generate(),
              session_id: "session-a",
              evidence_kind: "derives",
              excerpt: "summary"
            },
            %{
              source_type: "observation",
              source_id: Ecto.UUID.generate(),
              session_id: "session-a",
              evidence_kind: "supports",
              excerpt: "replay"
            }
          ]
        },
        offset: 0,
        page_size: 25,
        error: nil,
        current_path: "/memory/memories"
      })

    assert html =~ ~s(href="/memory/events/#{event_id}")
    assert html =~ "/memory/sessions?"
    assert html =~ "/memory/replay?"
    assert html =~ "session=session-a"
  end

  test "config is finite, filterable, typed, trusted-route editable, and audited", %{conn: conn} do
    previous = Backplane.Settings.get("memory.replay_max_events")
    on_exit(fn -> Backplane.Settings.set("memory.replay_max_events", previous) end)

    {:ok, view, _html} = live(conn, "/memory/config")
    assert has_element?(view, "#memory-config-table")
    refute has_element?(view, "#config-unauthorized")

    render_change(view, "filter", %{"filters" => %{"q" => "Replay maximum"}})
    assert_patch(view, "/memory/config?q=Replay+maximum")
    assert render(view) =~ "Replay maximum events"
    refute render(view) =~ "Host batch maximum events"

    render_submit(view, "set-setting", %{
      "setting" => %{"key" => "memory.replay_max_events", "value" => "321"}
    })

    assert has_element?(view, "#config-mutation-success", "saved and audited")
    assert Backplane.Settings.get("memory.replay_max_events") == 321

    assert [%{actor: "trusted-admin:memory-config", metadata: metadata} | _] =
             Audit.list(operation: "memory.config.set", limit: 1)

    assert metadata["setting"] == "memory.replay_max_events"
    assert metadata["old_class"] == "integer"
    assert metadata["new_class"] == "integer"
    assert metadata["content_exposed"] == false
    refute Map.has_key?(metadata, "old_value")
    refute Map.has_key?(metadata, "new_value")

    render_submit(view, "set-setting", %{
      "setting" => %{"key" => "memory.replay_max_events", "value" => "10001"}
    })

    assert has_element?(view, "#config-mutation-error", "outside the typed setting bounds")
    assert Backplane.Settings.get("memory.replay_max_events") == 321
  end

  test "partition submissions produce URL-owned trusted operator selection", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/memory/sessions")

    render_submit(view, "select_partition", %{"partition" => @partition})
    patched = assert_patch(view)
    assert URI.decode_query(URI.parse(patched).query) == @partition
  end

  test "session detail renders the shared SES-002 representation and cross-links", %{conn: conn} do
    session_id = "admin-detail-#{System.unique_integer([:positive])}"

    ingest_admin_event!(session_id, 1, "agent.session.started", %{
      "source" => %{"prompt" => "Inspect the fixture", "model" => "gpt-5"}
    })

    ingest_admin_event!(session_id, 2, "agent.tool.completed", %{
      "source" => %{
        "tool_name" => "Read",
        "tool_response" => "read",
        "file_path" => "lib/detail.ex",
        "commit_hash" => "deadbeef"
      }
    })

    ingest_admin_event!(session_id, 3, "agent.session.ended", %{})
    assert {:ok, _} = Rebuild.session(@partition["host"], session_id)

    detail_partition = %{
      "host" => @partition["host"],
      "client" => "host:#{@partition["host"]}",
      "scope" => @partition["scope"],
      "namespace" => "private"
    }

    {:ok, view, _html} =
      live(conn, "/memory/sessions/#{session_id}?" <> URI.encode_query(detail_partition))

    assert has_element?(view, "#memory-session-detail")
    assert render(view) =~ session_id
    assert has_element?(view, "#session-first-prompt", "Inspect the fixture")
    assert has_element?(view, "#session-tool-breakdown", "Read")
    assert has_element?(view, "#session-files", "lib/detail.ex")
    assert has_element?(view, "#session-commits", "deadbeef")
    assert has_element?(view, ~s(a[href*="/memory/timeline?"]), "Timeline")
    assert has_element?(view, ~s(a[href*="/memory/replay?"]), "Replay")
  end

  test "timeline owns every SES-003 filter in the URL", %{conn: conn} do
    query =
      Map.merge(@partition, %{
        "session" => "filter-session",
        "event_type" => "agent.tool.failed",
        "tool" => "Bash",
        "minimum_importance" => "7",
        "error" => "true",
        "file" => "lib/failure.ex",
        "from" => "2026-08-12T00:00:00Z",
        "to" => "2026-08-13T00:00:00Z"
      })

    {:ok, view, _html} = live(conn, "/memory/timeline?" <> URI.encode_query(query))

    assert has_element?(view, "#timeline-filters")
    assert has_element?(view, ~s(input[name="filters[event_type]"][value="agent.tool.failed"]))
    assert has_element?(view, ~s(input[name="filters[tool]"][value="Bash"]))
    assert has_element?(view, ~s(input[name="filters[minimum_importance]"][value="7"]))
    assert has_element?(view, ~s(select[name="filters[error]"] option[selected][value="true"]))
    assert has_element?(view, ~s(input[name="filters[file]"][value="lib/failure.ex"]))
    assert has_element?(view, ~s(input[name="filters[from]"][value="2026-08-12T00:00:00Z"]))
    assert has_element?(view, ~s(input[name="filters[to]"][value="2026-08-13T00:00:00Z"]))

    render_submit(view, "filter", %{
      "filters" => Map.take(query, ~w(event_type tool minimum_importance error file from to))
    })

    decoded = view |> assert_patch() |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    assert Map.take(decoded, Map.keys(query)) == query
    refute Map.has_key?(decoded, "offset")
  end

  defp ingest_admin_event!(session_id, sequence, event_type, payload) do
    occurred_at = DateTime.add(~U[2026-08-12 10:00:00.000000Z], sequence, :second)

    event =
      valid_event(%{
        "event_id" => Ecto.UUID.generate(),
        "host_id" => @partition["host"],
        "client_id" => @partition["client"],
        "scope" => @partition["scope"],
        "namespace" => @partition["namespace"],
        "agent_id" => "operator-agent",
        "integration" => "codex",
        "session_id" => session_id,
        "project" => "operator-project",
        "sequence" => sequence,
        "event_type" => event_type,
        "occurred_at" => DateTime.to_iso8601(occurred_at),
        "captured_at" => DateTime.to_iso8601(occurred_at),
        "idempotency_key" => "admin:#{session_id}:#{sequence}",
        "payload" => payload,
        "payload_hash" => Backplane.Memory.Ingest.EventValidator.payload_hash(payload)
      })

    assert {:ok, %{"results" => [%{"status" => "accepted"}]}} =
             Ingest.ingest_batch(
               %{
                 host_id: @partition["host"],
                 auth_token_id: "admin-detail-token",
                 scopes: ["host_agent.capture"],
                 partition_id: @partition["client"],
                 memory_scope: @partition["scope"]
               },
               %{
                 "batch_id" => Ecto.UUID.generate(),
                 "host_id" => @partition["host"],
                 "events" => [event]
               }
             )
  end
end

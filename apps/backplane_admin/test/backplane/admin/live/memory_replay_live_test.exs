defmodule Backplane.Admin.MemoryReplayLiveTest do
  use Backplane.Admin.LiveCase, async: false

  alias Backplane.Memory.Coordination.Action
  alias Backplane.Memory.Crystals.{Crystal, SourceEvent}
  alias Backplane.Memory.Events.Store
  alias Backplane.Memory.Graph.Node
  alias Backplane.Memory.Lessons.Lesson
  alias Backplane.Memory.Memories.{Evidence, Memory}
  alias Backplane.Memory.Projections.Rebuild
  alias Backplane.Memory.Replay
  alias Backplane.Memory.Summaries.Summary

  @partition %{
    host_id: "replay-ui-host",
    client_id: "replay-ui-client",
    scope: "replay-ui-scope",
    namespace: "private"
  }

  test "router grants separate trusted-operator replay capabilities while direct mounts fail closed",
       %{conn: conn} do
    session = session_id("route-permissions")
    append!(session, 1, "agent.prompt.submitted", %{"source" => %{"prompt" => "visible"}})
    assert {:ok, _result} = Rebuild.session(@partition.host_id, session)

    {:ok, routed_view, _html} =
      live(conn, "/memory/replay?" <> URI.encode_query(replay_params(session)))

    assert has_element?(routed_view, "#replay-player")
    assert has_element?(routed_view, "#replay-detail-json")

    {:ok, denied_view, _html} =
      live_isolated(conn, Backplane.Admin.MemoryReplayLive,
        session: %{
          "memory_replay_params" =>
            replay_params(session)
            |> Map.put("memory_replay_authorized", "true")
            |> Map.put("memory_replay_detail_authorized", "true")
        }
      )

    assert has_element?(denied_view, "#replay-unauthorized")
    refute has_element?(denied_view, "#replay-player")

    {:ok, metadata_view, _html} =
      live_isolated(conn, Backplane.Admin.MemoryReplayLive,
        session: %{
          "memory_replay_authorized" => true,
          "memory_replay_detail_authorized" => false,
          "memory_replay_params" => replay_params(session)
        }
      )

    assert has_element?(metadata_view, "#replay-player")
    assert has_element?(metadata_view, "#replay-detail-denied")
    refute has_element?(metadata_view, "#replay-detail-json")
  end

  test "loads one exact partition and exposes deterministic playback controls", %{conn: conn} do
    session = session_id("controls")
    append!(session, 1, "agent.prompt.submitted", %{"source" => %{"prompt" => "hello"}})

    second_event_id =
      append!(session, 2, "conversation.agent_message", %{
        "source" => %{"message" => "answer"}
      })

    assert {:ok, _result} = Rebuild.session(@partition.host_id, session)

    {:ok, view, html} = open_replay(conn, session)

    assert html =~ "Replay"
    assert html =~ "hello"
    assert has_element?(view, "#memory-replay[phx-hook=ReplayKeyboard]")
    refute has_element?(view, "#memory-replay[phx-window-keydown]")
    assert has_element?(view, "#replay-play-pause")
    assert has_element?(view, "#replay-previous")
    assert has_element?(view, "#replay-next")
    assert has_element?(view, "#replay-scrubber")

    for speed <- ~w(0.5 1 2 4) do
      assert has_element?(view, ~s([data-speed="#{speed}"]))
    end

    assert has_element?(view, ~s([data-kind="prompt"]))
    assert has_element?(view, ~s([data-kind="assistant_response"]))

    view |> element("#replay-next") |> render_click()
    assert has_element?(view, "#replay-event-2[aria-current=true]")
    assert render(view) =~ "answer"

    view |> element("#replay-previous") |> render_click()
    assert has_element?(view, "#replay-event-1[aria-current=true]")

    view |> element("#replay-speed-4") |> render_click()
    assert has_element?(view, "#replay-speed-4[aria-pressed=true]")

    view |> form("#replay-scrubber-form", playback: %{position: "2"}) |> render_change()
    assert has_element?(view, "#replay-event-2[aria-current=true]")

    render_keydown(view, "keyboard", %{"key" => "Home"})
    assert has_element?(view, "#replay-event-1[aria-current=true]")

    view |> element("#replay-kind-assistant_response") |> render_click()
    refute has_element?(view, "#replay-event-2")

    view |> element("#replay-play-pause") |> render_click()
    assert has_element?(view, "#replay-play-pause[aria-pressed=true]")
    view |> element("#replay-play-pause") |> render_click()
    assert has_element?(view, "#replay-play-pause[aria-pressed=false]")

    render_hook(view, "restore_view", %{
      "selected_event_id" => second_event_id,
      "active_kinds" => ["assistant_response"],
      "speed" => "2.0"
    })

    assert has_element?(view, "#replay-event-2[aria-current=true]")
    assert has_element?(view, "#replay-kind-prompt[aria-pressed=false]")
    assert has_element?(view, "#replay-speed-2[aria-pressed=true]")
  end

  test "shows only privacy-filtered detail through the detail permission boundary", %{conn: conn} do
    session = session_id("privacy")

    append!(session, 1, "agent.prompt.submitted", %{
      "source" => %{"prompt" => "hello <private>hidden</private>"}
    })

    append!(session, 2, "tool.call.started", %{
      "source" => %{
        "tool_name" => "HTTP",
        "input" => %{"token" => "short-secret", "url" => "https://example.test"}
      }
    })

    append!(session, 3, "tool.call.completed", %{
      "source" => %{"tool_name" => "HTTP", "result" => "request complete"}
    })

    append!(session, 4, "tool.call.failed", %{
      "source" => %{"tool_name" => "HTTP", "error" => "request failed"}
    })

    append!(session, 5, "git.commit.created", %{
      "source" => %{"commit_hash" => "abc123", "commit_message" => "done"}
    })

    assert {:ok, _result} = Rebuild.session(@partition.host_id, session)

    {:ok, view, html} = open_replay(conn, session)
    assert html =~ "[REDACTED]"
    assert has_element?(view, "#replay-detail-json")
    refute render(element(view, "#replay-detail-json")) =~ "hidden"

    view |> element("#replay-event-2") |> render_click()
    assert render(view) =~ "https://example.test"
    assert render(view) =~ "[REDACTED]"
    refute render(view) =~ "short-secret"

    view |> element("#replay-event-3") |> render_click()
    assert render(view) =~ "request complete"

    view |> element("#replay-event-4") |> render_click()
    assert render(view) =~ "request failed"

    view |> element("#replay-event-5") |> render_click()
    assert render(view) =~ "abc123"
    assert render(view) =~ "2026-08-12T00:00:05"

    {:ok, restricted_view, restricted_html} =
      open_replay(conn, session, %{"memory_replay_detail_authorized" => false})

    assert restricted_html =~ "prompt"
    refute restricted_html =~ "[REDACTED]"
    refute restricted_html =~ "short-secret"
    assert has_element?(restricted_view, "#replay-detail-denied")
    refute has_element?(restricted_view, "#replay-detail-json")
  end

  test "rejects missing or foreign exact partition identity", %{conn: conn} do
    session = session_id("partition")
    append!(session, 1, "agent.prompt.submitted", %{"source" => %{"prompt" => "private prompt"}})
    assert {:ok, _result} = Rebuild.session(@partition.host_id, session)

    {:ok, missing_view, missing_html} =
      live_isolated(conn, Backplane.Admin.MemoryReplayLive,
        session: %{
          "memory_replay_authorized" => true,
          "memory_replay_params" => %{"host" => @partition.host_id, "session" => session}
        }
      )

    assert has_element?(missing_view, "#replay-query-error")
    refute missing_html =~ "private prompt"

    {:ok, foreign_view, foreign_html} =
      open_replay(conn, session, %{
        "memory_replay_params" => replay_params(session) |> Map.put("client", "foreign-client")
      })

    assert has_element?(foreign_view, "#replay-query-error")
    refute foreign_html =~ "private prompt"
  end

  test "reloads the selected replay on a content-free PubSub notifier", %{conn: conn} do
    session = session_id("reload")
    append!(session, 1, "agent.prompt.submitted", %{"source" => %{"prompt" => "first"}})
    assert {:ok, _result} = Rebuild.session(@partition.host_id, session)
    {:ok, view, _html} = open_replay(conn, session)
    refute has_element?(view, "#replay-event-2")

    append!(session, 2, "conversation.agent_message", %{"source" => %{"message" => "second"}})
    assert {:ok, result} = Rebuild.session(@partition.host_id, session)
    assert {:ok, %{events: [_, _]}} = Replay.load(@partition, session)

    Phoenix.PubSub.broadcast(
      Backplane.PubSub,
      "memory:v2:replay",
      {:memory_replay_updated,
       %{"session_id" => session, "input_revision" => result.input_revision}}
    )

    assert eventually(fn -> has_element?(view, "#replay-event-2") end)
    view |> element("#replay-event-2") |> render_click()
    assert render(view) =~ "second"
  end

  test "opens only source IDs linked to the selected event", %{conn: conn} do
    session = session_id("sources")

    first_event_id =
      append!(session, 1, "agent.prompt.submitted", %{"source" => %{"prompt" => "first"}})

    second_event_id =
      append!(session, 2, "conversation.agent_message", %{"source" => %{"message" => "second"}})

    assert {:ok, result} = Rebuild.session(@partition.host_id, session)

    links = insert_links!(session, result, first_event_id, second_event_id)
    assert {:ok, %{events: [first, second]}} = Replay.load(@partition, session)
    assert links.summary.id in first.links.summary
    assert links.first_memory.id in first.links.memory
    assert links.second_memory.id in second.links.memory
    {:ok, view, _html} = open_replay(conn, session)

    assert has_element?(view, source_selector(1, :summary, links.summary.id))
    assert has_element?(view, source_selector(1, :memory, links.first_memory.id))
    assert has_element?(view, source_selector(1, :graph, links.graph.id))

    assert has_element?(
             view,
             ~s(a[href^="/memory/lessons/#{links.lesson.memory_id}?"])
           )

    view |> element("#replay-event-2") |> render_click()
    assert has_element?(view, source_selector(2, :memory, links.second_memory.id))
    assert has_element?(view, source_selector(2, :action, links.action.id))
    assert has_element?(view, ~s(a[href^="/memory/crystals/#{links.crystal.id}?"]))

    view |> element(source_selector(2, :memory, links.second_memory.id)) |> render_click()
    assert has_element?(view, "#replay-source-detail")
    assert render(view) =~ links.second_memory.id

    view |> element("#replay-event-1") |> render_click()
    view |> element(source_selector(1, :memory, links.first_memory.id)) |> render_click()
    assert render(view) =~ links.first_memory.id
    refute render(view) =~ ~s(Source ID</dt><dd[^>]*>#{links.second_memory.id})

    render_click(view, "select_source", %{
      "event-id" => first_event_id,
      "kind" => "memory",
      "source-id" => links.second_memory.id
    })

    assert has_element?(view, "#replay-source-error")
    refute has_element?(view, "#replay-source-detail")
  end

  defp open_replay(conn, session, extra_session \\ %{}) do
    params = replay_params(session)

    live_isolated(conn, Backplane.Admin.MemoryReplayLive,
      session:
        Map.merge(
          %{
            "memory_replay_authorized" => true,
            "memory_replay_detail_authorized" => true,
            "memory_replay_params" => params
          },
          extra_session
        )
    )
  end

  defp append!(session, sequence, event_type, payload) do
    event_id = Ecto.UUID.generate()

    assert {:ok, {:inserted, _}} =
             Store.append_tagged(%{
               id: event_id,
               stream_id: "capture:#{@partition.host_id}:#{session}",
               host_id: @partition.host_id,
               client_id: @partition.client_id,
               scope: @partition.scope,
               namespace: @partition.namespace,
               session_id: session,
               sequence: sequence,
               source_sequence: sequence,
               event_type: event_type,
               occurred_at: DateTime.add(~U[2026-08-12 00:00:00.000000Z], sequence),
               idempotency_key: "#{session}:#{sequence}",
               payload: payload,
               payload_hash: "sha256:#{session}:#{sequence}",
               schema_version: 1
             })

    event_id
  end

  defp insert_links!(session, result, first_event_id, second_event_id) do
    summary =
      repo().insert!(
        Summary.changeset(%Summary{}, %{
          subject_id: result.subject_id,
          host_id: @partition.host_id,
          session_id: session,
          content: "summary",
          processing_version: "summary-v1",
          input_revision: result.input_revision,
          output_revision: String.duplicate("b", 64)
        })
      )

    first_memory = insert_memory!(session, "first")
    second_memory = insert_memory!(session, "second")
    insert_evidence!(first_memory.id, first_event_id, session)
    insert_evidence!(second_memory.id, second_event_id, session)

    lesson =
      repo().insert!(
        Lesson.changeset(%Lesson{}, %{
          memory_id: first_memory.id,
          status: "active",
          source_kind: "manual"
        })
      )

    graph =
      repo().insert!(
        Node.changeset(
          %Node{},
          Map.merge(@partition, %{
            type: "Concept",
            name: "Replay UI",
            source_observation_ids: [first_event_id]
          })
        )
      )

    action =
      repo().insert!(
        Action.changeset(
          %Action{},
          Map.merge(@partition, %{
            title: "Follow up",
            source_observation_ids: [second_event_id]
          })
        )
      )

    crystal =
      repo().insert!(
        Crystal.changeset(
          %Crystal{},
          Map.merge(@partition, %{
            memory_id: second_memory.id,
            subject_id: result.subject_id,
            source_session_id: session,
            title: "Replay crystal",
            narrative: "Narrative",
            processing_version: "crystal-v1",
            prompt_version: "prompt-v1",
            input_revision: result.input_revision,
            output_revision: String.duplicate("c", 64),
            status: "complete"
          })
        )
      )

    repo().insert!(%SourceEvent{
      crystal_id: crystal.id,
      event_id: second_event_id,
      inserted_at: DateTime.utc_now()
    })

    %{
      summary: summary,
      first_memory: first_memory,
      second_memory: second_memory,
      lesson: lesson,
      graph: graph,
      action: action,
      crystal: crystal
    }
  end

  defp insert_memory!(session, suffix) do
    repo().insert!(
      Memory.changeset(
        %Memory{},
        Map.merge(@partition, %{
          content: "linked memory #{suffix}",
          agent_id: "agent",
          session_id: session
        })
      )
    )
  end

  defp insert_evidence!(memory_id, event_id, session) do
    repo().insert!(
      Evidence.changeset(%Evidence{}, %{
        memory_id: memory_id,
        source_event_id: event_id,
        session_id: session,
        host_id: @partition.host_id,
        evidence_kind: "supports",
        support_score: 1.0
      })
    )
  end

  defp replay_params(session) do
    @partition
    |> Map.new(fn {key, value} -> {partition_param(key), value} end)
    |> Map.put("session", session)
  end

  defp source_selector(position, kind, id),
    do: "#replay-source-#{position}-#{kind}-#{id}"

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)

  defp eventually(fun, attempts \\ 10)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(25)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false

  defp session_id(suffix),
    do: "replay-live-#{suffix}-#{System.unique_integer([:positive])}"

  defp partition_param(:host_id), do: "host"
  defp partition_param(:client_id), do: "client"
  defp partition_param(key), do: Atom.to_string(key)
end

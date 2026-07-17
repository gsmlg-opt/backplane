defmodule Backplane.Admin.MemoryEventsLiveTest do
  use Backplane.Admin.LiveCase, async: false

  import Backplane.Admin.MemoryFixtures

  alias Backplane.Memory.Events

  setup :setup_memory_auth
  setup :setup_memory_gates

  test "renders the bounded event inventory and intentional empty state", %{conn: conn} do
    {:ok, view, html} = live(conn, "/memory/events")

    assert has_element?(view, "h1", "Events")

    for label <- [
          "Event",
          "Stream / Sequence",
          "Project / Agent",
          "Tool",
          "Status",
          "Occurred"
        ] do
      assert has_element?(view, "#memory-events-table th", label)
    end

    assert html =~ "No events match these filters"
    assert html =~ "Pipeline is disabled"
    assert html =~ "Events is disabled"
    assert has_element?(view, ~s(a[href="/memory/pipeline"]), "Open Pipeline")
  end

  test "applies every URL-backed event filter", %{conn: conn} do
    marker = unique("event-filters")
    occurred_at = ~U[2026-07-17 05:00:00.123456Z]

    target =
      event_fixture(
        stream_id: "#{marker}-target-stream",
        project: "#{marker}-target-project",
        agent_id: "#{marker}-target-agent",
        session_id: "#{marker}-target-session",
        run_id: "#{marker}-target-run",
        event_type: "tool.call.failed",
        tool_name: "#{marker}-target-tool",
        status: "failed",
        occurred_at: occurred_at
      )

    early =
      event_fixture(
        stream_id: "#{marker}-early-stream",
        project: "#{marker}-early-project",
        agent_id: "#{marker}-early-agent",
        session_id: "#{marker}-early-session",
        run_id: "#{marker}-early-run",
        event_type: "task.created",
        tool_name: "#{marker}-early-tool",
        status: "pending",
        occurred_at: DateTime.add(occurred_at, -1, :hour)
      )

    late =
      event_fixture(
        stream_id: "#{marker}-late-stream",
        project: "#{marker}-late-project",
        agent_id: "#{marker}-late-agent",
        session_id: "#{marker}-late-session",
        run_id: "#{marker}-late-run",
        event_type: "task.updated",
        tool_name: "#{marker}-late-tool",
        status: "completed",
        occurred_at: DateTime.add(occurred_at, 1, :hour)
      )

    for {filter, value} <- [
          {"stream", target.stream_id},
          {"project", target.project},
          {"agent", target.agent_id},
          {"session", target.session_id},
          {"run", target.run_id},
          {"type", target.event_type},
          {"tool", target.tool_name},
          {"status", target.status}
        ] do
      {:ok, _view, html} =
        live(recycle(conn), query_path("/memory/events", %{filter => value}))

      assert table_event_ids(html) == [target.id]
    end

    {:ok, _view, from_html} =
      live(
        recycle(conn),
        query_path("/memory/events", %{
          "from" => DateTime.to_iso8601(target.occurred_at)
        })
      )

    assert target.id in table_event_ids(from_html)
    assert late.id in table_event_ids(from_html)
    refute early.id in table_event_ids(from_html)

    {:ok, _view, to_html} =
      live(
        recycle(conn),
        query_path("/memory/events", %{
          "to" => DateTime.to_iso8601(target.occurred_at)
        })
      )

    assert target.id in table_event_ids(to_html)
    assert early.id in table_event_ids(to_html)
    refute late.id in table_event_ids(to_html)
  end

  test "renders UTC bounds for datetime-local and preserves seconds and fractions on filter changes",
       %{conn: conn} do
    from = "2026-07-17T04:05:06.123456Z"
    to = "2026-07-17T05:06:07.654321Z"

    {:ok, view, _html} =
      live(
        conn,
        query_path("/memory/events", %{
          "from" => from,
          "to" => to
        })
      )

    assert has_element?(
             view,
             ~s|#event-from[value="2026-07-17T04:05:06.123456"]|
           )

    assert has_element?(
             view,
             ~s|#event-to[value="2026-07-17T05:06:07.654321"]|
           )

    render_change(view, "filter", %{
      "filters" => %{
        "project" => "  precision-project  ",
        "from" => "2026-07-17T04:05:06.123456",
        "to" => "2026-07-17T05:06:07.654321",
        "cursor" => "discard-me"
      }
    })

    patched = assert_patch(view)

    assert URI.decode_query(URI.parse(patched).query || "") == %{
             "from" => from,
             "project" => "precision-project",
             "to" => to
           }
  end

  test "successful and invalid loads replace-patch to canonical shareable URLs", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/memory/events")

    path =
      query_path("/memory/events", %{
        "project" => " canonical-events ",
        "from" => "2026-07-17T04:05",
        "limit" => "50"
      })

    render_patch(view, path)
    assert_patch(view, path)
    canonical = assert_patch(view)

    assert URI.decode_query(URI.parse(canonical).query || "") == %{
             "from" => "2026-07-17T04:05:00Z",
             "project" => "canonical-events"
           }

    invalid_time_path =
      query_path("/memory/events", %{
        "project" => "canonical-events",
        "from" => "not-a-time",
        "to" => "2026-07-17T05:06:07.654321Z"
      })

    render_patch(view, invalid_time_path)
    assert_patch(view, invalid_time_path)
    repaired_time = assert_patch(view)

    assert URI.decode_query(URI.parse(repaired_time).query || "") == %{
             "project" => "canonical-events",
             "to" => "2026-07-17T05:06:07.654321Z"
           }

    invalid_cursor_path =
      query_path("/memory/events", %{
        "project" => "canonical-events",
        "to" => "2026-07-17T05:06:07.654321Z",
        "cursor" => "@@@"
      })

    render_patch(view, invalid_cursor_path)
    assert_patch(view, invalid_cursor_path)
    repaired_cursor = assert_patch(view)

    assert URI.decode_query(URI.parse(repaired_cursor).query || "") == %{
             "project" => "canonical-events",
             "to" => "2026-07-17T05:06:07.654321Z"
           }

    assert render(view) =~ "One invalid event parameter was removed."
  end

  test "caps event pages at 100 rows and emits an opaque older cursor", %{conn: conn} do
    project = unique("event-cap")
    _events = append_events!(project, 101)

    {:ok, view, html} =
      live(
        conn,
        query_path("/memory/events", %{
          "project" => project,
          "limit" => "999"
        })
      )

    assert length(table_event_ids(html)) == 100

    [older_link] =
      html
      |> Floki.parse_fragment!()
      |> Floki.find(~s(a[data-phx-link="patch"]))
      |> Enum.filter(&(Floki.text(&1) |> String.trim() == "Load older"))

    older_href = older_link |> Floki.attribute("href") |> List.first()
    older_query = older_href |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert older_query["project"] == project
    assert older_query["limit"] == "100"
    assert is_binary(older_query["cursor"])
    refute older_query["cursor"] =~ "{"
    assert has_element?(view, "#memory-events-table th", "Occurred")
  end

  test "renders an immutable, escaped, directly shareable event detail", %{conn: conn} do
    causation_id = Ecto.UUID.generate()
    content = ~s|<script>alert("unsafe")</script> & visible|

    event =
      event_fixture(
        stream_id: unique("detail-stream"),
        project: "detail-project",
        agent_id: "detail-agent",
        host_id: "detail-host",
        client_id: "detail-client",
        session_id: "detail-session",
        run_id: "detail-run",
        event_type: "tool.call.failed",
        actor_type: "agent",
        role: "assistant",
        status: "failed",
        tool_name: "detail-tool",
        content: content,
        correlation_id: "detail-correlation",
        idempotency_key: unique("detail-idempotency"),
        importance: 7,
        namespace: "private",
        causation_id: causation_id,
        payload: %{
          "message" => "<img src=x onerror=alert(1)>",
          "nested" => %{"answer" => 42}
        },
        occurred_at: ~U[2026-07-17 04:05:06.123456Z]
      )

    assert {:ok, persisted_event} = Backplane.Memory.Operations.get_event(event.id)

    path =
      query_path("/memory/events/#{event.id}", %{
        "project" => event.project
      })

    {:ok, view, html} = live(conn, path)

    assert has_element?(view, "#event-identity", event.id)

    assert has_element?(
             view,
             ~s|#memory-events-table a[href="#{path}"]:not([data-phx-link])|
           )

    for label <- [
          "Event ID",
          "Sequence",
          "Occurred",
          "Persisted",
          "Stream",
          "Project",
          "Agent",
          "Host",
          "Client",
          "Session",
          "Run",
          "Tool",
          "Actor",
          "Role",
          "Importance",
          "Namespace",
          "Correlation",
          "Idempotency",
          "Causation"
        ] do
      assert has_element?(view, "#event-identity dt", label)
    end

    for value <- [
          event.id,
          Integer.to_string(event.sequence),
          DateTime.to_iso8601(event.occurred_at),
          DateTime.to_iso8601(persisted_event.inserted_at),
          event.stream_id,
          event.project,
          event.agent_id,
          event.host_id,
          event.client_id,
          event.session_id,
          event.run_id,
          event.tool_name,
          event.actor_type,
          event.role,
          Integer.to_string(event.importance),
          event.namespace,
          event.correlation_id,
          event.idempotency_key,
          causation_id
        ] do
      assert html =~ value
    end

    assert has_element?(view, "#event-content", content)

    content_html = view |> element("#event-content") |> render()
    assert content_html =~ "&lt;script&gt;"
    refute content_html =~ "<script>"

    payload_html = view |> element("#event-payload") |> render()
    payload_text = payload_html |> Floki.parse_fragment!() |> Floki.text() |> String.trim()

    assert payload_text == Jason.encode!(persisted_event.payload, pretty: true)
    assert payload_text =~ ~s("_backplane")
    assert payload_html =~ "&lt;img"
    refute payload_html =~ "<img"

    for forbidden <- [
          "Edit event",
          "Delete event",
          "Replay",
          "Retry"
        ] do
      refute html =~ forbidden
    end
  end

  test "matching newest notifications authoritatively reload delayed events in persisted order",
       %{conn: conn} do
    project = unique("event-delayed")
    base = ~U[2026-07-17 10:00:00.000000Z]

    oldest =
      event_fixture(
        stream_id: "#{project}-oldest",
        project: project,
        occurred_at: base
      )

    newest =
      event_fixture(
        stream_id: "#{project}-newest",
        project: project,
        occurred_at: DateTime.add(base, 20, :second)
      )

    {:ok, view, html} =
      live(conn, query_path("/memory/events", %{"project" => project}))

    assert table_event_ids(html) == [newest.id, oldest.id]

    delayed =
      event_fixture(
        stream_id: "#{project}-delayed",
        project: project,
        occurred_at: DateTime.add(base, 10, :second)
      )

    send(view.pid, {:memory_event_inserted, safe_summary(delayed)})

    assert table_event_ids(render(view)) == [newest.id, delayed.id, oldest.id]
  end

  test "nonmatching notifications do not reload the current page", %{conn: conn} do
    event = event_fixture(project: unique("matching-project"))

    {:ok, view, html} =
      live(conn, query_path("/memory/events", %{"project" => event.project}))

    ids = table_event_ids(html)
    assert ids == [event.id]
    :ok = fail_memory_reads!()

    nonmatching = %{safe_summary(event) | project: "different-project"}
    send(view.pid, {:memory_event_inserted, nonmatching})

    refute has_element?(view, "#event-query-error")
    assert table_event_ids(render(view)) == ids
    assert Process.alive?(view.pid)
  end

  test "matching historical notifications preserve the page and show a refresh indicator", %{
    conn: conn
  } do
    project = unique("event-history")
    _events = append_events!(project, 51)

    {:ok, view, _html} =
      live(conn, query_path("/memory/events", %{"project" => project}))

    historical_html = view |> element("a", "Load older") |> render_click()
    historical_ids = table_event_ids(historical_html)
    assert length(historical_ids) == 1

    new_event =
      event_fixture(
        stream_id: "#{project}-new",
        project: project,
        occurred_at: ~U[2026-07-18 00:00:00.000000Z]
      )

    send(view.pid, {:memory_event_inserted, safe_summary(new_event)})

    assert has_element?(view, ~s(#event-new-events[title="New events available"]))
    assert table_event_ids(render(view)) == historical_ids

    view
    |> element("#event-new-events a", "Refresh newest")
    |> render_click()

    assert List.first(table_event_ids(render(view))) == new_event.id
  end

  test "retains last good event data on repository failure and ignores unrelated settings", %{
    conn: conn
  } do
    event = event_fixture(project: "last-good-event")

    {:ok, view, _html} =
      live(conn, "/memory/events/#{event.id}?project=last-good-event")

    assert has_element?(view, "#event-payload")
    :ok = fail_memory_reads!()
    send(view.pid, {:memory_event_inserted, safe_summary(event)})

    assert has_element?(view, "#event-query-error")
    assert has_element?(view, "#event-payload")
    refute render(view) =~ "forced memory repository failure"

    send(
      view.pid,
      {:setting_changed, "services.day.enabled", false}
    )

    assert Process.alive?(view.pid)
  end

  defp append_events!(project, count) do
    base = ~U[2026-07-16 00:00:00.000000Z]
    stream_id = unique("#{project}-stream")

    attrs =
      for sequence <- 1..count do
        %{
          stream_id: stream_id,
          event_type: "task.updated",
          project: project,
          content: Integer.to_string(sequence),
          occurred_at: DateTime.add(base, sequence, :second),
          idempotency_key: "#{stream_id}-#{sequence}"
        }
      end

    assert {:ok, events} = Events.append_batch(attrs)
    events
  end

  defp table_event_ids(html) do
    html
    |> Floki.parse_fragment!()
    |> Floki.find("#memory-events-table tbody tr td:first-child a")
    |> Enum.map(fn link ->
      link
      |> Floki.attribute("href")
      |> List.first()
      |> URI.parse()
      |> Map.fetch!(:path)
      |> Path.basename()
    end)
  end

  defp query_path(path, query), do: path <> "?" <> URI.encode_query(query)

  defp unique(prefix) do
    "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
  end
end

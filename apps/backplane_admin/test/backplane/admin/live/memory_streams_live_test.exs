defmodule Backplane.Admin.MemoryStreamsLiveTest do
  use Backplane.Admin.LiveCase, async: false

  import Backplane.Admin.MemoryFixtures

  alias Backplane.Memory.Events
  alias Backplane.Memory.Events.Stream

  setup :setup_memory_gates

  test "renders the bounded inventory and intentional empty state", %{conn: conn} do
    {:ok, view, html} = live(conn, "/memory/streams")

    assert has_element?(view, "h1", "Streams")

    for label <- ["Stream", "Project", "Session / Run", "Sequence", "Last activity", "State"] do
      assert has_element?(view, "#memory-streams-table th", label)
    end

    assert has_element?(view, "#memory-streams-table[phx-mounted]")
    assert html =~ "No streams match these filters"
    assert html =~ "Pipeline is disabled"
    assert html =~ "Events is disabled"

    assert has_element?(
             view,
             ~s|a#memory-open-pipeline[href="/memory/pipeline"]|,
             "Open Pipeline"
           )

    refute has_element?(view, "a el-dm-button")
  end

  test "initial repository failure does not masquerade as an empty stream result", %{conn: conn} do
    :ok = fail_memory_reads!()

    {:ok, view, html} = live(conn, "/memory/streams")

    assert has_element?(view, "#stream-query-error")
    refute html =~ "No streams match these filters"
  end

  test "applies every URL-backed inventory filter", %{conn: conn} do
    marker = unique("stream-filters")

    target =
      event_fixture(
        stream_id: "#{marker}-target",
        project: "#{marker}-project",
        agent_id: "#{marker}-agent",
        host_id: "#{marker}-host",
        client_id: "#{marker}-client",
        session_id: "#{marker}-session",
        run_id: "#{marker}-run"
      )

    closed =
      event_fixture(
        stream_id: "#{marker}-closed",
        project: "#{marker}-other-project",
        agent_id: "#{marker}-other-agent",
        host_id: "#{marker}-other-host",
        session_id: "#{marker}-other-session",
        run_id: "#{marker}-other-run"
      )

    assert {:ok, _stream} = Events.close_stream(closed.stream_id)

    for {filter, value} <- [
          {"project", target.project},
          {"agent", target.agent_id},
          {"host", target.host_id},
          {"session", target.session_id},
          {"run", target.run_id}
        ] do
      {:ok, _view, html} =
        live(recycle(conn), query_path("/memory/streams", %{filter => value}))

      assert html =~ target.stream_id
      refute html =~ closed.stream_id
    end

    {:ok, _view, open_html} =
      live(recycle(conn), query_path("/memory/streams", %{"state" => "open"}))

    assert open_html =~ target.stream_id
    refute open_html =~ closed.stream_id

    {:ok, _view, closed_html} =
      live(recycle(conn), query_path("/memory/streams", %{"state" => "closed"}))

    assert closed_html =~ closed.stream_id
    refute closed_html =~ target.stream_id
  end

  test "filter changes trim blanks and remove inventory and sequence cursors", %{conn: conn} do
    event = event_fixture(project: "filter-patch")
    {:ok, view, _html} = live(conn, "/memory/streams/#{event.stream_id}")

    render_change(view, "filter", %{
      "filters" => %{
        "state" => "",
        "project" => "  filter-patch  ",
        "agent" => " ",
        "host" => "",
        "session" => "",
        "run" => "",
        "cursor" => "discard-me",
        "before" => "9",
        "after" => "10"
      }
    })

    patched = assert_patch(view)
    uri = URI.parse(patched)

    assert uri.path == "/memory/streams/#{event.stream_id}"
    assert URI.decode_query(uri.query || "") == %{"project" => "filter-patch"}
  end

  test "filter changes ignore LiveView unused-field metadata", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/memory/streams")

    render_change(view, "filter", %{
      "filters" => %{
        "_unused_project" => "",
        "_unused_agent" => "",
        "_unused_host" => "",
        "_unused_session" => "",
        "_unused_run" => "",
        "_unused_state" => "",
        "project" => "  metadata-project  ",
        "agent" => "",
        "host" => "",
        "session" => "",
        "run" => "",
        "state" => ""
      }
    })

    patched = assert_patch(view)

    assert URI.decode_query(URI.parse(patched).query || "") == %{
             "project" => "metadata-project"
           }

    refute render(view) =~ "One invalid stream parameter was removed."
  end

  test "successful and invalid loads replace-patch to canonical shareable URLs", %{conn: conn} do
    event = event_fixture(project: "canonical-project")

    path =
      query_path("/memory/streams/#{event.stream_id}", %{
        "project" => " canonical-project ",
        "agent" => " ",
        "limit" => "50",
        "before" => "2"
      })

    {:ok, view, _html} =
      live(conn, "/memory/streams/#{event.stream_id}?project=canonical-project&before=2")

    render_patch(view, path)
    assert_patch(view, path)
    canonical = assert_patch(view)
    canonical_uri = URI.parse(canonical)

    assert canonical_uri.path == "/memory/streams/#{event.stream_id}"

    assert URI.decode_query(canonical_uri.query || "") == %{
             "before" => "2",
             "project" => "canonical-project"
           }

    invalid_path =
      query_path("/memory/streams", %{
        "cursor" => "@@@",
        "project" => "canonical-project"
      })

    render_patch(view, invalid_path)
    assert_patch(view, invalid_path)
    repaired = assert_patch(view)

    assert URI.decode_query(URI.parse(repaired).query || "") == %{
             "project" => "canonical-project"
           }

    assert render(view) =~ "One invalid stream parameter was removed."
  end

  test "compound-invalid URLs need one canonical correction and one concise flash", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/memory/streams")

    compound_path =
      query_path("/memory/streams", %{
        "project" => "compound-streams",
        "state" => "all",
        "cursor" => "@@@"
      })

    render_patch(view, compound_path)
    assert_patch(view, compound_path)
    corrected = assert_patch(view)

    assert URI.decode_query(URI.parse(corrected).query || "") == %{
             "project" => "compound-streams"
           }

    flash =
      view
      |> render()
      |> Floki.parse_fragment!()
      |> Floki.find("#flash-error")

    assert length(flash) == 1
    assert Floki.text(flash) =~ "One invalid stream parameter was removed."

    render_patch(view, corrected)
    assert_patch(view, corrected)
    refute_patched(view)
  end

  test "caps inventory pages and traverses tied and undated streams without gaps", %{conn: conn} do
    project = unique("stream-cap")
    now = ~U[2026-07-17 10:00:00.000000Z]

    for sequence <- 1..101 do
      insert_stream!("#{project}-#{sequence}",
        project: project,
        last_event_at: DateTime.add(now, sequence, :second)
      )
    end

    {:ok, capped_view, capped_html} =
      live(
        conn,
        query_path("/memory/streams", %{
          "project" => project,
          "limit" => "999"
        })
      )

    assert length(table_stream_ids(capped_html)) == 100

    assert has_element?(
             capped_view,
             "a#stream-next-page[data-phx-link=patch][href]",
             "Next page"
           )

    refute has_element?(capped_view, "a el-dm-button")

    capped_view
    |> element("#stream-next-page")
    |> render_click()

    next_href = assert_patch(capped_view)
    next_query = next_href |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert next_query["project"] == project
    assert next_query["limit"] == "100"
    assert is_binary(next_query["cursor"])
    refute next_query["cursor"] =~ "{"
    assert has_element?(capped_view, "#memory-streams-table th", "State")

    tied_project = unique("stream-ties")
    tied_time = ~U[2026-07-17 09:00:00.000000Z]

    for {id, at} <- [
          {"z", DateTime.add(tied_time, 1, :hour)},
          {"b", tied_time},
          {"a", tied_time},
          {"undated-c", nil},
          {"undated-b", nil},
          {"undated-a", nil}
        ] do
      insert_stream!("#{tied_project}-#{id}", project: tied_project, last_event_at: at)
    end

    {:ok, traversal_view, first_html} =
      live(
        recycle(conn),
        query_path("/memory/streams", %{
          "project" => tied_project,
          "limit" => "2"
        })
      )

    first = table_stream_ids(first_html)
    second_html = traversal_view |> element("#stream-next-page") |> render_click()
    second = table_stream_ids(second_html)
    third_html = traversal_view |> element("#stream-next-page") |> render_click()
    third = table_stream_ids(third_html)

    assert first ++ second ++ third == [
             "#{tied_project}-z",
             "#{tied_project}-b",
             "#{tied_project}-a",
             "#{tied_project}-undated-c",
             "#{tied_project}-undated-b",
             "#{tied_project}-undated-a"
           ]

    assert Enum.uniq(first ++ second ++ third) == first ++ second ++ third
    refute has_element?(traversal_view, "#stream-next-page")
  end

  test "renders immutable stream identity and a directly shareable detail", %{conn: conn} do
    stream_id = unique("stream-detail")

    [first, _second, third] =
      append_events!(stream_id, 3,
        project: "detail-project",
        agent_id: "detail-agent",
        host_id: "detail-host",
        client_id: "detail-client",
        session_id: "detail-session",
        run_id: "detail-run"
      )

    assert {:ok, stream} = Events.close_stream(stream_id)
    {:ok, view, html} = live(conn, "/memory/streams/#{stream_id}")

    assert has_element?(view, "#stream-identity", stream_id)
    assert html =~ "grid-cols-1"
    assert html =~ "sm:grid-cols-[max-content_minmax(0,1fr)]"

    assert has_element?(
             view,
             ~s|#memory-streams-table a.text-on-surface.underline[href="/memory/streams/#{stream_id}"]:not([data-phx-link])|
           )

    refute has_element?(view, "#memory-streams-table a.text-primary")

    for value <- [
          "detail-project",
          "detail-agent",
          "detail-host",
          "detail-client",
          "detail-session",
          "detail-run",
          DateTime.to_iso8601(stream.inserted_at),
          DateTime.to_iso8601(third.occurred_at),
          DateTime.to_iso8601(stream.closed_at)
        ] do
      assert html =~ value
    end

    for label <- [
          "Stream ID",
          "Project",
          "Agent",
          "Host",
          "Client",
          "Session",
          "Run",
          "First activity",
          "Last activity",
          "Closed at",
          "Current sequence"
        ] do
      assert has_element?(view, "#stream-identity dt", label)
    end

    assert has_element?(view, "#stream-identity dd", "3")
    assert html =~ "Closed"
    assert sequence_numbers(html) == [first.sequence, 2, third.sequence]

    for forbidden <- ["Edit stream", "Delete stream", "Retry", "Close stream"] do
      refute html =~ forbidden
    end
  end

  test "uses bounded ascending sequence windows with gap-free older/newer round trips", %{
    conn: conn
  } do
    stream_id = unique("stream-sequence")
    append_events!(stream_id, 250)

    {:ok, view, latest_html} = live(conn, "/memory/streams/#{stream_id}")
    assert sequence_numbers(latest_html) == Enum.to_list(151..250)

    assert has_element?(
             view,
             "a#stream-older-events[data-phx-link=patch][href]",
             "Older events"
           )

    refute has_element?(view, "#stream-newer-events")
    refute has_element?(view, "a el-dm-button")

    older_html = view |> element("#stream-older-events") |> render_click()
    assert sequence_numbers(older_html) == Enum.to_list(51..150)

    assert has_element?(
             view,
             "a#stream-older-events[data-phx-link=patch][href]",
             "Older events"
           )

    assert has_element?(
             view,
             "a#stream-newer-events[data-phx-link=patch][href]",
             "Newer events"
           )

    newest_again = view |> element("#stream-newer-events") |> render_click()
    assert sequence_numbers(newest_again) == Enum.to_list(151..250)
    assert Enum.uniq(sequence_numbers(newest_again)) == Enum.to_list(151..250)
  end

  test "matching notifications refresh the newest inventory and selected latest window", %{
    conn: conn
  } do
    stream_id = unique("stream-latest-notification")
    append_events!(stream_id, 1)

    {:ok, detail_view, detail_html} = live(conn, "/memory/streams/#{stream_id}")
    assert sequence_numbers(detail_html) == [1]

    [next_event] = append_events!(stream_id, 1)
    send(detail_view.pid, {:memory_event_inserted, safe_summary(next_event)})

    assert sequence_numbers(render(detail_view)) == [1, 2]
    assert has_element?(detail_view, "#stream-identity dd", "2")

    {:ok, inventory_view, initial_html} = live(recycle(conn), "/memory/streams")
    refute initial_html =~ "inventory-after-mount"

    after_mount =
      event_fixture(stream_id: "inventory-after-mount-#{System.unique_integer([:positive])}")

    send(inventory_view.pid, {:memory_event_inserted, safe_summary(after_mount)})
    assert render(inventory_view) =~ after_mount.stream_id
    assert render(inventory_view) =~ stream_id
  end

  test "notifications refresh latest views but preserve historical windows", %{conn: conn} do
    stream_id = unique("stream-notifications")
    _events = append_events!(stream_id, 150)

    {:ok, view, _html} = live(conn, "/memory/streams/#{stream_id}")
    historical_html = view |> element("#stream-older-events") |> render_click()
    historical_sequences = sequence_numbers(historical_html)

    [new_event] = append_events!(stream_id, 1, idempotency_key: unique("notify-event"))
    send(view.pid, {:memory_event_inserted, safe_summary(new_event)})

    assert has_element?(view, ~s(#stream-new-events[title="New events available"]))
    assert sequence_numbers(render(view)) == historical_sequences

    assert has_element?(
             view,
             "a#stream-refresh-newest[data-phx-link=patch][href]",
             "Refresh newest"
           )

    view
    |> element("#stream-refresh-newest", "Refresh newest")
    |> render_click()

    assert List.last(sequence_numbers(render(view))) == 151
  end

  test "retains last good stream data on repository failure and ignores unrelated settings", %{
    conn: conn
  } do
    event = event_fixture(project: "last-good-stream")

    {:ok, view, _html} =
      live(conn, "/memory/streams/#{event.stream_id}")

    assert has_element?(view, "#stream-identity", event.stream_id)
    :ok = fail_memory_reads!()
    send(view.pid, {:memory_event_inserted, safe_summary(event)})

    assert has_element?(view, "#stream-query-error")
    assert has_element?(view, "#stream-identity", event.stream_id)
    refute render(view) =~ "forced memory repository failure"

    send(view.pid, {:setting_changed, "services.day.enabled", false})

    assert Process.alive?(view.pid)
  end

  defp append_events!(stream_id, count, attrs \\ []) do
    attrs = Map.new(attrs)

    events =
      for sequence <- 1..count do
        attrs
        |> Map.put(:stream_id, stream_id)
        |> Map.put(:event_type, "task.updated")
        |> Map.put(:content, Integer.to_string(sequence))
        |> Map.put_new(:idempotency_key, "#{stream_id}-#{sequence}-#{unique("event")}")
      end

    assert {:ok, events} = Events.append_batch(events)
    events
  end

  defp insert_stream!(stream_id, attrs) do
    attrs =
      attrs
      |> Map.new()
      |> Map.put(:stream_id, stream_id)

    %Stream{}
    |> struct(attrs)
    |> repo().insert!()
  end

  defp table_stream_ids(html) do
    html
    |> Floki.parse_fragment!()
    |> Floki.find("#memory-streams-table tbody tr td:first-child a")
    |> Enum.map(&(Floki.text(&1) |> String.trim()))
  end

  defp sequence_numbers(html) do
    ~r/#(\d+) · task\.updated/
    |> Regex.scan(html, capture: :all_but_first)
    |> List.flatten()
    |> Enum.map(&String.to_integer/1)
  end

  defp query_path(path, query), do: path <> "?" <> URI.encode_query(query)

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)

  defp unique(prefix) do
    "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
  end
end

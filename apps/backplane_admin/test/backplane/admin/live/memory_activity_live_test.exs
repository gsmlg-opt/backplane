defmodule Backplane.Admin.MemoryActivityLiveTest do
  use Backplane.Admin.LiveCase, async: false

  alias Backplane.Memory.Events.Store
  alias Backplane.Memory.Projections.{ActivityContribution, ActivityDaily}
  alias Backplane.Skills.{AgentManage, Hosts}

  @partition %{
    host_id: "activity-ui-host",
    client_id: "activity-ui-client",
    scope: "team",
    namespace: "private"
  }

  setup do
    AgentManage.clear()
    on_exit(fn -> AgentManage.clear() end)
  end

  test "renders retained exact-partition activity with filters, trends, and bounded distribution",
       %{
         conn: conn
       } do
    today = Date.utc_today()
    insert_activity!(Date.add(today, -2), "alpha", "agent-a", "memory.recalled", 3)
    insert_activity!(Date.add(today, -1), "beta", "agent-b", "agent.tool.failed", 2)
    insert_activity!(today, "alpha", "agent-a", "task.completed", 1)

    insert_activity!(today, "foreign", "agent-x", "memory.recalled", 99, host_id: "foreign-host")

    {:ok, view, html} = activity_live(conn)

    assert html =~ "Activity"
    assert has_element?(view, "#activity-exact-host", @partition.host_id)
    assert has_element?(view, "#activity-host-filter[readonly][value='#{@partition.host_id}']")
    retention_days = Backplane.Memory.Config.activity_retention_days()
    assert element_count(view, "#activity-heatmap [data-date]") == retention_days

    assert has_element?(
             view,
             "#activity-heatmap [data-date='#{Date.add(Date.utc_today(), 1 - retention_days)}']"
           )

    assert has_element?(view, "#activity-heatmap [data-date='#{Date.utc_today()}']")
    assert has_element?(view, "#activity-summary-events", "6")
    assert has_element?(view, "#activity-event-distribution", "memory.recalled")
    assert has_element?(view, "#activity-project-breakdown", "alpha")
    assert has_element?(view, "#activity-project-breakdown", "beta")
    assert has_element?(view, "#activity-agent-breakdown", "agent-a")
    assert has_element?(view, "#activity-agent-breakdown", "agent-b")
    assert has_element?(view, "#activity-host-breakdown", @partition.host_id)
    assert has_element?(view, "#activity-host-breakdown", "foreign-host")
    assert has_element?(view, "#activity-trends th", "Actions")
    assert has_element?(view, "#activity-trends th", "Recalls")
    refute has_element?(view, "#activity-project-breakdown", "foreign")

    view
    |> form("#activity-filters", %{
      "filters" => %{
        "project" => "alpha",
        "agent_id" => "agent-a",
        "event_type" => "memory.recalled"
      }
    })
    |> render_change()

    assert has_element?(view, "#activity-summary-events", "3")
    refute render(view) =~ "agent.tool.failed"

    retained_dates = Date.range(Date.add(Date.utc_today(), 1 - retention_days), Date.utc_today())

    period_counts = [
      {"daily", retention_days},
      {"monthly", retained_dates |> Enum.map(&{&1.year, &1.month}) |> Enum.uniq() |> length()},
      {"yearly", retained_dates |> Enum.map(& &1.year) |> Enum.uniq() |> length()}
    ]

    for {period, expected_rows} <- period_counts do
      view |> element("#activity-period-#{period}") |> render_click()
      assert element_count(view, "#activity-trends [data-period]") == expected_rows
    end
  end

  test "paginates a bounded event distribution", %{conn: conn} do
    today = Date.utc_today()

    for index <- 1..12 do
      insert_activity!(today, "project", "agent", "custom.event.#{index}", index)
    end

    {:ok, view, _html} = activity_live(conn)
    assert element_count(view, "#activity-event-distribution tbody tr") == 10
    assert has_element?(view, "#activity-distribution-next")

    view |> element("#activity-distribution-next") |> render_click()
    assert element_count(view, "#activity-event-distribution tbody tr") == 2
    assert has_element?(view, "#activity-distribution-previous")
  end

  test "reloads from PostgreSQL on matching PubSub updates and ignores foreign partitions", %{
    conn: conn
  } do
    today = Date.utc_today()
    insert_event!(today, 1, "memory.recalled")
    insert_activity!(today, "live", "agent", "memory.recalled", 1)
    {:ok, view, _html} = activity_live(conn)
    assert has_element?(view, "#activity-summary-events", "1")
    assert has_element?(view, "#activity-recent-events", "memory.recalled")

    insert_event!(today, 2, "task.completed")
    insert_activity!(today, "live", "agent", "task.completed", 2)

    Phoenix.PubSub.broadcast(
      Backplane.PubSub,
      "memory:v2:activity",
      {:memory_activity_updated, Map.merge(@partition, %{date_from: today, date_to: today})}
    )

    assert render(view) =~ "Live update received"
    assert has_element?(view, "#activity-summary-events", "3")
    assert has_element?(view, "#activity-recent-events", "task.completed")

    insert_activity!(today, "foreign", "agent", "agent.tool.failed", 50, host_id: "foreign-host")

    Phoenix.PubSub.broadcast(
      Backplane.PubSub,
      "memory:v2:activity",
      {:memory_activity_updated,
       Map.merge(@partition, %{
         host_id: "foreign-host",
         date_from: today,
         date_to: today
       })}
    )

    assert has_element?(view, "#activity-summary-events", "3")

    {:ok, reconnected, _html} = activity_live(recycle(conn))
    assert has_element?(reconnected, "#activity-summary-events", "3")
    assert has_element?(reconnected, "#activity-recent-events", "task.completed")
  end

  test "fails closed without a complete durable partition", %{conn: conn} do
    repo().delete_all(ActivityContribution)
    repo().delete_all(ActivityDaily)
    {:ok, view, html} = live(conn, "/memory/activity")
    assert html =~ "Activity partition unavailable"
    refute has_element?(view, "#activity-heatmap")
  end

  test "selects only server-enumerated durable partitions", %{conn: conn} do
    today = Date.utc_today()
    insert_activity!(today, "alpha", "agent", "memory.recalled", 1)
    insert_activity!(today, "beta", "agent", "task.completed", 7, host_id: "zz-host")

    {:ok, view, _html} = activity_live(conn)
    assert has_element?(view, "#activity-exact-host", @partition.host_id)

    option_index = partition_option_index(view, "zz-host")

    view
    |> form("#activity-partition-selector", %{"selection" => %{"index" => option_index}})
    |> render_change()

    assert has_element?(view, "#activity-exact-host", "zz-host")
    assert has_element?(view, "#activity-summary-events", "7")

    render_change(view, "select_partition", %{"selection" => %{"index" => "999"}})

    assert has_element?(view, "#activity-exact-host", "zz-host")
  end

  test "reuses live host-agent capture and delivery health for the selected host", %{conn: conn} do
    assert {:ok, host, auth_token, _token} =
             Hosts.create_agent_with_token(%{"name" => "activity-capture-host"})

    assert :ok = AgentManage.register_connection(host, auth_token, self(), %{})

    assert :ok =
             AgentManage.update_runtime(host.id, %{
               "agent_version" => "0.2.0",
               "capture" => %{
                 "connection_state" => "connected",
                 "spool_depth" => 2,
                 "spool_bytes" => 4_096,
                 "oldest_event_age_ms" => 12_000,
                 "captured_count" => 9,
                 "redacted_count" => 3,
                 "rejected_count" => 1,
                 "retry_count" => 4,
                 "dead_letter_count" => 0,
                 "upload_latency_ms" => 14,
                 "ack_latency_ms" => 8
               }
             })

    partition = %{@partition | host_id: host.id}

    insert_activity!(Date.utc_today(), "capture", "agent", "agent.session.started", 1,
      host_id: host.id
    )

    {:ok, view, html} = activity_live(conn, partition)

    assert has_element?(view, "#activity-host-health", "Connected")
    assert html =~ "2 / 4.0 KiB"
    assert html =~ "12s"
    assert html =~ "14 ms / 8 ms"
    assert html =~ "0.2.0"
    refute html =~ "payload"

    assert :ok =
             AgentManage.update_runtime(host.id, %{
               "capture" => %{"connection_state" => "disconnected", "spool_depth" => 3}
             })

    assert has_element?(view, "#activity-host-health", "Disconnected")
    assert has_element?(view, "#activity-host-health", "3")
  end

  defp activity_live(conn, partition \\ @partition) do
    {:ok, view, html} = live(conn, "/memory/activity")
    option_index = partition_option_index(view, partition.host_id)

    if has_element?(view, "#activity-partition option[selected][value='#{option_index}']") do
      {:ok, view, html}
    else
      view
      |> form("#activity-partition-selector", %{"selection" => %{"index" => option_index}})
      |> render_change()

      {:ok, view, render(view)}
    end
  end

  defp partition_option_index(view, host_id) do
    view
    |> render()
    |> Floki.parse_fragment!()
    |> Floki.find("#activity-partition-selector option")
    |> Enum.find_value(fn option ->
      if Floki.text(option) =~ host_id,
        do: option |> Floki.attribute("value") |> List.first()
    end)
  end

  defp insert_activity!(date, project, agent, event_type, count, overrides \\ []) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    partition = Map.merge(@partition, Map.new(overrides))
    subject = "#{partition.host_id}:#{project}:#{agent}:#{event_type}"

    dimensions =
      Map.merge(partition, %{
        date: date,
        project: project,
        agent_id: agent,
        event_type: event_type
      })

    counters = %{
      event_count: count,
      session_count: 1,
      memory_count:
        if(String.starts_with?(event_type, "memory.") and event_type != "memory.recalled",
          do: count,
          else: 0
        ),
      lesson_count: if(String.starts_with?(event_type, "lesson."), do: count, else: 0),
      crystal_count: if(String.starts_with?(event_type, "crystal."), do: count, else: 0),
      recall_count: if(event_type == "memory.recalled", do: count, else: 0),
      action_count: if(String.starts_with?(event_type, "task."), do: count, else: 0),
      error_count: if(String.ends_with?(event_type, ".failed"), do: count, else: 0),
      inserted_at: now,
      updated_at: now
    }

    repo().insert_all(ActivityDaily, [Map.merge(dimensions, counters)])

    repo().insert_all(ActivityContribution, [
      dimensions
      |> Map.merge(counters)
      |> Map.merge(%{
        subject_id: subject,
        processing_version: "activity-v1",
        input_revision: "revision"
      })
    ])
  end

  defp insert_event!(date, sequence, event_type) do
    occurred_at = DateTime.new!(date, Time.new!(sequence, 0, 0, {0, 6}), "Etc/UTC")

    assert {:ok, {:inserted, _event}} =
             Store.append_tagged(%{
               id: Ecto.UUID.generate(),
               stream_id: "capture:#{@partition.host_id}:activity-live-feed",
               host_id: @partition.host_id,
               client_id: @partition.client_id,
               scope: @partition.scope,
               namespace: @partition.namespace,
               session_id: "activity-live-feed",
               project: "live",
               agent_id: "agent",
               sequence: sequence,
               source_sequence: sequence,
               event_type: event_type,
               occurred_at: occurred_at,
               idempotency_key: "activity-live-feed:#{sequence}",
               payload: %{"secret" => "must-not-render"},
               payload_hash: "sha256:activity-live-feed:#{sequence}",
               schema_version: 1
             })
  end

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)

  defp element_count(view, selector) do
    view
    |> render()
    |> Floki.parse_fragment!()
    |> Floki.find(selector)
    |> length()
  end
end

defmodule Backplane.Memory.ActivityTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.Activity
  alias Backplane.Memory.Events.Store
  alias Backplane.Memory.Operations.Activity, as: OperatorActivity
  alias Backplane.Memory.Projections.ActivityDaily
  alias Backplane.Memory.Projections.Rebuild

  @partition %{
    host_id: "activity-host",
    client_id: "activity-client",
    scope: "activity-scope",
    namespace: "private"
  }

  test "heatmap returns every day in the requested window from exact-partition aggregates" do
    insert_daily!(~D[2026-08-01], %{event_count: 3, error_count: 1})
    insert_daily!(~D[2026-08-03], %{event_count: 2})
    insert_daily!(~D[2026-08-02], %{host_id: "foreign-host", event_count: 99})

    assert {:ok,
            [
              %{date: ~D[2026-08-01], event_count: 3, error_count: 1},
              %{date: ~D[2026-08-02], event_count: 0, error_count: 0},
              %{date: ~D[2026-08-03], event_count: 2, error_count: 0}
            ]} =
             Activity.heatmap(@partition,
               date_from: ~D[2026-08-01],
               date_to: ~D[2026-08-03]
             )

    assert {:error, :unauthorized} =
             Activity.heatmap(Map.delete(@partition, :namespace),
               date_from: ~D[2026-08-01],
               date_to: ~D[2026-08-03]
             )
  end

  test "trends derive counters from canonical events and count each session once per day" do
    append_event!("session-one", 1, "agent.prompt.submitted", ~U[2026-08-01 01:00:00.000000Z],
      status: "failed"
    )

    append_event!("session-one", 2, "agent.tool.failed", ~U[2026-08-01 01:01:00.000000Z])
    append_event!("session-two", 1, "memory.recalled", ~U[2026-08-03 01:00:00.000000Z])
    append_event!("session-two", 2, "task.created", ~U[2026-08-03 01:01:00.000000Z])

    assert {:ok, _} = Rebuild.session(@partition.host_id, "session-one")
    assert {:ok, _} = Rebuild.session(@partition.host_id, "session-two")

    # Canonical input is not visible until the incremental activity projection commits.
    append_event!("unprojected", 1, "agent.tool.failed", ~U[2026-08-01 02:00:00.000000Z])

    assert {:ok, [first, empty, last]} =
             Activity.trends(@partition,
               date_from: ~D[2026-08-01],
               date_to: ~D[2026-08-03]
             )

    assert %{
             date: ~D[2026-08-01],
             event_count: 2,
             session_count: 1,
             error_count: 2,
             recall_count: 0,
             action_count: 0
           } = first

    assert %{date: ~D[2026-08-02], event_count: 0, session_count: 0} = empty

    assert %{
             date: ~D[2026-08-03],
             event_count: 2,
             session_count: 1,
             recall_count: 1,
             action_count: 1,
             memory_count: 0,
             lesson_count: 0,
             crystal_count: 0
           } = last
  end

  test "breakdowns and summary use bounded server filters over canonical durable events" do
    append_event!("session-a", 1, "agent.prompt.submitted", ~U[2026-08-01 01:00:00.000000Z])
    append_event!("session-a", 2, "agent.tool.failed", ~U[2026-08-01 01:01:00.000000Z])

    append_event!("session-b", 1, "task.created", ~U[2026-08-02 01:00:00.000000Z],
      project: "other"
    )

    append_event!("foreign", 1, "agent.tool.failed", ~U[2026-08-01 01:00:00.000000Z],
      host_id: "foreign-host"
    )

    opts = [date_from: ~D[2026-08-01], date_to: ~D[2026-08-02], project: "backplane"]

    assert {:ok, _} = Rebuild.session(@partition.host_id, "session-a")
    assert {:ok, _} = Rebuild.session(@partition.host_id, "session-b")

    append_event!("unprojected", 1, "agent.tool.failed", ~U[2026-08-01 02:00:00.000000Z])

    assert {:ok,
            [
              %{key: "agent.prompt.submitted", event_count: 1, session_count: 1},
              %{key: "agent.tool.failed", event_count: 1, session_count: 1, error_count: 1}
            ]} = Activity.breakdown(@partition, :event_type, opts)

    assert {:ok,
            %{
              date_from: ~D[2026-08-01],
              date_to: ~D[2026-08-02],
              event_count: 2,
              session_count: 1,
              error_count: 1,
              action_count: 0,
              recall_count: 0
            }} = Activity.summary(@partition, opts)

    assert {:error, :invalid_options} = Activity.breakdown(@partition, :unknown, opts)

    assert {:error, :invalid_options} =
             Activity.breakdown(@partition, :project, opts ++ [limit: 101])
  end

  test "public activity stays exact-host while operator activity compares server-owned partitions" do
    append_event!("host-a-session", 1, "memory.recalled", ~U[2026-08-01 01:00:00.000000Z])

    append_event!("host-b-session", 1, "task.created", ~U[2026-08-01 02:00:00.000000Z],
      host_id: "activity-host-b"
    )

    assert {:ok, _} = Rebuild.session(@partition.host_id, "host-a-session")
    assert {:ok, _} = Rebuild.session("activity-host-b", "host-b-session")

    tenant_partition = %{
      client_id: @partition.client_id,
      scope: @partition.scope,
      namespace: @partition.namespace
    }

    opts = [date_from: ~D[2026-08-01], date_to: ~D[2026-08-01], limit: 10]

    assert {:ok,
            [
              %{key: "activity-host", event_count: 1, session_count: 1},
              %{key: "activity-host-b", event_count: 1, session_count: 1}
            ]} = OperatorActivity.host_breakdown(tenant_partition, opts)

    assert {:ok, [%{key: "activity-host"}]} =
             Activity.breakdown(@partition, :host_id, opts)

    refute function_exported?(Activity, :admin_host_breakdown, 2)
  end

  test "recent event feed is bounded, privacy-safe, filtered, and exact-partitioned" do
    append_event!("feed-session", 1, "memory.recalled", ~U[2026-08-01 01:00:00.000000Z])
    append_event!("feed-session", 2, "task.created", ~U[2026-08-01 02:00:00.000000Z])

    append_event!("foreign-feed", 1, "agent.tool.failed", ~U[2026-08-01 03:00:00.000000Z],
      host_id: "foreign-feed-host"
    )

    assert {:ok, [latest]} =
             Activity.recent_events(@partition,
               date_from: ~D[2026-08-01],
               date_to: ~D[2026-08-01],
               event_type: "task.created",
               limit: 1
             )

    assert latest.event_type == "task.created"
    assert latest.project == "backplane"
    assert latest.agent_id == "agent-1"
    assert latest.occurred_at == ~U[2026-08-01 02:00:00.000000Z]

    assert Map.keys(latest) |> Enum.sort() == [
             :agent_id,
             :event_type,
             :id,
             :occurred_at,
             :project
           ]

    assert {:error, :invalid_options} = Activity.recent_events(@partition, limit: 101)
  end

  defp insert_daily!(date, overrides) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    defaults = %{
      date: date,
      project: "backplane",
      agent_id: "agent-1",
      event_type: "agent.prompt.submitted",
      event_count: 0,
      session_count: 0,
      memory_count: 0,
      lesson_count: 0,
      crystal_count: 0,
      recall_count: 0,
      action_count: 0,
      error_count: 0,
      inserted_at: now,
      updated_at: now
    }

    repo().insert_all(ActivityDaily, [@partition |> Map.merge(defaults) |> Map.merge(overrides)])
  end

  defp append_event!(session_id, sequence, event_type, occurred_at, overrides \\ []) do
    host_id = Keyword.get(overrides, :host_id, @partition.host_id)

    assert {:ok, {:inserted, _event}} =
             Store.append_tagged(%{
               id: Ecto.UUID.generate(),
               stream_id: "capture:#{host_id}:#{session_id}",
               host_id: host_id,
               client_id: @partition.client_id,
               scope: @partition.scope,
               namespace: @partition.namespace,
               session_id: session_id,
               project: Keyword.get(overrides, :project, "backplane"),
               agent_id: Keyword.get(overrides, :agent_id, "agent-1"),
               status: Keyword.get(overrides, :status),
               sequence: sequence,
               source_sequence: sequence,
               event_type: event_type,
               occurred_at: occurred_at,
               idempotency_key: "#{session_id}:#{sequence}",
               payload: %{},
               payload_hash: "sha256:#{session_id}:#{sequence}",
               schema_version: 1
             })
  end
end

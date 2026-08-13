defmodule Backplane.Memory.Projections.ActivityReadModelsTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.Projections.{ActivityDaily, ReadModels}

  test "returns complete old history from the indexed daily table with server filters" do
    suffix = unique()

    insert_activity!(
      suffix,
      ~D[2025-09-01],
      "project-old",
      "agent-old",
      "host-old",
      "agent.tool.failed",
      2
    )

    insert_activity!(
      suffix,
      ~D[2026-08-01],
      "project-new",
      "agent-new",
      "host-new",
      "memory.recalled",
      3
    )

    insert_activity!(
      "other-#{suffix}",
      ~D[2025-09-01],
      "project-old",
      "agent-old",
      "host-old",
      "agent.tool.failed",
      99
    )

    assert {:ok, [old]} =
             ReadModels.activity(
               client_id: "client-#{suffix}",
               scope: "scope-#{suffix}",
               namespace: "private",
               date_from: ~D[2025-09-01],
               date_to: ~D[2025-10-01],
               project: "project-old",
               agent_id: "agent-old",
               host_id: "host-old",
               event_type: "agent.tool.failed",
               limit: 10
             )

    assert old.date == ~D[2025-09-01]
    assert old.event_count == 2
    assert old.error_count == 2

    assert {:ok, [old]} =
             ReadModels.activity(
               client_id: "client-#{suffix}",
               scope: "scope-#{suffix}",
               namespace: "private",
               host_id: "host-old",
               date_from: ~D[2025-09-01],
               date_to: ~D[2026-08-31],
               limit: 2
             )

    assert [old.date] == [~D[2025-09-01]]
  end

  test "requires a complete partition and bounds dates, offsets, limits, and configured window" do
    assert {:error, :invalid_options} = ReadModels.activity([])

    base = [client_id: "client", scope: "scope", namespace: "private", host_id: "host"]
    assert {:error, :invalid_options} = ReadModels.activity(Keyword.delete(base, :host_id))
    assert {:error, :invalid_options} = ReadModels.activity(base ++ [limit: 0])
    assert {:error, :invalid_options} = ReadModels.activity(base ++ [limit: 10_001])
    assert {:error, :invalid_options} = ReadModels.activity(base ++ [offset: 10_001])
    assert {:error, :invalid_options} = ReadModels.activity(base ++ [date_from: "not-a-date"])

    assert {:error, :invalid_options} =
             ReadModels.activity(base ++ [date_from: ~D[2020-01-01], date_to: ~D[2026-08-12]])
  end

  test "activity query uses an indexed bounded partition-date predicate" do
    suffix = unique()
    insert_activity!(suffix, ~D[2026-08-01], "project", "agent", "host", "memory.recalled", 1)

    repo().query!("SET LOCAL enable_seqscan = off")

    plan =
      repo().query!(
        """
        EXPLAIN (FORMAT TEXT)
        SELECT * FROM memory_activity_daily
        WHERE host_id = $1 AND client_id = $2 AND scope = $3 AND namespace = 'private'
          AND date >= '2026-01-01' AND date <= '2026-12-31'
        ORDER BY date DESC, project, agent_id, host_id, event_type
        LIMIT 100
        """,
        ["host", "client-#{suffix}", "scope-#{suffix}"]
      ).rows
      |> List.flatten()
      |> Enum.join("\n")

    assert plan =~ ~r/(Index Scan|Bitmap Index Scan)/
    assert plan =~ "Index Cond:"
    assert plan =~ "host_id"
    assert plan =~ "client_id"
    assert plan =~ "scope"
    assert plan =~ "namespace"
    assert plan =~ "date"
  end

  defp insert_activity!(suffix, date, project, agent, host, event_type, count) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    repo().insert_all(ActivityDaily, [
      %{
        date: date,
        project: project,
        agent_id: agent,
        host_id: host,
        client_id: "client-#{suffix}",
        scope: "scope-#{suffix}",
        namespace: "private",
        event_type: event_type,
        event_count: count,
        session_count: 1,
        memory_count: 0,
        lesson_count: 0,
        crystal_count: 0,
        recall_count: if(event_type == "memory.recalled", do: count, else: 0),
        action_count: 0,
        error_count: if(event_type == "agent.tool.failed", do: count, else: 0),
        inserted_at: now,
        updated_at: now
      }
    ])
  end

  defp unique, do: System.unique_integer([:positive]) |> Integer.to_string()
end

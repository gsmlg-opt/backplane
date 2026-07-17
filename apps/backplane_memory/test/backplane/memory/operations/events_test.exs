defmodule Backplane.Memory.Operations.EventsTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.Events.Store
  alias Backplane.Memory.Operations

  defmodule EventsFailingRepo do
    def all(_query), do: raise("forced events read failure")
    def get(_schema, _id), do: raise("forced events read failure")
  end

  test "timeline filters events, returns canonical filters, and resolves event detail" do
    project = unique("operations-events")

    completed =
      append!(%{
        stream_id: "#{project}:stream",
        event_type: "agent.run.completed",
        project: project,
        status: "completed"
      })

    failed =
      append!(%{
        stream_id: "#{project}:stream",
        event_type: "agent.run.failed",
        project: project,
        status: "failed"
      })

    assert {:ok, %{events: events, next_cursor: nil, filters: filters}} =
             Operations.timeline(%{
               "project" => project,
               "status" => "failed",
               "limit" => "100"
             })

    assert Enum.map(events, & &1.id) == [failed.id]

    assert filters == %{
             "limit" => "100",
             "project" => project,
             "status" => "failed"
           }

    assert {:ok, fetched_failed} = Operations.get_event(failed.id)
    assert fetched_failed.id == failed.id
    assert fetched_failed.inserted_at

    assert {:ok, fetched_completed} = Operations.get_event(completed.id)
    assert fetched_completed.id == completed.id
    assert fetched_completed.inserted_at
    assert {:error, :not_found} = Operations.get_event(Ecto.UUID.generate())
    assert {:error, :not_found} = Operations.get_event("not-a-uuid")
  end

  test "timeline enforces the 100-row admin cap" do
    project = unique("operations-cap")

    attrs =
      for n <- 1..101 do
        %{
          stream_id: "#{project}:stream",
          event_type: "task.updated",
          project: project,
          content: Integer.to_string(n)
        }
      end

    assert {:ok, _events} = Store.append_batch(attrs, telemetry: false)

    assert {:ok, %{events: events, next_cursor: cursor, filters: filters}} =
             Operations.timeline(%{"project" => project, "limit" => "999"})

    assert length(events) == 100
    assert is_binary(cursor)
    assert filters == %{"project" => project, "limit" => "100"}
  end

  test "a malformed cursor returns the valid canonical query without the cursor" do
    project = unique("operations-cursor")

    assert {:error, {:invalid_param, :cursor, %{"project" => ^project, "limit" => "100"}}} =
             Operations.timeline(%{
               "project" => project,
               "cursor" => "not-a-cursor",
               "limit" => "100"
             })
  end

  test "repository failures return errors instead of raising" do
    previous_repo = Application.fetch_env(:backplane_memory, :repo)

    on_exit(fn ->
      case previous_repo do
        {:ok, repo} -> Application.put_env(:backplane_memory, :repo, repo)
        :error -> Application.delete_env(:backplane_memory, :repo)
      end
    end)

    Application.put_env(:backplane_memory, :repo, EventsFailingRepo)

    assert {:error, %RuntimeError{message: "forced events read failure"}} =
             Operations.timeline(%{})

    assert {:error, %RuntimeError{message: "forced events read failure"}} =
             Operations.get_event(Ecto.UUID.generate())
  end

  test "notification matching covers every filter with inclusive time bounds" do
    occurred_at = ~U[2026-07-17 04:05:06.000000Z]

    summary = %{
      id: Ecto.UUID.generate(),
      stream_id: "stream-1",
      event_type: "tool.call.failed",
      project: "project-1",
      agent_id: "agent-1",
      session_id: "session-1",
      run_id: "run-1",
      tool_name: "tool-1",
      status: "failed",
      occurred_at: occurred_at
    }

    all_filters = %{
      "stream" => summary.stream_id,
      "project" => summary.project,
      "agent" => summary.agent_id,
      "session" => summary.session_id,
      "run" => summary.run_id,
      "type" => summary.event_type,
      "tool" => summary.tool_name,
      "status" => summary.status,
      "from" => DateTime.to_iso8601(occurred_at),
      "to" => DateTime.to_iso8601(occurred_at),
      "cursor" => "ignored-cursor",
      "limit" => "1"
    }

    assert Operations.notification_matches?(summary, all_filters)

    for filter <- ~w(stream project agent session run type tool status) do
      refute Operations.notification_matches?(summary, %{filter => "nonmatching"})
    end

    refute Operations.notification_matches?(summary, %{
             "from" => occurred_at |> DateTime.add(1, :second) |> DateTime.to_iso8601()
           })

    refute Operations.notification_matches?(summary, %{
             "to" => occurred_at |> DateTime.add(-1, :second) |> DateTime.to_iso8601()
           })

    assert Operations.notification_matches?(summary, %{
             "cursor" => "opaque",
             "limit" => "100"
           })
  end

  test "notification matching rejects malformed or unsafe summaries" do
    summary = %{
      id: Ecto.UUID.generate(),
      stream_id: "stream-1",
      event_type: "task.created",
      project: nil,
      agent_id: nil,
      session_id: nil,
      run_id: nil,
      tool_name: nil,
      status: nil,
      occurred_at: ~U[2026-07-17 04:05:06.000000Z]
    }

    refute Operations.notification_matches?(:not_a_map, %{})
    refute Operations.notification_matches?(Map.delete(summary, :id), %{})
    refute Operations.notification_matches?(%{summary | occurred_at: "not-a-datetime"}, %{})
    refute Operations.notification_matches?(string_keyed(summary), %{})
    refute Operations.notification_matches?(Map.put(summary, :unexpected, "value"), %{})
    refute Operations.notification_matches?(Map.put(summary, :content, "secret"), %{})
    refute Operations.notification_matches?(Map.put(summary, :payload, %{}), %{})
    refute Operations.notification_matches?(summary, :not_filters)
  end

  defp append!(attrs) do
    assert {:ok, event} = Store.append(attrs, telemetry: false)
    event
  end

  defp string_keyed(map) do
    Map.new(map, fn {key, value} -> {Atom.to_string(key), value} end)
  end

  defp unique(prefix) do
    "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
  end
end

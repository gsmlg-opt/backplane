defmodule Backplane.Memory.Projections.ActivityProjectorTest do
  use ExUnit.Case, async: true

  alias Backplane.Memory.Events.Event
  alias Backplane.Memory.Projections.ActivityProjector

  test "projects every durable counter by UTC date and canonical partition" do
    events = [
      event("memory.recalled", ~U[2026-08-12 23:59:59Z]),
      event("task.created", ~U[2026-08-13 00:00:00Z]),
      event("agent.tool.failed", ~U[2026-08-13 00:01:00Z], %{session_id: "other"}),
      event("agent.prompt.submitted", ~U[2026-08-13 00:02:00Z])
    ]

    rows = ActivityProjector.project(events)
    assert [first | _rest] = rows
    assert first["date"] == "2026-08-12"
    rows = Map.new(rows, &{&1["event_type"], &1})
    recall = rows["memory.recalled"]
    failed = rows["agent.tool.failed"]
    prompt = rows["agent.prompt.submitted"]
    action = rows["task.created"]

    assert recall == %{
             "date" => "2026-08-12",
             "project" => "/workspace/backplane",
             "agent_id" => "agent-1",
             "host_id" => "host-1",
             "client_id" => "client-1",
             "scope" => "scope:default",
             "namespace" => "private",
             "event_type" => "memory.recalled",
             "event_count" => 1,
             "session_count" => 1,
             "memory_count" => 0,
             "lesson_count" => 0,
             "crystal_count" => 0,
             "recall_count" => 1,
             "action_count" => 0,
             "error_count" => 0
           }

    assert failed["event_type"] == "agent.tool.failed"
    assert failed["event_count"] == 1
    assert failed["session_count"] == 1
    assert failed["error_count"] == 1
    assert zero_domain_counters(failed)

    assert prompt["event_type"] == "agent.prompt.submitted"
    assert prompt["session_count"] == 1
    assert zero_domain_counters(prompt)

    assert action["event_type"] == "task.created"
    assert action["action_count"] == 1
    assert action["memory_count"] == 0
  end

  test "classifies supported future canonical knowledge events and defaults unknown types to zero" do
    rows =
      [
        event("memory.created", ~U[2026-08-12 01:00:00Z]),
        event("lesson.created", ~U[2026-08-12 01:01:00Z]),
        event("crystal.created", ~U[2026-08-12 01:02:00Z]),
        event("action.completed", ~U[2026-08-12 01:03:00Z]),
        event("vendor.unknown", ~U[2026-08-12 01:04:00Z])
      ]
      |> ActivityProjector.project()
      |> Map.new(&{&1["event_type"], &1})

    assert rows["memory.created"]["memory_count"] == 1
    assert rows["lesson.created"]["lesson_count"] == 1
    assert rows["crystal.created"]["crystal_count"] == 1
    assert rows["action.completed"]["action_count"] == 1
    assert zero_domain_counters(rows["vendor.unknown"])
  end

  test "normalizes absent optional dimensions before aggregation" do
    first = event("memory.recalled", ~U[2026-08-12 01:00:00Z], %{project: nil, agent_id: nil})
    second = event("memory.recalled", ~U[2026-08-12 01:01:00Z], %{project: "", agent_id: ""})

    assert [row] = ActivityProjector.project([first, second])
    assert row["project"] == ""
    assert row["agent_id"] == ""
    assert row["event_count"] == 2
  end

  defp event(type, occurred_at, overrides \\ %{}) do
    struct!(
      Event,
      Map.merge(
        %{
          id: Ecto.UUID.generate(),
          host_id: "host-1",
          client_id: "client-1",
          scope: "scope:default",
          namespace: "private",
          session_id: "session-1",
          project: "/workspace/backplane",
          agent_id: "agent-1",
          event_type: type,
          source_sequence: 1,
          occurred_at: occurred_at,
          payload_hash: "sha256:fixture",
          payload: %{},
          schema_version: 1
        },
        overrides
      )
    )
  end

  defp zero_domain_counters(row) do
    Enum.all?(~w(memory_count lesson_count crystal_count recall_count action_count), fn key ->
      row[key] == 0
    end)
  end
end

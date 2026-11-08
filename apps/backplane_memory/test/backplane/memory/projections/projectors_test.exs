defmodule Backplane.Memory.Projections.ProjectorsTest do
  use ExUnit.Case, async: true

  alias Backplane.Memory.Events.Event

  alias Backplane.Memory.Projections.{
    Gaps,
    ObservationProjector,
    Revision,
    SessionProjector
  }

  test "observation projection is stable across shuffled input and maps nested Claude data" do
    events = [
      event(
        "00000000-0000-4000-8000-000000000005",
        5,
        "git.commit.created",
        ~U[2026-08-04 01:04:00Z],
        %{
          "source" => %{
            "commit_hash" => "abc123",
            "commit_message" => "fix projection ordering",
            "files" => ["lib/b.ex", "lib/a.ex"]
          }
        }
      ),
      event(
        "00000000-0000-4000-8000-000000000002",
        2,
        "agent.tool.failed",
        ~U[2026-08-04 01:01:00Z],
        %{
          "source" => %{
            "tool_name" => "Write",
            "tool_input" => %{"file_path" => "/workspace/lib/a.ex"},
            "error" => "permission denied"
          }
        }
      ),
      event(
        "00000000-0000-4000-8000-000000000001",
        1,
        "agent.prompt.submitted",
        ~U[2026-08-04 01:00:00Z],
        %{
          "source" => %{"prompt" => "implement projections"}
        }
      ),
      event(
        "00000000-0000-4000-8000-000000000003",
        3,
        "agent.tool.completed",
        ~U[2026-08-04 01:02:00Z],
        %{
          "source" => %{
            "tool_name" => "Read",
            "tool_input" => %{"file_path" => "/workspace/lib/b.ex"},
            "tool_response" => "file contents"
          }
        }
      ),
      event(
        "00000000-0000-4000-8000-000000000004",
        4,
        "conversation.agent_message",
        ~U[2026-08-04 01:03:00Z],
        %{
          "message" => "projection complete"
        }
      )
    ]

    expected = ObservationProjector.project(events)

    assert expected == ObservationProjector.project(Enum.reverse(events))
    assert expected == ObservationProjector.project(Enum.shuffle(events))
    assert {:ok, output_revision} = Revision.output_revision(expected)

    assert {:ok, ^output_revision} =
             events
             |> Enum.reverse()
             |> ObservationProjector.project()
             |> Revision.output_revision()

    assert %{
             "host_id" => "host-1",
             "session_id" => "session-1",
             "observations" => [prompt, failed_tool, completed_tool, message, commit]
           } = expected

    assert prompt["content"] == "implement projections"
    assert prompt["message"] == "implement projections"
    assert prompt["is_error"] == false

    assert failed_tool["tool_name"] == "Write"
    assert failed_tool["content"] == "permission denied"
    assert failed_tool["message"] == "permission denied"
    assert failed_tool["is_error"] == true
    assert failed_tool["file_paths"] == ["/workspace/lib/a.ex"]

    assert completed_tool["tool_name"] == "Read"
    assert completed_tool["content"] == "file contents"
    assert completed_tool["is_error"] == false
    assert completed_tool["file_paths"] == ["/workspace/lib/b.ex"]

    assert message["content"] == "projection complete"
    assert message["message"] == "projection complete"

    assert commit["content"] == "fix projection ordering"
    assert commit["message"] == "fix projection ordering"
    assert commit["file_paths"] == ["lib/a.ex", "lib/b.ex"]
    assert commit["commit_hash"] == "abc123"
  end

  test "stable source tie-breaks produce identical observations and input revisions" do
    first =
      event(
        "00000000-0000-4000-8000-000000000002",
        7,
        "agent.prompt.submitted",
        ~U[2026-08-04 01:00:00Z],
        %{
          "source" => %{"prompt" => "second by id"}
        }
      )

    second =
      event(
        "00000000-0000-4000-8000-000000000001",
        7,
        "agent.prompt.submitted",
        ~U[2026-08-04 01:00:00Z],
        %{
          "source" => %{"prompt" => "first by id"}
        }
      )

    assert %{"observations" => [one, two]} = ObservationProjector.project([first, second])
    assert Enum.map([one, two], & &1["event_id"]) == [second.id, first.id]

    assert Revision.input_revision([first, second]) == Revision.input_revision([second, first])
  end

  test "session projection derives lifecycle, counts, provenance, and supplied gaps" do
    events = [
      event(
        "00000000-0000-4000-8000-000000000005",
        5,
        "agent.session.ended",
        ~U[2026-08-04 01:05:00Z],
        %{
          "source" => %{"reason" => "complete"}
        }
      ),
      event(
        "00000000-0000-4000-8000-000000000003",
        3,
        "agent.tool.failed",
        ~U[2026-08-04 01:03:00Z],
        %{
          "source" => %{"tool_name" => "Bash", "error" => "exit 1"}
        }
      ),
      event(
        "00000000-0000-4000-8000-000000000001",
        1,
        "agent.session.started",
        ~U[2026-08-04 01:00:00Z],
        %{}
      ),
      event(
        "00000000-0000-4000-8000-000000000004",
        4,
        "agent.session.stopped",
        ~U[2026-08-04 01:04:00Z],
        %{}
      ),
      event(
        "00000000-0000-4000-8000-000000000002",
        2,
        "agent.tool.completed",
        ~U[2026-08-04 01:02:00Z],
        %{
          "source" => %{"tool_name" => "Bash", "tool_response" => "ok"}
        }
      )
    ]

    assert session = SessionProjector.project(events, [6])
    assert session == SessionProjector.project(Enum.reverse(events), [6])
    assert session["status"] == "completed"
    assert session["started_at"] == "2026-08-04T01:00:00Z"
    assert session["ended_at"] == "2026-08-04T01:05:00Z"
    assert session["project"] == "/workspace/backplane"
    assert session["agent_id"] == "claude-main"
    assert session["gaps"] == [6]
    assert session["counts"]["events"] == 5
    assert session["counts"]["tools"] == 2
    assert session["counts"]["errors"] == 1
    assert session["counts"]["by_tool"] == %{"Bash" => 2}
    assert session["counts"]["by_event_type"]["agent.session.started"] == 1

    assert session["source_event_ids"] ==
             events
             |> Enum.sort_by(&{&1.source_sequence, &1.event_type, &1.id})
             |> Enum.map(& &1.id)
  end

  test "stopped lifecycle is distinct from active and completed" do
    started =
      event(
        "00000000-0000-4000-8000-000000000001",
        1,
        "agent.session.started",
        ~U[2026-08-04 01:00:00Z],
        %{}
      )

    stopped =
      event(
        "00000000-0000-4000-8000-000000000002",
        2,
        "agent.session.stopped",
        ~U[2026-08-04 01:01:00Z],
        %{}
      )

    ended =
      event(
        "00000000-0000-4000-8000-000000000003",
        3,
        "agent.session.ended",
        ~U[2026-08-04 01:02:00Z],
        %{}
      )

    assert SessionProjector.project([started], [])["status"] == "active"
    assert SessionProjector.project([started, stopped], [])["status"] == "stopped"
    assert SessionProjector.project([started, stopped, ended], [])["status"] == "completed"

    assert SessionProjector.project([started, ended, %{stopped | source_sequence: 4}], [])[
             "status"
           ] == "stopped"
  end

  test "structured tool responses are retained as canonical observation content" do
    tool =
      event(
        "00000000-0000-4000-8000-000000000001",
        1,
        "agent.tool.completed",
        ~U[2026-08-04 01:00:00Z],
        %{"source" => %{"tool_name" => "Read", "tool_response" => %{"z" => 2, "a" => 1}}}
      )

    assert %{"observations" => [observation]} = ObservationProjector.project([tool])
    assert observation["content"] == ~s({"a":1,"z":2})
    assert observation["message"] == ~s({"a":1,"z":2})
  end

  test "gaps use distinct positive source sequences" do
    events = [
      event(
        "00000000-0000-4000-8000-000000000001",
        1,
        "agent.prompt.submitted",
        ~U[2026-08-04 01:00:00Z],
        %{}
      ),
      event(
        "00000000-0000-4000-8000-000000000002",
        3,
        "agent.tool.completed",
        ~U[2026-08-04 01:01:00Z],
        %{}
      ),
      event(
        "00000000-0000-4000-8000-000000000003",
        3,
        "agent.tool.failed",
        ~U[2026-08-04 01:02:00Z],
        %{}
      ),
      event(
        "00000000-0000-4000-8000-000000000004",
        5,
        "agent.session.ended",
        ~U[2026-08-04 01:03:00Z],
        %{}
      )
    ]

    assert Gaps.find(events) == [%{"from" => 2, "to" => 2}, %{"from" => 4, "to" => 4}]

    assert Gaps.find(Enum.reverse(events)) == [
             %{"from" => 2, "to" => 2},
             %{"from" => 4, "to" => 4}
           ]

    sparse = [
      event(
        "00000000-0000-4000-8000-000000000005",
        9_223_372_036_854_775_000,
        "agent.prompt.submitted",
        ~U[2026-08-04 01:04:00Z],
        %{}
      )
    ]

    assert Gaps.find(sparse) == [
             %{"from" => 1, "to" => 9_223_372_036_854_774_999}
           ]
  end

  defp event(id, sequence, type, occurred_at, payload, overrides \\ %{}) do
    struct!(
      Event,
      Map.merge(
        %{
          id: id,
          host_id: "host-1",
          session_id: "session-1",
          project: "/workspace/backplane",
          agent_id: "claude-main",
          event_type: type,
          source_sequence: sequence,
          occurred_at: occurred_at,
          payload_hash: "sha256:#{id}",
          payload: payload,
          schema_version: 1
        },
        overrides
      )
    )
  end
end

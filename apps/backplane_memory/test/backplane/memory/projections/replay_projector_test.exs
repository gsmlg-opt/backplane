defmodule Backplane.Memory.Projections.ReplayProjectorTest do
  use ExUnit.Case, async: true

  alias Backplane.Memory.Events.Event
  alias Backplane.Memory.Projections.ReplayProjector

  test "projects stable canonical replay kinds with privacy-filtered detail" do
    events = [
      event(3, "agent.tool.completed", %{
        "source" => %{
          "tool_name" => "Bash",
          "input" => %{"command" => "echo token=secret-value", "token" => "short-secret"},
          "result" => "password=secret-value"
        }
      }),
      event(1, "agent.prompt.submitted", %{
        "source" => %{"prompt" => "hello <private>hidden</private>"}
      }),
      event(2, "conversation.agent_message", %{"source" => %{"message" => "answer"}}),
      event(4, "git.commit.created", %{
        "source" => %{"commit_hash" => "abc123", "commit_message" => "done"}
      }),
      event(5, "agent.session.ended", %{})
    ]

    assert [prompt, response, result, commit, boundary] = ReplayProjector.project(events)

    assert Enum.map([prompt, response, result, commit, boundary], & &1["kind"]) ==
             ~w(prompt assistant_response agent_tool_result commit session_boundary)

    assert prompt["position"] == 1
    assert prompt["detail"]["content"] == "hello [REDACTED]"

    assert result["detail"]["tool_input"] == %{
             "command" => "echo [REDACTED]",
             "token" => "[REDACTED]"
           }

    assert result["detail"]["tool_output"] == "[REDACTED]"
    assert result["detail"]["tool_name"] == "Bash"
    assert commit["detail"]["commit_hash"] == "abc123"
  end

  test "native and imported canonical sessions produce identical replay kinds and order" do
    native = [
      event(1, "session.started", %{}),
      %{event(2, "conversation.user_message", %{}) | content: "same prompt"},
      event(3, "tool.call.completed", %{
        "source" => %{"tool_name" => "Read", "result" => "same result"}
      }),
      event(4, "tool.call.failed", %{
        "source" => %{"tool_name" => "Bash", "error" => "same error"}
      }),
      event(5, "git.commit.created", %{
        "source" => %{"commit_hash" => "abc123", "commit_message" => "same commit"}
      }),
      event(6, "session.ended", %{})
    ]

    imported = [
      imported_event(1, "agent.session.started", %{}),
      imported_event(2, "agent.prompt.submitted", %{
        "source" => %{"prompt" => "same prompt"}
      }),
      imported_event(3, "agent.tool.completed", %{
        "source" => %{"tool_name" => "Read", "tool_response" => "same result"}
      }),
      imported_event(4, "agent.tool.failed", %{
        "source" => %{"tool_name" => "Bash", "error" => "same error"}
      }),
      imported_event(5, "git.commit.created", %{
        "source" => %{"commit_hash" => "abc123", "commit_message" => "same commit"}
      }),
      imported_event(6, "agent.session.ended", %{})
    ]

    refute Enum.map(native, & &1.id) == Enum.map(imported, & &1.id)

    assert replay_shape(native) == replay_shape(imported)
    assert Enum.map(replay_shape(native), &elem(&1, 1)) == Enum.to_list(1..6)
  end

  test "maps canonical agent run lifecycle events to session boundaries" do
    assert Enum.map(
             ReplayProjector.project([
               event(1, "agent.run.started", %{}),
               event(2, "agent.run.completed", %{})
             ]),
             & &1["kind"]
           ) == ["session_boundary", "session_boundary"]
  end

  test "agent run failure emits an error followed by a terminal session boundary" do
    failed = event(1, "agent.run.failed", %{"source" => %{"error" => "boom"}})

    assert [error, terminal] = ReplayProjector.project([failed])
    assert {error["kind"], error["position"], error["event_id"]} == {"error", 1, failed.id}

    assert {terminal["kind"], terminal["position"], terminal["event_id"]} ==
             {"session_boundary", 2, failed.id}

    assert ReplayProjector.project([failed]) == [error, terminal]
  end

  defp event(sequence, type, payload) do
    %Event{
      id: Ecto.UUID.generate(),
      host_id: "host",
      client_id: "client",
      scope: "scope",
      namespace: "private",
      session_id: "session",
      source_sequence: sequence,
      event_type: type,
      occurred_at: DateTime.add(~U[2026-08-12 00:00:00Z], sequence),
      payload: payload,
      schema_version: 1
    }
  end

  defp imported_event(sequence, type, payload) do
    %{event(sequence, type, payload) | integration: "claude-jsonl"}
  end

  defp replay_shape(events) do
    events
    |> ReplayProjector.project()
    |> Enum.map(&{&1["kind"], &1["position"], &1["detail"]})
  end
end

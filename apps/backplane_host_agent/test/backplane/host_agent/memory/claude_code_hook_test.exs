defmodule Backplane.HostAgent.Memory.ClaudeCodeHookTest do
  use ExUnit.Case, async: true

  alias Backplane.HostAgent.Memory.Hooks.ClaudeCode

  @mappings %{
    "SessionStart" => "agent.session.started",
    "UserPromptSubmit" => "agent.prompt.submitted",
    "PostToolUse" => "agent.tool.completed",
    "PostToolUseFailure" => "agent.tool.failed",
    "PreCompact" => "agent.context.pre_compact",
    "SubagentStart" => "agent.subagent.started",
    "SubagentStop" => "agent.subagent.stopped",
    "Stop" => "agent.session.stopped",
    "SessionEnd" => "agent.session.ended",
    "PostCommit" => "git.commit.created"
  }

  test "normalizes all ten Claude Code hooks to canonical event types" do
    Enum.each(@mappings, fn {hook, event_type} ->
      input = fixture(hook)

      assert {:ok, envelope} = ClaudeCode.normalize(hook, input, %{host_id: "trusted-host"})
      assert envelope.host_id == "trusted-host"
      assert envelope.integration == "claude_code"
      assert envelope.event_type == event_type
      assert envelope.session_id == "session-1"
      assert envelope.agent_id == "claude-main"
      assert envelope.schema_version == 1
      assert envelope.payload["host_id"] == nil
      assert envelope.payload["source"]["source_event_id"] == "source-#{hook}"
    end)
  end

  test "derives stable event and idempotency identities from source identity" do
    input = fixture("PostToolUse")

    assert {:ok, first} = ClaudeCode.normalize("post-tool-use", input, %{host_id: "host-a"})
    assert {:ok, retried} = ClaudeCode.normalize("PostToolUse", input, %{host_id: "host-a"})

    assert first.event_id == retried.event_id

    assert first.event_id =~
             ~r/^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

    assert first.idempotency_key == retried.idempotency_key
    assert first.idempotency_key =~ "claude_code:session-1:post-tool-use:"
  end

  test "rejects unsupported hooks and malformed source payloads" do
    assert {:error, :unsupported_hook} =
             ClaudeCode.normalize("PermissionRequest", fixture("PermissionRequest"), %{
               host_id: "host"
             })

    assert {:error, {:malformed, [:session_id]}} =
             ClaudeCode.normalize("SessionStart", %{"source_event_id" => "source"}, %{
               host_id: "host"
             })

    assert {:error, {:malformed, [:payload]}} =
             ClaudeCode.normalize("SessionStart", [], %{host_id: "host"})
  end

  defp fixture(hook) do
    %{
      "session_id" => "session-1",
      "agent_id" => "claude-main",
      "host_id" => "caller-spoof",
      "source_event_id" => "source-#{hook}",
      "occurred_at" => "2026-08-04T01:00:00Z",
      "cwd" => "/workspace/backplane",
      "tool_use_id" => "tool-1",
      "tool_name" => "Bash",
      "prompt" => "fix the capture path",
      "agent_type" => "reviewer"
    }
  end
end

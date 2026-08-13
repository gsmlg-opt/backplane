defmodule Backplane.HostAgent.Memory.CodexHookTest do
  use ExUnit.Case, async: true

  alias Backplane.HostAgent.Memory.Hooks.Codex
  alias Backplane.HostAgent.Memory.Hooks

  @mappings %{
    "PreToolUse" => "codex.tool.pre_use.v1",
    "PermissionRequest" => "codex.permission.requested.v1",
    "PostToolUse" => "agent.tool.completed",
    "PreCompact" => "agent.context.pre_compact",
    "PostCompact" => "codex.context.post_compact.v1",
    "SessionStart" => "agent.session.started",
    "SessionEnd" => "agent.session.ended",
    "UserPromptSubmit" => "agent.prompt.submitted",
    "SubagentStart" => "agent.subagent.started",
    "SubagentStop" => "agent.subagent.stopped",
    "Stop" => "agent.session.stopped"
  }

  test "normalizes every hook exposed by the installed Codex 0.146 contract" do
    Enum.each(@mappings, fn {hook, event_type} ->
      assert {:ok, envelope} = Codex.normalize(hook, fixture(hook), %{host_id: "host-a"})
      assert envelope.host_id == "host-a"
      assert envelope.integration == "codex"
      assert envelope.client_id == "codex-cli"
      assert envelope.event_type == event_type
      assert envelope.session_id == "session-1"
      assert envelope.agent_id == "codex-main"
      assert envelope.payload["hook"] == canonical_hook(hook)
      refute Map.has_key?(envelope.payload["source"], "host_id")
    end)
  end

  test "uses Codex tool and turn identities for stable retry identities" do
    input = fixture("PostToolUse")

    assert {:ok, first} = Codex.normalize("post-tool-use", input, %{host_id: "host-a"})
    assert {:ok, retry} = Codex.normalize("PostToolUse", input, %{host_id: "host-a"})

    assert first.event_id == retry.event_id
    assert first.idempotency_key == retry.idempotency_key
    assert first.idempotency_key =~ "codex:session-1:post-tool-use:"
  end

  test "rejects events outside the installed contract and malformed payloads" do
    assert {:error, :unsupported_hook} =
             Codex.normalize("Notification", fixture("Notification"), %{host_id: "host-a"})

    assert {:error, {:malformed, [:session_id]}} =
             Codex.normalize("SessionStart", %{"cwd" => "/workspace"}, %{host_id: "host-a"})

    assert {:error, {:malformed, [:payload]}} =
             Codex.normalize("SessionStart", [], %{host_id: "host-a"})
  end

  test "publishes explicit runtime availability without claiming OpenCode support" do
    assert {:supported, Codex} = Hooks.availability("codex")

    assert %{status: :supported, adapter: Codex, hooks: hooks, hook_count: 11} =
             Hooks.inventory("codex")

    assert "Stop" in hooks
    assert length(hooks) == 11

    assert {:supported, Backplane.HostAgent.Memory.Hooks.ClaudeCode} =
             Hooks.availability("claude_code")

    assert {:unsupported, :local_hook_contract_unavailable} = Hooks.availability("opencode")
  end

  test "capture adapters normalize only and have no database or intelligence dependency" do
    hooks_dir = Path.expand("../../../../lib/backplane/host_agent/memory/hooks", __DIR__)

    for file <- ~w(claude_code.ex codex.ex) do
      source = File.read!(Path.join(hooks_dir, file))
      refute source =~ "Backplane.Repo"
      refute source =~ "Ecto."
      refute source =~ "Backplane.Memory.Service"
      refute source =~ "Oban"
    end
  end

  defp fixture(hook) do
    %{
      "hook_event_name" => hook,
      "session_id" => "session-1",
      "agent_id" => "codex-main",
      "host_id" => "caller-spoof",
      "cwd" => "/workspace/backplane",
      "model" => "gpt-5.6-codex",
      "permission_mode" => "default",
      "transcript_path" => nil,
      "turn_id" => "turn-1",
      "tool_use_id" => "tool-1",
      "tool_name" => "exec_command",
      "tool_input" => %{"cmd" => "mix test"},
      "tool_response" => %{"exit_code" => 0},
      "prompt" => "validate memory capture",
      "occurred_at" => "2026-08-12T01:00:00Z"
    }
  end

  defp canonical_hook(hook) do
    hook
    |> Macro.underscore()
    |> String.replace("_", "-")
  end
end

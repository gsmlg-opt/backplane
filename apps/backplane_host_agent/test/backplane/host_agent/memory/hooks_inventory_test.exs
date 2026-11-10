defmodule Backplane.HostAgent.Memory.HooksInventoryTest do
  use ExUnit.Case, async: false

  alias Backplane.HostAgent.Memory.Hooks
  alias Backplane.HostAgent.Memory.Hooks.ClaudeCode
  alias Backplane.HostAgent.Memory.Hooks.Codex
  alias Backplane.HostAgent.Memory.Hooks.Cursor

  test "inventory lists Claude Code and Cursor hooks" do
    assert %{status: :supported, adapter: ClaudeCode, hooks: hooks, hook_count: 9} =
             Hooks.inventory("claude_code")

    assert "PostToolUseFailure" in hooks

    assert %{status: :supported, adapter: Cursor, hooks: cursor_hooks, hook_count: 8} =
             Hooks.inventory("cursor")

    assert "beforeSubmitPrompt" in cursor_hooks
  end

  test "inventory loads a supported adapter before inspecting its exported hooks" do
    :code.purge(Codex)
    :code.delete(Codex)
    refute Code.loaded?(Codex)

    assert %{
             status: :supported,
             adapter: Codex,
             hooks: hooks,
             hook_count: 11
           } = Hooks.inventory("codex")

    assert Code.loaded?(Codex)
    assert "Stop" in hooks
  end
end

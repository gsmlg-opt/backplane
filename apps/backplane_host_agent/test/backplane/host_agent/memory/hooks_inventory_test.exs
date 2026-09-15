defmodule Backplane.HostAgent.Memory.HooksInventoryTest do
  use ExUnit.Case, async: false

  alias Backplane.HostAgent.Memory.Hooks
  alias Backplane.HostAgent.Memory.Hooks.ClaudeCode
  alias Backplane.HostAgent.Memory.Hooks.Codex

  test "inventory supports adapters without an optional hook inventory callback" do
    assert %{
             status: :supported,
             adapter: ClaudeCode,
             hooks: [],
             hook_count: 0
           } = Hooks.inventory("claude_code")
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

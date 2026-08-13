defmodule Backplane.HostAgent.Memory.HooksInventoryTest do
  use ExUnit.Case, async: false

  alias Backplane.HostAgent.Memory.Hooks
  alias Backplane.HostAgent.Memory.Hooks.Codex

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

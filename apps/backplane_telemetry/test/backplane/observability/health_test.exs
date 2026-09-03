defmodule Backplane.Observability.HealthTest do
  use ExUnit.Case, async: false

  alias Backplane.Observability

  test "health snapshot includes flags, settings, buffers, and writers" do
    health = Observability.health()

    assert is_map(health.flags)
    assert Map.has_key?(health, :settings)
    assert Map.has_key?(health, :runtime_sink)
    assert Map.has_key?(health, :buffers)
    assert %{llm: _, mcp: _, mcp_tool: _} = health.writers
  end
end

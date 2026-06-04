defmodule Backplane.Monitor.PlanTest do
  use ExUnit.Case, async: true

  alias Backplane.Monitor.Plan

  test "Claude Code is a supported monitor provider" do
    assert "claude_code" in Plan.providers()
    assert Plan.provider_label("claude_code") == "Claude Code"
    assert Plan.provider_supported?("claude_code")
  end
end

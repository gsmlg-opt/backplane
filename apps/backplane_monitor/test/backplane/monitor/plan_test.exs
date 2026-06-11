defmodule Backplane.Monitor.PlanTest do
  use ExUnit.Case, async: true

  alias Backplane.Monitor.Plan

  test "Claude Code is a supported monitor provider" do
    assert "claude_code" in Plan.providers()
    assert Plan.provider_label("claude_code") == "Claude Code"
    assert Plan.provider_supported?("claude_code")
  end

  test "OpenAI Codex is a supported monitor provider" do
    assert "openai_codex" in Plan.providers()
    assert Plan.provider_label("openai_codex") == "OpenAI Codex"
    assert Plan.provider_supported?("openai_codex")
  end

  test "Google Antigravity is a supported monitor provider" do
    assert "google_ai" in Plan.providers()
    assert Plan.provider_label("google_ai") == "Google Antigravity"
    assert Plan.provider_supported?("google_ai")
  end
end

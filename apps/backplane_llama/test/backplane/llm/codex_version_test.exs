defmodule Backplane.LLM.CodexVersionTest do
  use ExUnit.Case, async: false

  alias Backplane.LLM.CodexVersion

  test "parses the version emitted by the Codex CLI" do
    assert CodexVersion.parse_cli_output("codex-cli 0.156.0") == "0.156.0"
    assert CodexVersion.parse_cli_output("codex-cli 0.156.0\\n") == "0.156.0"
  end

  test "rejects output without a semantic version" do
    assert CodexVersion.parse_cli_output("codex-cli development") == nil
  end

  test "parses the OpenAI Codex GitHub release tag" do
    assert CodexVersion.parse_release(%{"tag_name" => "rust-v0.156.1"}) == "0.156.1"
    assert CodexVersion.parse_release(%{"name" => "0.156.1"}) == "0.156.1"
  end
end

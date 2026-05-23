defmodule BackplaneMemory.Privacy.FilterTest do
  use ExUnit.Case, async: true

  alias BackplaneMemory.Privacy.Filter

  describe "apply/1" do
    test "passes through normal content unchanged" do
      assert Filter.apply("The meeting is at 3pm.") == {:ok, "The meeting is at 3pm."}
    end

    test "strips <private> tagged content" do
      assert Filter.apply("<private>my secret</private>") == {:ok, "[REDACTED]"}
    end

    test "strips OpenAI/Anthropic-style API keys (sk- prefix)" do
      input = "Use key sk-1234567890abcdefABCDEFabcdef123456"
      {:ok, result} = Filter.apply(input)
      refute result =~ "sk-1234567890"
      assert result =~ "[REDACTED]"
    end

    test "strips AWS access key IDs (AKIA prefix)" do
      input = "AKIA1234567890ABCDEF is the key"
      {:ok, result} = Filter.apply(input)
      refute result =~ "AKIA1234567890ABCDEF"
      assert result =~ "[REDACTED]"
    end

    test "strips api_key assignment patterns" do
      input = ~s(api_key = "abcdefghijklmnopqrstuvwxyz12345")
      {:ok, result} = Filter.apply(input)
      refute result =~ "abcdefghijklmnopqrstuvwxyz12345"
      assert result =~ "[REDACTED]"
    end

    test "strips GitHub personal access tokens (ghp_ prefix)" do
      input = "token: ghp_abcdefghijklmnopqrstuvwxyz1234567890AB"
      {:ok, result} = Filter.apply(input)
      refute result =~ "ghp_"
      assert result =~ "[REDACTED]"
    end

    test "strips Authorization: Bearer header tokens" do
      input = "Authorization: Bearer eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.payload"
      {:ok, result} = Filter.apply(input)
      refute result =~ "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9"
      assert result =~ "[REDACTED]"
    end

    test "multi-line content: strips only the private block" do
      input = "Facts:\n<private>my password</private>\nMore facts."
      {:ok, result} = Filter.apply(input)
      assert result =~ "Facts:"
      assert result =~ "More facts."
      refute result =~ "my password"
    end
  end
end

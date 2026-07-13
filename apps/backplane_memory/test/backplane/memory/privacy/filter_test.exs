defmodule Backplane.Memory.Privacy.FilterTest do
  use ExUnit.Case, async: true

  alias Backplane.Memory.Privacy.Filter

  describe "apply/1" do
    test "redacts atom sensitive keys" do
      {:ok, e} =
        Filter.apply_event(%{
          stream_id: "s",
          event_type: "heartbeat.triggered",
          payload: %{password: "secret"}
        })

      assert e.payload.password == "[REDACTED]"
    end

    test "sanitizes sensitive keys recursively" do
      {:ok, e} =
        Filter.apply_event(%{
          "stream_id" => "s",
          "event_type" => "heartbeat.triggered",
          "content" => "ok",
          "payload" => %{"Authorization" => "secret", "nested" => %{"password" => "x"}}
        })

      assert e.payload["Authorization"] == "[REDACTED]"
      assert e.payload["nested"]["password"] == "[REDACTED]"
      assert is_binary(e.payload["_backplane"]["event_fingerprint"])
    end

    test "content truncation is grapheme and byte bounded" do
      {:ok, e} =
        Filter.apply_event(%{
          "stream_id" => "s",
          "event_type" => "heartbeat.triggered",
          "content" => String.duplicate("é", 40_000)
        })

      assert byte_size(e.content) <= 65_536
      assert e.payload["_backplane"]["content"]["truncated"]
    end

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

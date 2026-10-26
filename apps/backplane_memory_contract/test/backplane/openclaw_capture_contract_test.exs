defmodule Backplane.OpenClawCaptureContractTest do
  use ExUnit.Case, async: true
  alias Backplane.OpenClawCaptureContract, as: Contract

  defp message do
    content = "完整🦞 evidence"

    %{
      "protocol" => "openclaw_capture.v1",
      "event_id" => "2699493c-6347-4138-baba-8b09393a8500",
      "installation_id" => "b6b8672a-74a0-4df7-b533-ec0a99f49df8",
      "profile_id" => "primary",
      "source_sequence" => 1,
      "session_id" => "native-session",
      "session_key" => "agent:rikka:main",
      "run_id" => "native-run",
      "occurrence_id" => "native-run:0",
      "message_index" => 0,
      "agent_id" => "rikka",
      "binding_fingerprint" => String.duplicate("a", 64),
      "occurred_at" => "2026-10-26T01:00:00Z",
      "captured_at" => "2026-10-26T01:00:00Z",
      "role" => "user",
      "input_provenance" => %{"kind" => "external_user"},
      "content" => content,
      "completeness" => %{
        "truncated" => false,
        "coverage" => "full",
        "original_length" => length(String.codepoints(content)),
        "original_sha256" => Base.encode16(:crypto.hash(:sha256, content), case: :lower)
      }
    }
  end

  test "retains independently identified roles and actual session/run provenance" do
    for {role, type} <- [
          {"user", "conversation.user_message"},
          {"assistant", "conversation.agent_message"},
          {"tool", "agent.tool.completed"}
        ] do
      assert {:ok, ^type} = Contract.validate("message", %{message() | "role" => role})
    end
  end

  test "rejects unknown contracts, ownership, fabricated coverage and nonportable integers" do
    for invalid <- [
          Map.delete(message(), "session_id"),
          Map.delete(message(), "agent_id"),
          Map.delete(message(), "occurrence_id"),
          Map.put(message(), "protocol", "hermes_capture.v1"),
          Map.put(message(), "host_id", "attacker"),
          Map.put(message(), "scope", "private"),
          Map.put(message(), "source_sequence", 9_007_199_254_740_992),
          put_in(message(), ["completeness", "original_length"], 1),
          put_in(message(), ["completeness", "truncated"], true),
          put_in(message(), ["input_provenance", "scope"], "injected")
        ] do
      assert {:error, :invalid_capture} = Contract.validate("message", invalid)
    end
  end

  test "host redaction remains honest and requires trusted filtered validation" do
    redacted =
      message()
      |> Map.put("content", "[PRIVATE]")
      |> update_in(
        ["completeness"],
        &Map.merge(&1, %{
          "coverage" => "redacted",
          "retained_length" => 9,
          "retained_sha256" => Base.encode16(:crypto.hash(:sha256, "[PRIVATE]"), case: :lower)
        })
      )

    assert {:error, :invalid_capture} = Contract.validate("message", redacted)

    assert {:ok, "conversation.user_message"} =
             Contract.validate("message", redacted, filtered: true)
  end
end

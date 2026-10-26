defmodule Backplane.HostAgent.Memory.OpenClawHookTest do
  use ExUnit.Case, async: true
  alias Backplane.HostAgent.Memory.{Hooks, EventEnvelope}
  alias Backplane.HostAgent.Memory.Spool.Turso, as: Spool

  @moduletag :tmp_dir

  defp input(content \\ "real complete evidence") do
    %{
      "protocol" => "openclaw_capture.v1",
      "event_id" => "2699493c-6347-4138-baba-8b09393a8500",
      "installation_id" => "b6b8672a-74a0-4df7-b533-ec0a99f49df8",
      "profile_id" => "primary",
      "source_sequence" => 1,
      "session_id" => "real-session",
      "run_id" => "real-run",
      "agent_id" => "rikka",
      "occurrence_id" => "real-run:0",
      "binding_fingerprint" => String.duplicate("a", 64),
      "occurred_at" => "2026-10-26T01:00:00Z",
      "captured_at" => "2026-10-26T01:00:00Z",
      "role" => "user",
      "content" => content,
      "completeness" => %{
        "truncated" => false,
        "coverage" => "full",
        "original_length" => length(String.codepoints(content)),
        "original_sha256" => Base.encode16(:crypto.hash(:sha256, content), case: :lower)
      }
    }
  end

  test "normalizer keeps actual identities and distinct occurrences without pairing" do
    assert {:supported, Hooks.OpenClaw} = Hooks.availability("openclaw")
    assert {:ok, event} = Hooks.normalize("openclaw", "message", input(), %{host_id: "trusted"})
    assert event.host_id == "trusted"
    assert event.agent_id == "rikka"
    assert event.session_id == "real-session"
    assert event.payload["source"]["run_id"] == "real-run"
    assert event.integration == "openclaw"

    assert {:error, {:malformed, [:payload]}} =
             Hooks.normalize("openclaw", "message", Map.delete(input(), "session_id"), %{
               host_id: "trusted"
             })

    assert {:error, :unsupported_hook} =
             Hooks.normalize("openclaw", "pre-compress", input(), %{host_id: "trusted"})
  end

  test "immutable replay survives ACK retention and privacy coverage remains honest", %{
    tmp_dir: dir
  } do
    spool =
      start_supervised!(
        {Spool, database: Path.join(dir, "capture.db"), name: nil, id: make_ref()}
      )

    raw = input("private <private>hidden</private> sk-secretvalue")
    assert {:ok, event} = Hooks.normalize("openclaw", "message", raw, %{host_id: "trusted"})
    assert {:ok, retained} = Spool.append(spool, event)
    assert {:duplicate, ^retained} = Spool.append(spool, event)
    source = retained["payload"]["source"]
    refute source["content"] =~ "hidden"
    refute source["content"] =~ "sk-secretvalue"
    assert source["completeness"]["coverage"] == "redacted"
    assert source["completeness"]["original_sha256"] == raw["completeness"]["original_sha256"]

    assert {:ok, "conversation.user_message"} =
             Backplane.OpenClawCaptureContract.validate("message", source, filtered: true)

    assert {:ok, _} = EventEnvelope.validate(retained)
    assert :ok = Spool.acknowledge(spool, [event.event_id])
    assert {:duplicate, _} = Spool.append(spool, event)
    changed = input("changed immutable payload")

    assert {:ok, changed_event} =
             Hooks.normalize("openclaw", "message", changed, %{host_id: "trusted"})

    assert {:error, :identity_collision} = Spool.append(spool, changed_event)
    assert %{pending_depth: 0} = Spool.stats(spool)
  end
end

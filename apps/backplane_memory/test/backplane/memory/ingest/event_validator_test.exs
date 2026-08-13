defmodule Backplane.Memory.Ingest.EventValidatorTest do
  use ExUnit.Case, async: true

  alias Backplane.Memory.Ingest.EventValidator
  import Backplane.Memory.IngestFixtures

  test "validates and normalizes the canonical v1 envelope" do
    assert {:ok, envelope} = EventValidator.validate(valid_event())
    assert envelope["schema_version"] == 1
    assert %DateTime{} = envelope["occurred_at"]
    assert %DateTime{} = envelope["captured_at"]
  end

  test "accepts replayable Claude transcript message types" do
    for type <- ["conversation.user_message", "conversation.agent_message", "tool.call.started"] do
      assert {:ok, %{"event_type" => ^type}} =
               valid_event()
               |> Map.put("event_type", type)
               |> EventValidator.validate()
    end
  end

  test "classifies future schemas separately from malformed envelopes" do
    assert {:error, :unsupported_schema} =
             valid_event() |> Map.put("schema_version", 2) |> EventValidator.validate()

    for changed <- [
          Map.delete(valid_event(), "event_id"),
          Map.put(valid_event(), "event_id", "not-a-uuid"),
          Map.put(valid_event(), "sequence", 0),
          Map.put(valid_event(), "occurred_at", "yesterday"),
          Map.put(valid_event(), "privacy", []),
          Map.put(valid_event(), "payload", []),
          Map.put(valid_event(), "payload_hash", "sha256:wrong"),
          Map.put(valid_event(), "payload_hash", 42),
          Map.put(valid_event(), "importance", "high"),
          Map.put(valid_event(), "importance", 2_147_483_648),
          Map.put(valid_event(), "importance", -2_147_483_649),
          Map.put(valid_event(), "event_type", "agent.unknown"),
          Map.put(valid_event(), "event_type", "session.started"),
          put_in(valid_event(), ["trace", "correlation_id"], 42),
          put_in(valid_event(), ["trace", "causation_id"], "not-a-uuid")
        ] do
      assert {:error, {:invalid_event, errors}} = EventValidator.validate(changed)
      assert errors != []
    end
  end

  test "requires session identity and sequence only for session-bound events" do
    assert {:error, {:invalid_event, errors}} =
             valid_event() |> Map.delete("sequence") |> EventValidator.validate()

    assert :sequence in errors

    commit =
      valid_event()
      |> Map.put("event_type", "git.commit.created")
      |> Map.delete("session_id")
      |> Map.delete("sequence")

    assert {:ok, _} = EventValidator.validate(commit)
  end
end

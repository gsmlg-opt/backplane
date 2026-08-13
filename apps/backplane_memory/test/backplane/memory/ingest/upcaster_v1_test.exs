defmodule Backplane.Memory.Ingest.Upcaster.V1Test do
  use ExUnit.Case, async: true

  alias Backplane.Memory.Ingest.Upcaster.V1
  import Backplane.Memory.IngestFixtures

  test "maps the canonical envelope without collapsing its event type" do
    raw = valid_event()
    assert {:ok, event} = Backplane.Memory.Ingest.EventValidator.validate(raw)
    assert {:ok, attrs} = V1.upcast(event, %{host_id: "host-1", auth_token_id: "token-1"})

    assert attrs.id == raw["event_id"]
    assert attrs.stream_id == "capture:host-1:session-1"
    assert attrs.namespace == "private"
    refute Map.has_key?(attrs, :sequence)
    assert attrs.source_sequence == 1
    assert attrs.importance == 0
    assert attrs.event_type == "agent.prompt.submitted"
    assert attrs.idempotency_key == "capture:6:host-1:codex:session-1:1"
    assert attrs.raw_envelope["payload"] == raw["payload"]
    assert attrs.client_id == "host:host-1"
    assert attrs.raw_envelope["client_id"] == "host:host-1"
    assert attrs.ingest_auth_token_id == "token-1"
  end

  test "preserves optional canonical importance" do
    raw = valid_event(%{"importance" => 7})
    assert {:ok, event} = Backplane.Memory.Ingest.EventValidator.validate(raw)
    assert {:ok, attrs} = V1.upcast(event, %{host_id: "host-1", auth_token_id: "token-1"})
    assert attrs.importance == 7
  end

  test "host ownership survives token rotation and ignores the wire client id" do
    raw = valid_event(%{"client_id" => "host:attacker"})
    assert {:ok, event} = Backplane.Memory.Ingest.EventValidator.validate(raw)

    assert {:ok, first} = V1.upcast(event, %{host_id: "host-1", auth_token_id: "token-1"})
    assert {:ok, rotated} = V1.upcast(event, %{host_id: "host-1", auth_token_id: "token-2"})

    assert first.client_id == "host:host-1"
    assert rotated.client_id == first.client_id
    assert first.ingest_auth_token_id == "token-1"
    assert rotated.ingest_auth_token_id == "token-2"
    refute first.raw_envelope["client_id"] == "host:attacker"
  end

  test "host namespaces cannot collide through delimiter ambiguity" do
    first = valid_event(%{"host_id" => "a:b", "idempotency_key" => "c"})
    second = valid_event(%{"host_id" => "a", "idempotency_key" => "b:c"})

    assert {:ok, first} = Backplane.Memory.Ingest.EventValidator.validate(first)
    assert {:ok, second} = Backplane.Memory.Ingest.EventValidator.validate(second)
    assert {:ok, first_attrs} = V1.upcast(first, %{host_id: "a:b", auth_token_id: "token-1"})
    assert {:ok, second_attrs} = V1.upcast(second, %{host_id: "a", auth_token_id: "token-2"})
    refute first_attrs.idempotency_key == second_attrs.idempotency_key
  end
end

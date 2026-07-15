defmodule Backplane.Memory.EventsTest do
  use ExUnit.Case, async: true

  alias Backplane.Memory.Events

  test "append normalizes, sanitizes, and returns an Event struct" do
    assert {:ok, event} =
             Events.append(%{
               "event_type" => "legacy.observation",
               "session_id" => "s1",
               "content" => "hello"
             })

    assert %Backplane.Memory.Events.Event{} = event
    assert event.stream_id == "session:s1"
    assert event.content == "hello"
  end

  test "append returns a recursively sanitized and bounded Event" do
    raw_secret = "persisted-event-raw-sentinel"

    assert {:ok, event} =
             Events.append(%{
               stream_id: "s",
               event_type: "tool.call.failed",
               idempotency_key: "tool-use-1",
               content: "<private>#{raw_secret}</private>",
               payload: %{
                 "blob" => String.duplicate("x", 270_000),
                 "error" => "password=#{raw_secret}"
               }
             })

    assert %Backplane.Memory.Events.Event{} = event
    assert event.content == "[REDACTED]"
    assert byte_size(Jason.encode!(event.payload)) <= 262_144
    assert event.payload["_backplane"]["payload"]["truncated"]
    assert is_binary(event.payload["_backplane"]["event_fingerprint"])
    refute Jason.encode!(event.payload) =~ raw_secret
    refute inspect(event) =~ raw_secret
  end

  test "append redacts camel-case sensitive keys and nested header pair arrays" do
    raw_secret = "short-raw-sentinel"

    assert {:ok, event} =
             Events.append(%{
               stream_id: "s",
               event_type: "tool.call.completed",
               payload: %{
                 "apiKey" => raw_secret,
                 "accessToken" => raw_secret,
                 "AWSSecretAccessKey" => raw_secret,
                 "setCookie" => raw_secret,
                 "nested" => %{
                   "headers" => [
                     ["Authorization", "Bearer #{raw_secret}"],
                     ["X-Api-Key", raw_secret],
                     ["Content-Type", "application/json"]
                   ],
                   "environment" => [["databasePassword", raw_secret]]
                 }
               }
             })

    encoded = Jason.encode!(event.payload)
    refute encoded =~ raw_secret
    assert encoded =~ "[REDACTED]"

    assert get_in(event.payload, ["nested", "headers", Access.at(2)]) == [
             "Content-Type",
             "application/json"
           ]
  end

  test "append redacts values when sensitive keys themselves contain assignments" do
    embedded_key_secret = "embedded-key-secret"
    associated_value_secret = "associated-value-raw-sentinel"

    assert {:ok, event} =
             Events.append(%{
               stream_id: "s",
               event_type: "tool.call.completed",
               payload: %{
                 "password=#{embedded_key_secret}" => associated_value_secret,
                 "pairs" => [
                   ["accessToken=#{embedded_key_secret}", associated_value_secret]
                 ]
               }
             })

    encoded = Jason.encode!(event.payload)
    refute encoded =~ embedded_key_secret
    refute encoded =~ associated_value_secret
    assert event.payload["[REDACTED]"] == "[REDACTED]"
    assert event.payload["pairs"] == [["[REDACTED]", "[REDACTED]"]]
  end

  test "append rejects invalid UTF-8 content and nested payload strings without raising" do
    invalid = <<255>>

    for attrs <- [
          %{content: invalid},
          %{payload: %{"nested" => [invalid]}},
          %{payload: %{"nested" => %{invalid => "value"}}}
        ] do
      assert {:error, :invalid_utf8} =
               Events.append(
                 Map.merge(
                   %{stream_id: "s", event_type: "tool.call.completed"},
                   attrs
                 )
               )
    end
  end

  test "append rejects invalid attributes before persistence" do
    assert {:error, :missing_identity} = Events.append(%{event_type: "legacy.observation"})

    assert {:error, :invalid_payload} =
             Events.append(%{stream_id: "s", event_type: "legacy.observation", payload: []})

    assert {:error, :missing_identity} =
             Events.append(%{
               stream_id: nil,
               session_id: "session",
               event_type: "legacy.observation"
             })

    assert {:error, :invalid_uuid} =
             Events.append(%{stream_id: "s", event_type: "legacy.observation", id: "bad"})

    assert {:error, :invalid_uuid} =
             Events.append(%{
               stream_id: "s",
               event_type: "legacy.observation",
               causation_id: "bad"
             })
  end

  test "append_batch preserves order and stops at the first invalid item" do
    assert {:ok, [first, second]} =
             Events.append_batch([
               %{stream_id: "s", event_type: "task.created", content: "one"},
               %{stream_id: "s", event_type: "task.updated", content: "two"}
             ])

    assert [first.event_type, second.event_type] == ["task.created", "task.updated"]

    assert {:error, :missing_identity} =
             Events.append_batch([
               %{stream_id: "s", event_type: "task.created"},
               %{event_type: "task.updated"}
             ])
  end
end

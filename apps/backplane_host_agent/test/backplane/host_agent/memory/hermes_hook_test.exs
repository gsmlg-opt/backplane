defmodule Backplane.HostAgent.Memory.HermesHookTest do
  use ExUnit.Case, async: true
  alias Backplane.HostAgent.Memory.Hooks
  alias Backplane.HostAgent.Memory.Hooks.Hermes

  defp input do
    %{
      "protocol" => "hermes_capture.v1",
      "event_id" => "2699493c-6347-4138-baba-8b09393a8500",
      "installation_id" => "b6b8672a-74a0-4df7-b533-ec0a99f49df8",
      "profile_id" => "primary",
      "source_sequence" => 1,
      "session_id" => "actual-session",
      "occurred_at" => "2026-10-24T01:00:00Z",
      "captured_at" => "2026-10-24T01:00:00Z"
    }
  end

  test "Hermes lifecycle and role map to existing canonical event types" do
    assert {:supported, Hermes} = Hooks.availability("hermes")

    for {hook, type} <- [
          {"session-start", "agent.session.started"},
          {"session-end", "agent.session.ended"},
          {"pre-compress", "agent.context.pre_compact"}
        ] do
      assert {:ok, envelope} =
               Hooks.normalize("hermes", hook, input(), %{host_id: "trusted-host"})

      assert envelope.event_type == type
      assert envelope.event_id == input()["event_id"]
      assert envelope.host_id == "trusted-host"
    end

    for {role, type} <- [
          {"user", "conversation.user_message"},
          {"assistant", "conversation.agent_message"},
          {"tool", "agent.tool.completed"}
        ] do
      message =
        Map.merge(input(), %{
          "role" => role,
          "content" => "real complete evidence",
          "agent_id" => "Rikka",
          "message_uid" => "native-uid",
          "source_revision" => 2,
          "parent_session_id" => "parent",
          "author" => %{"name" => "actual user"}
        })

      assert {:ok, envelope} =
               Hooks.normalize("hermes", "message", message, %{host_id: "trusted-host"})

      assert envelope.event_type == type
      assert envelope.agent_id == "Rikka"
      assert envelope.parent_session_id == "parent"
      assert envelope.payload["source"] == message
      assert envelope.payload["source"]["role"] == role
    end
  end

  test "unknown protocol ownership injection and incomplete truncation fail closed" do
    message = Map.merge(input(), %{"role" => "user", "content" => "evidence"})

    for invalid <- [
          Map.put(message, "protocol", "invented.v1"),
          Map.put(message, "host_id", "attacker"),
          Map.put(message, "scope", "another-partition"),
          Map.put(message, "role", "system"),
          Map.put(message, "source_sequence", 0),
          Map.put(message, "completeness", %{"truncated" => true})
        ] do
      assert {:error, {:malformed, _}} =
               Hooks.normalize("hermes", "message", invalid, %{host_id: "trusted-host"})
    end

    assert {:error, :unsupported_hook} =
             Hooks.normalize("hermes", "invented", input(), %{host_id: "trusted-host"})
  end
end

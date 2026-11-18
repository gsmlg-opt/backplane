defmodule Backplane.HostAgent.Memory.SynapsisHookTest do
  use ExUnit.Case, async: true

  alias Backplane.HostAgent.Memory.Hooks
  alias Backplane.HostAgent.Memory.Hooks.Synapsis

  test "inventory and normalization expose all four versioned lifecycle hooks" do
    assert %{status: :supported, adapter: Synapsis, hook_count: 4, hooks: hooks} =
             Hooks.inventory("synapsis")

    assert Enum.sort(hooks) ==
             Enum.sort(~w(session-start user-prompt-submit post-tool-use session-end))

    for {hook, payload, event_type} <- events() do
      source = source(payload)

      assert {:ok, envelope} =
               Hooks.normalize("synapsis", hook, source, %{host_id: "trusted-host"})

      assert envelope.event_type == event_type
      assert envelope.event_id == source["event_id"]
      assert envelope.session_id == source["session_id"]
      assert envelope.project == source["cwd"]
      assert envelope.occurred_at == source["timestamp"]
      assert envelope.agent_id == "Rikka"
      assert envelope.host_id == "trusted-host"
      assert envelope.client_id == "synapsis"
      assert envelope.payload == %{"hook" => hook, "source" => source}

      assert {:ok, ^envelope} =
               Hooks.normalize("synapsis", hook, source, %{host_id: "trusted-host"})
    end
  end

  test "version identity timestamp and hook payload bounds are enforced" do
    valid = source(%{"message_id" => "accepted-input", "content" => "capture this turn"})

    for invalid <- [
          Map.put(valid, "schema_version", "2.0"),
          Map.put(valid, "event_id", "unstable"),
          Map.put(valid, "session_id", "missing-durable-session"),
          Map.put(valid, "cwd", "relative/project"),
          Map.put(valid, "timestamp", "2026-11-19T09:00:00+01:00"),
          Map.put(valid, "host_id", "another-host"),
          Map.put(valid, "payload", %{"content" => "missing message identity"}),
          put_in(valid, ["payload", "content"], String.duplicate("x", 262_145))
        ] do
      assert {:error, {:malformed, [:payload]}} =
               Hooks.normalize("synapsis", "user-prompt-submit", invalid, %{
                 host_id: "trusted-host"
               })
    end

    assert {:error, :unsupported_hook} =
             Hooks.normalize("synapsis", "stop", valid, %{host_id: "trusted-host"})

    oversized_result =
      source(%{
        "tool_call_id" => "native-call",
        "tool_name" => "read_file",
        "is_error" => false,
        "result" => String.duplicate("x", 480_000)
      })

    assert {:error, {:malformed, [:payload]}} =
             Hooks.normalize("synapsis", "post-tool-use", oversized_result, %{
               host_id: "trusted-host"
             })
  end

  defp source(payload) do
    %{
      "schema_version" => "1.0",
      "event_id" => "2c330d38-f351-4aa6-9c77-3914f3e93c20",
      "session_id" => "a214a528-03cf-4338-b184-851bd5f94cd2",
      "cwd" => "/workspace/backplane",
      "timestamp" => "2026-11-19T08:00:00Z",
      "agent_id" => "Rikka",
      "payload" => payload
    }
  end

  defp events do
    [
      {"session-start", %{}, "agent.session.started"},
      {"user-prompt-submit", %{"message_id" => "message-1", "content" => "capture this turn"},
       "agent.prompt.submitted"},
      {"post-tool-use",
       %{
         "tool_call_id" => "tool-1",
         "tool_name" => "read_file",
         "is_error" => false,
         "result" => %{"content" => "public tool result"}
       }, "agent.tool.completed"},
      {"session-end", %{"reason" => "normal"}, "agent.session.ended"}
    ]
  end
end

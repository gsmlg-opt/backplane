defmodule Backplane.HostAgent.Memory.CursorHookTest do
  use ExUnit.Case, async: true

  alias Backplane.HostAgent.Memory.Hooks
  alias Backplane.HostAgent.Memory.Hooks.Cursor

  @config %{host_id: "host-a"}

  @mappings %{
    "sessionStart" => "agent.session.started",
    "beforeSubmitPrompt" => "agent.prompt.submitted",
    "postToolUse" => "agent.tool.completed",
    "afterShellExecution" => "agent.tool.completed",
    "afterFileEdit" => "agent.tool.completed",
    "afterAgentResponse" => "conversation.agent_message",
    "stop" => "agent.session.stopped",
    "sessionEnd" => "agent.session.ended"
  }

  test "maps every Cursor hook to its canonical event type" do
    Enum.each(@mappings, fn {hook, event_type} ->
      assert {:ok, envelope} = Cursor.normalize(hook, fixture(), @config)
      assert envelope.event_type == event_type
      assert envelope.integration == "cursor"
      assert envelope.client_id == "cursor"
      assert envelope.agent_id == "cursor"
      assert envelope.host_id == "host-a"
      assert envelope.session_id == "conv-1"
      assert envelope.project == "/w/a"
      assert envelope.payload["source"]["conversation_id"] == "conv-1"
      assert envelope.idempotency_key =~ "cursor:conv-1:"
    end)
  end

  test "requires conversation_id" do
    assert {:error, {:malformed, [:conversation_id]}} =
             Cursor.normalize("stop", Map.delete(fixture(), "conversation_id"), @config)

    assert {:error, {:malformed, [:payload]}} = Cursor.normalize("stop", [], @config)
    assert {:error, :unsupported_hook} = Cursor.normalize("preToolUse", fixture(), @config)
  end

  test "uses the first workspace root as project and scope" do
    assert {:ok, envelope} = Cursor.normalize("stop", fixture(), @config)
    assert envelope.project == "/w/a"
    assert envelope.scope == "project:/w/a"
  end

  test "resolves camelCase, kebab and lower-case hook names" do
    keys =
      for name <- ["beforeSubmitPrompt", "before-submit-prompt", "beforesubmitprompt"] do
        assert {:ok, envelope} = Cursor.normalize(name, fixture(), @config)
        assert envelope.event_type == "agent.prompt.submitted"
        assert envelope.payload["hook"] == "before-submit-prompt"
        envelope.event_id
      end

    assert length(Enum.uniq(keys)) == 1
  end

  test "retries are idempotent and distinct tool calls in one generation differ" do
    assert {:ok, a} = Cursor.normalize("afterShellExecution", fixture(), @config)
    assert {:ok, b} = Cursor.normalize("afterShellExecution", fixture(), @config)
    assert a.event_id == b.event_id

    other = Map.put(fixture(), "command", "ls")
    assert {:ok, c} = Cursor.normalize("afterShellExecution", other, @config)
    refute c.event_id == a.event_id
  end

  test "exposes Cursor text fields under the conventional projector keys" do
    assert {:ok, %{payload: %{"source" => source}}} =
             Cursor.normalize("afterAgentResponse", fixture(), @config)

    assert source["message"] == "agent said hi"
    assert source["text"] == "agent said hi"

    assert {:ok, %{payload: %{"source" => shell}}} =
             Cursor.normalize("afterShellExecution", fixture(), @config)

    assert shell["tool_name"] == "Shell"
    assert shell["tool_response"] == "file1"

    assert {:ok, %{payload: %{"source" => edit}}} =
             Cursor.normalize("afterFileEdit", fixture(), @config)

    assert edit["tool_name"] == "Edit"
  end

  test "publishes availability and inventory" do
    assert {:supported, Cursor} = Hooks.availability("cursor")
    assert %{hook_count: 8} = Hooks.inventory("cursor")
    assert {:ok, %{integration: "cursor"}} = Hooks.normalize("cursor", "stop", fixture(), @config)
  end

  test "drops caller-supplied host_id and user_email from the source payload" do
    input = Map.merge(fixture(), %{"host_id" => "spoof", "user_email" => "me@example.test"})

    for hook <- Map.keys(@mappings) do
      assert {:ok, envelope} = Cursor.normalize(hook, input, @config)
      refute Map.has_key?(envelope.payload["source"], "host_id")
      refute Map.has_key?(envelope.payload["source"], "user_email")
      assert envelope.payload["source"]["conversation_id"] == "conv-1"
    end
  end

  defp fixture do
    %{
      "conversation_id" => "conv-1",
      "generation_id" => "gen-1",
      "workspace_roots" => ["/w/a", "/w/b"],
      "model" => "gpt",
      "prompt" => "hello",
      "text" => "agent said hi",
      "command" => "echo",
      "output" => "file1",
      "file_path" => "/w/a/x.ex",
      "occurred_at" => "2026-08-04T01:00:00Z"
    }
  end
end

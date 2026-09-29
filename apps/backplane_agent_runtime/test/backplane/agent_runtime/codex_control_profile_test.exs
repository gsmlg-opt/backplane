defmodule Backplane.AgentRuntime.CodexControlProfileTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{Codex, Conversation, EphemeralStore}

  defmodule Provider do
    def stream(request, context) do
      send(context.test, {:provider, request, self()})

      Stream.resource(
        fn -> nil end,
        fn state ->
          receive do
            {:events, events} -> {events, state}
          end
        end,
        fn _ -> :ok end
      )
    end
  end

  defp start_conversation(run_id, tools, context, test_pid) do
    authority = %{
      caller: "host",
      run_id: run_id,
      grants: tools,
      tool_revisions: Map.new(tools, &{&1, 1})
    }

    assert {:ok, profile} =
             Codex.profile(:interactive, context, authority, tools: tools)

    {:ok, store} = EphemeralStore.new(1)

    Conversation.start_link(
      run_id: run_id,
      store: EphemeralStore,
      context: store,
      provider: Provider,
      provider_context: %{test: test_pid},
      subscriber: test_pid,
      registry: profile.registry,
      tools: profile.tools,
      authority: profile.authority,
      schema_admission: :strict,
      work: 20,
      run_timeout: 5_000
    )
  end

  test "request_user_input uses the correlated Conversation interaction" do
    {:ok, conversation} =
      start_conversation("control-input", ["request_user_input"], %{root?: true}, self())

    assert {:ok, _} = Conversation.prompt(conversation, "ask")
    assert_receive {:provider, _, provider}

    send(provider, {
      :events,
      [
        %{
          type: :tool_call_completed,
          tool_call: %{
            id: "question-1",
            name: "request_user_input",
            arguments: %{
              "questions" => [
                %{
                  "id" => "target",
                  "header" => "Target",
                  "question" => "Where should this run?",
                  "options" => [
                    %{"label" => "Local (Recommended)", "description" => "Use local execution."},
                    %{"label" => "Remote", "description" => "Use the remote environment."}
                  ]
                }
              ]
            }
          }
        },
        %{type: :response_completed, message: %{role: :assistant, content: "asking"}}
      ]
    })

    assert_receive {:agent_runtime, "control-input",
                    %{
                      type: :interaction_requested,
                      interaction_id: interaction_id,
                      request: %{kind: :request_user_input}
                    }}

    answer = %{"answers" => %{"target" => %{"answers" => ["Local (Recommended)"]}}}
    assert :ok = Conversation.resolve(conversation, interaction_id, answer)

    assert_receive {:provider, %{messages: messages}, final_provider}

    assert %{name: "request_user_input", result: %{is_error: false} = result} =
             List.last(messages)

    assert result.answers == answer["answers"]

    send(final_provider, {
      :events,
      [%{type: :response_completed, message: %{role: :assistant, content: "done"}}]
    })

    assert_receive {:agent_runtime, "control-input", %{type: :run_completed}}
  end

  test "request_permissions applies only the host-resolved grant" do
    parent = self()

    grant = fn request, response ->
      send(parent, {:granted, request, response})
      {:ok, %{status: :applied}}
    end

    {:ok, conversation} =
      start_conversation(
        "control-permission",
        ["request_permissions"],
        %{root?: true, grant_permissions: grant},
        self()
      )

    assert {:ok, _} = Conversation.prompt(conversation, "grant")
    assert_receive {:provider, _, provider}

    arguments = %{
      "reason" => "read fixture",
      "permissions" => %{"file_system" => %{"read" => ["/tmp/fixture"]}}
    }

    send(provider, {
      :events,
      [
        %{
          type: :tool_call_completed,
          tool_call: %{id: "permission-1", name: "request_permissions", arguments: arguments}
        },
        %{type: :response_completed, message: %{role: :assistant, content: "requesting"}}
      ]
    })

    assert_receive {:agent_runtime, "control-permission",
                    %{type: :interaction_requested, interaction_id: interaction_id}}

    response = %{
      "permissions" => %{"file_system" => %{"read" => ["/tmp/fixture"]}},
      "scope" => "turn"
    }

    assert :ok = Conversation.resolve(conversation, interaction_id, response)
    assert_receive {:granted, ^arguments, ^response}
    assert_receive {:provider, _, final_provider}

    send(final_provider, {
      :events,
      [%{type: :response_completed, message: %{role: :assistant, content: "done"}}]
    })

    assert_receive {:agent_runtime, "control-permission", %{type: :run_completed}}
  end

  test "new_context starts the next provider request without prior conversation messages" do
    {:ok, conversation} =
      start_conversation("control-context", ["new_context"], %{root?: true}, self())

    assert {:ok, _} = Conversation.prompt(conversation, "old context")
    assert_receive {:provider, %{messages: initial_messages}, provider}
    assert Enum.any?(initial_messages, &(&1[:content] == "old context"))

    send(provider, {
      :events,
      [
        %{
          type: :tool_call_completed,
          tool_call: %{id: "context-1", name: "new_context", arguments: %{}}
        },
        %{type: :response_completed, message: %{role: :assistant, content: "rolling over"}}
      ]
    })

    assert_receive {:agent_runtime, "control-context", %{type: :context_window_started}}
    assert_receive {:provider, %{messages: []}, final_provider}

    send(final_provider, {
      :events,
      [%{type: :response_completed, message: %{role: :assistant, content: "done"}}]
    })

    assert_receive {:agent_runtime, "control-context", %{type: :run_completed}}
  end

  test "async messages acknowledge immediately and environment waits use the host provider" do
    parent = self()

    environment_provider = fn environment_id ->
      send(parent, {:environment_checked, environment_id})
      %{ready: true, authorized: true, environment_id: environment_id}
    end

    context = %{root?: true, environment_provider: environment_provider}
    tools = ["send_message_to_user_async", "wait_for_environment"]
    {:ok, conversation} = start_conversation("control-async", tools, context, self())

    assert {:ok, _} = Conversation.prompt(conversation, "notify")
    assert_receive {:provider, _, provider}

    send(provider, {
      :events,
      [
        %{
          type: :tool_call_completed,
          tool_call: %{
            id: "message-1",
            name: "send_message_to_user_async",
            arguments: %{"message" => "Need attention"}
          }
        },
        %{
          type: :tool_call_completed,
          tool_call: %{
            id: "wait-1",
            name: "wait_for_environment",
            arguments: %{"environment_id" => "env-1"}
          }
        },
        %{type: :response_completed, message: %{role: :assistant, content: "working"}}
      ]
    })

    assert_receive {:agent_runtime, "control-async",
                    %{type: :async_user_message, message: "Need attention"}}

    assert_receive {:environment_checked, "env-1"}
    assert_receive {:provider, %{messages: messages}, final_provider}
    assert %{name: "wait_for_environment", result: %{status: "ready"}} = List.last(messages)

    send(final_provider, {
      :events,
      [%{type: :response_completed, message: %{role: :assistant, content: "done"}}]
    })

    assert_receive {:agent_runtime, "control-async", %{type: :run_completed}}
  end
end

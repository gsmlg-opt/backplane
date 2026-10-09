defmodule Backplane.AgentRuntime.ProviderOutputTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{Error, Execution, ProviderOutput, ToolEffects}

  defmodule Adapter do
    def start(operation) do
      send(operation.provider_context.test, :provider_started)
      {:ok, operation.response}
    end

    def execute(operation) do
      send(operation.backend_context.test, :tool_started)
      {:ok, operation.response}
    end
  end

  defp prepared(effect, response) do
    %{
      effect: effect,
      adapter: Adapter,
      operation: %{response: response},
      host_context: %{test: self()}
    }
  end

  test "non-stream providers support infinity and finite content diagnostics" do
    text = String.duplicate("x", 1_048_577)

    assert {:ok, [%{text: ^text}]} =
             Execution.dispatch(prepared(:provider, %{text: text}),
               provider_output_limit: :infinity,
               output_limit: 0
             )

    assert {:error, %Error{details: %{scope: :provider_response, limit: 3, size: 4}}} =
             Execution.dispatch(
               prepared(:provider, %{message: %{role: :assistant, content: "four"}}),
               provider_output_limit: 3
             )

    assert {:ok, [%{text: "four"}]} =
             Execution.dispatch(prepared(:provider, %{text: "four", usage: %{tokens: 30}}),
               provider_output_limit: 4
             )
  end

  test "invalid output options are rejected before adapter side effects" do
    for key <- [:provider_output_limit, :output_limit], value <- [nil, :bad, -1, 1.5] do
      assert {:error, %Error{class: :validation}} =
               Execution.dispatch(prepared(:provider, %{text: "ok"}), [{key, value}])

      refute_receive :provider_started
    end

    assert {:error, %Error{class: :validation}} =
             Execution.dispatch(prepared(:tool, %{text: "ok"}), output_limit: :infinity)

    refute_receive :tool_started
  end

  test "direct tool output limits cannot be disabled with atoms" do
    for value <- [nil, :infinity, :unlimited, -1, 1.5] do
      assert {:error, %Error{class: :validation}} =
               ToolEffects.validate_output(%{payload: %{text: "ok"}}, limit: value)
    end

    assert {:error, %Error{class: :resource_conflict}} =
             ToolEffects.validate_output(%{payload: %{text: "ok"}}, limit: 0)
  end

  test "partial tool snapshots without IDs preserve distinct indexed content" do
    message = %{
      content: [
        %{type: :tool_call, id: nil, partial_json: "abc"},
        %{type: :tool_call, id: nil, partial_json: "defg"}
      ]
    }

    state = ProviderOutput.event(ProviderOutput.new(), %{type: :usage_updated, message: message})
    assert {:ok, _} = ProviderOutput.check(state, 7)
    assert {:error, %Error{details: %{size: 7}}} = ProviderOutput.check(state, 6)
  end

  test "materializing tool IDs merges partial snapshots and deltas" do
    state =
      ProviderOutput.new()
      |> ProviderOutput.event(%{
        type: :tool_call_arguments_delta,
        index: 2,
        delta: "ab",
        message: %{
          content: [
            %{type: :text, text: "x"},
            %{type: :thinking, thinking: "y"},
            %{type: :tool_call, id: nil, partial_json: "ab"}
          ]
        }
      })
      |> ProviderOutput.event(%{type: :tool_call_arguments_delta, index: 2, delta: "cd"})
      |> ProviderOutput.event(%{
        type: :tool_call_completed,
        index: 2,
        tool_call: %{id: "tool", arguments: "abcd"}
      })
      |> ProviderOutput.event(%{
        type: :response_completed,
        message: %{
          content: [
            %{type: :text, text: "x"},
            %{type: :thinking, thinking: "y"},
            %{type: :tool_call, id: "tool", arguments: "abcd"}
          ]
        }
      })

    assert {:ok, _} = ProviderOutput.check(state, 6)
    assert {:error, %Error{details: %{size: 6}}} = ProviderOutput.check(state, 5)
  end

  test "custom arguments and separately indexed text blocks count generated UTF-8 bytes" do
    state =
      ProviderOutput.new()
      |> ProviderOutput.event(%{type: :content_text_delta, index: 0, delta: "é"})
      |> ProviderOutput.event(%{type: :content_text_delta, index: 1, delta: "é"})
      |> ProviderOutput.event(%{
        type: :tool_call_arguments_delta,
        index: 2,
        tool_call_id: "custom",
        delta: "raw"
      })
      |> ProviderOutput.event(%{
        type: :tool_call_completed,
        tool_call: %{id: "custom", arguments: "raw"}
      })
      |> ProviderOutput.event(%{
        type: :response_completed,
        message: %{
          content: [
            %{type: :text, text: "é"},
            %{type: :text, text: "é"},
            %{type: :tool_call, id: "custom", arguments: "raw"}
          ]
        }
      })

    assert {:ok, _} = ProviderOutput.check(state, 7)
    assert {:error, %Error{details: %{size: 7}}} = ProviderOutput.check(state, 6)
  end

  test "absent provider option retains the finite default and inherits finite output_limit" do
    assert ProviderOutput.limit([]) == 1_048_576
    assert ProviderOutput.limit(output_limit: 3) == 3

    assert {:error, %Error{details: %{limit: 3, size: 4}}} =
             Execution.dispatch(prepared(:provider, %{text: "four"}), output_limit: 3)
  end

  test "provisional event-level tool IDs keep independent indexed arguments" do
    for id <- [nil, "", 10] do
      state =
        ProviderOutput.new()
        |> ProviderOutput.event(%{type: :tool_call_started, index: 0, tool_call: %{id: id}})
        |> ProviderOutput.event(%{type: :tool_call_started, index: 1, tool_call: %{id: id}})
        |> ProviderOutput.event(%{type: :tool_call_arguments_delta, index: 0, delta: "ab"})
        |> ProviderOutput.event(%{type: :tool_call_arguments_delta, index: 1, delta: "cd"})
        |> ProviderOutput.event(%{
          type: :tool_call_completed,
          index: 0,
          tool_call: %{id: "A", arguments: "ab"}
        })
        |> ProviderOutput.event(%{
          type: :tool_call_completed,
          index: 1,
          tool_call: %{id: "B", arguments: "cd"}
        })

      assert {:ok, _} = ProviderOutput.check(state, 4)
      assert {:error, %Error{details: %{size: 4}}} = ProviderOutput.check(state, 3)
    end
  end
end

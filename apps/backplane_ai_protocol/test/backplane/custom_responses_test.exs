defmodule Backplane.AiProtocol.CustomResponsesTest do
  use ExUnit.Case, async: true
  alias Backplane.AiProtocol.{Codec, Error, Request, Serialization, ToolCall, ToolDefinition}

  @patch "*** Begin Patch\n*** Add File: 你好.txt\n+hello\n*** End Patch\n"
  @format %{"type" => "grammar", "syntax" => "lark", "definition" => "start: /.+/"}

  test "custom definitions and raw calls retain names, format and bounds" do
    assert {:ok, tool} =
             ToolDefinition.new(%{
               name: "functions::apply_patch",
               input_kind: :custom,
               format: @format
             })

    assert tool.name == "functions::apply_patch"
    assert tool.format == @format

    assert {:ok, call} =
             ToolCall.new(%{id: "call_1", name: tool.name, raw_arguments: {:custom, @patch}})

    assert {:ok, json} = Serialization.to_json(call)
    assert json =~ "custom"

    assert {:error, %Error{}} =
             ToolCall.new(%{id: "c", name: "apply_patch", raw_arguments: {:custom, @patch}},
               limits: %{max_string_bytes: 8}
             )

    assert {:error, %Error{}} =
             ToolCall.new(%{id: "c", name: "exec", raw_arguments: {:custom, <<255>>}})

    assert {:error, %Error{}} =
             ToolCall.new(%{id: "c", name: "exec", raw_arguments: {:structured, @patch}})

    assert {:error, %Error{}} =
             ToolDefinition.new(%{name: "exec", input_kind: :custom, input_schema: %{}})

    assert {:error, %Error{}} = ToolDefinition.new(%{name: "exec", format: @format})
    assert {:error, %Error{}} = ToolDefinition.new(%{name: "clock:::now"})
  end

  test "native Responses declarations, history calls and outputs round trip without JSON wrapping" do
    request = request()
    assert {:ok, wire} = Codec.encode_request(:openai_responses, request)

    assert [
             %{
               "type" => "namespace",
               "name" => "functions",
               "tools" => [%{"type" => "custom", "name" => "apply_patch", "format" => @format}]
             },
             %{
               "type" => "namespace",
               "name" => "clock",
               "tools" => [%{"type" => "function", "name" => "curr_time"}]
             }
           ] = wire["tools"]

    assert [
             %{
               "type" => "custom_tool_call",
               "call_id" => "call_1",
               "namespace" => "functions",
               "name" => "apply_patch",
               "input" => @patch
             },
             %{"type" => "custom_tool_call_output", "call_id" => "call_1", "output" => "ok"}
           ] = wire["input"]

    doc = %{"status" => "completed", "output" => [native_call()]}
    assert {:ok, response} = Codec.decode_response(:openai_responses, 200, [], doc)
    assert response.stop_reason == :tool_use
    assert [block] = response.output
    assert block.tool_call.name == "functions::apply_patch"
    assert block.tool_call.raw_arguments == {:custom, @patch}

    assert {:error, %Error{}} =
             Codec.decode_response(:openai_responses, 200, [], %{
               doc
               | "output" => [native_call(), native_call()]
             })
  end

  test "providers without custom capability reject before dispatch" do
    for provider <- [:openai, :anthropic, :google] do
      assert {:error,
              %Error{
                kind: :incompatible,
                upstream_outcome: :not_submitted,
                compatibility: %{"capability" => "custom_tools"}
              }} = Codec.encode_request(provider, request())
    end
  end

  test "Responses custom input deltas and completion survive every UTF8 transport split" do
    bytes = stream()

    for split <- 0..byte_size(bytes) do
      <<left::binary-size(split), right::binary>> = bytes
      state = Codec.stream_new(:openai_responses)
      assert {:ok, state, first} = Codec.stream_feed(:openai_responses, state, left)
      assert {:ok, state, second} = Codec.stream_feed(:openai_responses, state, right)
      assert {:ok, _state, last} = Codec.stream_finish(:openai_responses, state, :eof)
      events = first ++ second ++ last
      assert [done] = Enum.filter(events, &(&1.type == :tool_call_done))
      assert done.content.tool_call.raw_arguments == {:custom, @patch}
      assert done.name == "functions::apply_patch"
      assert Enum.count(events, &(&1.type == :terminal)) == 1
    end
  end

  test "stream rejects duplicate identities, incomplete custom calls and cumulative input overflow" do
    state = Codec.stream_new(:openai_responses)

    start =
      event(%{
        "type" => "response.output_item.added",
        "output_index" => 0,
        "item" => Map.put(native_call(), "input", "")
      })

    assert {:ok, state, _} = Codec.stream_feed(:openai_responses, state, start)
    assert {:error, %Error{}, _} = Codec.stream_feed(:openai_responses, state, start)
    assert {:error, %Error{}, _} = Codec.stream_finish(:openai_responses, state, :eof)
    state = Codec.stream_new(:openai_responses, max_tool_input_bytes: 8)
    assert {:error, %Error{}, _} = Codec.stream_feed(:openai_responses, state, stream())
  end

  test "namespaced functions preserve namespace and reject unsupported provider projections" do
    {:ok, request} =
      Request.new(%{
        model: "codex",
        input: [],
        tools: [%{name: "clock::curr_time", input_schema: %{"type" => "object"}}]
      })

    for provider <- [:openai, :anthropic, :google] do
      assert {:error,
              %Error{
                upstream_outcome: :not_submitted,
                compatibility: %{"capability" => "tool_namespaces"}
              }} = Codec.encode_request(provider, request)
    end

    native = %{
      "type" => "function_call",
      "id" => "fc_1",
      "call_id" => "c",
      "namespace" => "clock",
      "name" => "curr_time",
      "arguments" => "{}"
    }

    assert {:ok, response} =
             Codec.decode_response(:openai_responses, 200, [], %{
               "status" => "completed",
               "output" => [native]
             })

    assert [block] = response.output
    assert block.tool_call.name == "clock::curr_time"
    assert block.tool_call.raw_arguments == {:json, "{}"}

    for bad <- ["[]", "null", "{", "42"] do
      assert {:error, %Error{}} =
               Codec.decode_response(:openai_responses, 200, [], %{
                 "status" => "completed",
                 "output" => [Map.put(native, "arguments", bad)]
               })
    end
  end

  test "raw exec input is custom text and duplicate request calls are invalid" do
    raw = "const result = await tools.clock__curr_time({}); text(result);"
    call = %{id: "exec_1", name: "functions::exec", raw_arguments: {:custom, raw}}
    message = %{role: :assistant, content: [%{type: :tool_call, tool_call: call}]}

    assert {:ok, request} =
             Request.new(%{
               model: "codex",
               input: [message],
               tools: [
                 %{name: "functions::exec", input_kind: :custom, format: %{"type" => "text"}}
               ]
             })

    assert {:ok, wire} = Codec.encode_request(:openai_responses, request)
    assert [%{"input" => ^raw, "type" => "custom_tool_call"}] = wire["input"]
    assert {:error, %Error{}} = Request.new(%{model: "codex", input: [message, message]})

    assert {:error, %Error{}} =
             Request.new(%{model: "codex", input: [], tools: [%{name: "exec"}, %{name: "exec"}]})
  end

  test "stream rejects malformed, mismatched and unresolved completion events" do
    start =
      event(%{
        "type" => "response.output_item.added",
        "output_index" => 0,
        "item" => Map.put(native_call(), "input", "")
      })

    assert {:ok, state, _} =
             Codec.stream_feed(:openai_responses, Codec.stream_new(:openai_responses), start)

    for bad <- [
          %{
            "type" => "response.custom_tool_call_input.delta",
            "item_id" => "ctc_1",
            "delta" => 10
          },
          %{
            "type" => "response.function_call_arguments.delta",
            "item_id" => "ctc_1",
            "delta" => "{}"
          },
          %{
            "type" => "response.custom_tool_call_input.done",
            "item_id" => "missing",
            "input" => "raw"
          },
          %{
            "type" => "response.output_item.done",
            "item" => Map.put(native_call(), "call_id", "different")
          },
          %{
            "type" => "response.completed",
            "response" => %{"status" => "completed", "output" => [native_call()]}
          }
        ] do
      assert {:error, %Error{}, _} = Codec.stream_feed(:openai_responses, state, event(bad))
    end
  end

  test "Responses bounds retained call count and total raw input across tools" do
    first =
      event(%{
        "type" => "response.output_item.added",
        "output_index" => 0,
        "item" => Map.put(native_call(), "input", "1234")
      })

    second_item =
      native_call()
      |> Map.put("id", "ctc_2")
      |> Map.put("call_id", "call_2")
      |> Map.put("input", "5678")

    second =
      event(%{"type" => "response.output_item.added", "output_index" => 1, "item" => second_item})

    for opts <- [[max_tool_calls: 1], [max_total_tool_input_bytes: 6]] do
      assert {:ok, state, _} =
               Codec.stream_feed(
                 :openai_responses,
                 Codec.stream_new(:openai_responses, opts),
                 first
               )

      assert {:error, %Error{}, _} = Codec.stream_feed(:openai_responses, state, second)
    end
  end

  test "native function streaming keeps JSON object arguments strict" do
    item = %{
      "type" => "function_call",
      "id" => "fc_1",
      "call_id" => "call_f",
      "namespace" => "clock",
      "name" => "curr_time",
      "arguments" => ""
    }

    start = event(%{"type" => "response.output_item.added", "item" => item, "output_index" => 0})

    bytes =
      start <>
        event(%{
          "type" => "response.function_call_arguments.delta",
          "item_id" => "fc_1",
          "delta" => "{}"
        }) <>
        event(%{
          "type" => "response.function_call_arguments.done",
          "item_id" => "fc_1",
          "arguments" => "{}"
        }) <>
        event(%{
          "type" => "response.completed",
          "response" => %{"status" => "completed", "output" => [Map.put(item, "arguments", "{}")]}
        })

    assert {:ok, _state, events} =
             Codec.stream_feed(:openai_responses, Codec.stream_new(:openai_responses), bytes)

    assert [done] = Enum.filter(events, &(&1.type == :tool_call_done))
    assert done.content.tool_call.raw_arguments == {:json, "{}"}

    assert {:ok, state, _} =
             Codec.stream_feed(:openai_responses, Codec.stream_new(:openai_responses), start)

    assert {:error, %Error{}, _} =
             Codec.stream_feed(
               :openai_responses,
               state,
               event(%{
                 "type" => "response.function_call_arguments.done",
                 "item_id" => "fc_1",
                 "arguments" => "[]"
               })
             )
  end

  test "terminal completion cannot change a custom call into a JSON function" do
    item = native_call() |> Map.put("input", "{}")

    bytes =
      event(%{"type" => "response.output_item.added", "item" => item}) <>
        event(%{"type" => "response.output_item.done", "item" => item})

    assert {:ok, state, _} =
             Codec.stream_feed(:openai_responses, Codec.stream_new(:openai_responses), bytes)

    changed =
      item
      |> Map.put("type", "function_call")
      |> Map.put("arguments", "{}")
      |> Map.delete("input")

    assert {:error, %Error{}, _} =
             Codec.stream_feed(
               :openai_responses,
               state,
               event(%{
                 "type" => "response.completed",
                 "response" => %{"status" => "completed", "output" => [changed]}
               })
             )
  end

  defp request do
    {:ok, request} =
      Request.new(%{
        model: "codex",
        tools: [
          %{name: "functions::apply_patch", input_kind: :custom, format: @format},
          %{name: "clock::curr_time", input_schema: %{"type" => "object"}}
        ],
        input: [
          %{
            role: :assistant,
            content: [
              %{
                type: :tool_call,
                tool_call: %{
                  id: "call_1",
                  name: "functions::apply_patch",
                  raw_arguments: {:custom, @patch}
                }
              }
            ]
          },
          %{role: :tool, tool_call_id: "call_1", content: [%{type: :text, text: "ok"}]}
        ]
      })

    request
  end

  defp native_call,
    do: %{
      "type" => "custom_tool_call",
      "id" => "ctc_1",
      "call_id" => "call_1",
      "namespace" => "functions",
      "name" => "apply_patch",
      "input" => @patch
    }

  defp event(value), do: "data: " <> Jason.encode!(value) <> "\n\n"

  defp stream do
    event(%{
      "type" => "response.output_item.added",
      "output_index" => 0,
      "item" => Map.put(native_call(), "input", "")
    }) <>
      event(%{
        "type" => "response.custom_tool_call_input.delta",
        "item_id" => "ctc_1",
        "output_index" => 0,
        "delta" => @patch
      }) <>
      event(%{
        "type" => "response.custom_tool_call_input.done",
        "item_id" => "ctc_1",
        "output_index" => 0,
        "input" => @patch
      }) <>
      event(%{
        "type" => "response.output_item.done",
        "output_index" => 0,
        "item" => native_call()
      }) <>
      event(%{
        "type" => "response.completed",
        "response" => %{"status" => "completed", "output" => [native_call()]}
      })
  end
end

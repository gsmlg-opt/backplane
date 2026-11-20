defmodule Backplane.AiProtocol.CodexResponsesProjectionTest do
  use ExUnit.Case, async: true

  alias Backplane.AiProtocol.{Codec, Error, Request}
  alias Backplane.AiProtocol.Codec.OpenAIResponses

  @archive_schema %{
    "type" => "object",
    "properties" => %{
      "query" => %{"type" => "string", "encrypted" => true},
      "limit" => %{"type" => "integer", "minimum" => 1}
    },
    "required" => ["query"],
    "additionalProperties" => false
  }

  test "Codex declarations and replay use provider identities and wire schemas" do
    request = request()

    assert {:ok, opts} = OpenAIResponses.codex_tool_options(request)
    assert {:ok, wire} = Codec.encode_request(:openai_responses, request, opts)

    assert [
             %{
               "name" => "agent_message_board",
               "description" => "Tools in the agent_message_board namespace.",
               "tools" => [%{"name" => "get_channels"}]
             },
             %{"name" => "history", "tools" => [%{"strict" => false, "parameters" => schema}]},
             %{"name" => "ordinary", "parameters" => @archive_schema}
           ] = wire["tools"]

    assert schema == %{
             "type" => "object",
             "properties" => %{
               "query" => %{"type" => "string", "encrypted" => true},
               "limit" => %{"type" => "integer"}
             },
             "required" => ["query"]
           }

    assert [
             %{
               "namespace" => "agent_message_board",
               "name" => "get_channels",
               "call_id" => "call_board"
             },
             %{"type" => "function_call_output", "call_id" => "call_board", "output" => "[]"}
           ] = wire["input"]

    assert {:ok, default} = Codec.encode_request(:openai_responses, request)
    assert [%{"namespace" => "collaboration"}, _result] = default["input"]

    assert Enum.at(default["tools"], 1)["tools"] |> hd() |> Map.fetch!("parameters") ==
             @archive_schema
  end

  test "optional-only archive arguments omit empty required lists on the wire" do
    schema = %{
      "type" => "object",
      "properties" => %{"limit" => %{"type" => "integer", "minimum" => 1}},
      "required" => [],
      "additionalProperties" => false
    }

    request = request([%{name: "history::list_items", input_schema: schema}])
    assert {:ok, opts} = OpenAIResponses.codex_tool_options(request)

    assert OpenAIResponses.wire_tool_parameters("history::list_items", schema, opts) ==
             %{"type" => "object", "properties" => %{"limit" => %{"type" => "integer"}}}

    assert hd(request.tools).input_schema == schema
  end

  test "buffered and streamed results restore the canonical tool name" do
    assert {:ok, opts} = OpenAIResponses.codex_tool_options(request())

    item = %{
      "id" => "fc_item",
      "call_id" => "call_board",
      "type" => "function_call",
      "namespace" => "agent_message_board",
      "name" => "get_channels",
      "arguments" => "{}"
    }

    document = %{"status" => "completed", "output" => [item]}
    assert {:ok, response} = Codec.decode_response(:openai_responses, 200, [], document, opts)
    assert [%{tool_call: %{name: "collaboration::get_channels"}}] = response.output

    state = Codec.stream_new(:openai_responses, opts)

    assert {:ok, state, [%{type: :tool_call_start, name: "collaboration::get_channels"}]} =
             feed(state, "response.output_item.added", %{"item" => %{item | "arguments" => ""}})

    assert {:ok, state, [%{type: :tool_call_done, name: "collaboration::get_channels"}]} =
             feed(state, "response.output_item.done", %{"item" => item})

    assert {:ok, _, [%{type: :terminal, stop_reason: :tool_use}]} =
             feed(state, "response.completed", %{"response" => document})

    assert {:error, %Error{}} =
             Codec.decode_response(
               :openai_responses,
               200,
               [],
               %{document | "output" => [%{item | "name" => "create_channel"}]},
               opts
             )
  end

  test "a historical board tool participates in namespace collision checks" do
    request = request([%{name: "agent_message_board::another_tool"}])
    assert {:error, %Error{}} = OpenAIResponses.codex_tool_options(request)

    retired = %{request | tools: []}
    assert {:ok, opts} = OpenAIResponses.codex_tool_options(retired)

    assert {:ok, %{"input" => [%{"namespace" => "agent_message_board"}, _result]}} =
             Codec.encode_request(:openai_responses, retired, opts)
  end

  test "host-owned History and Notes retain their plaintext schemas and canonical identities" do
    schema = put_in(@archive_schema, ["properties", "query"], %{"type" => "string"})

    request =
      request(
        for ns <- ~w(history notes), do: %{name: ns <> "::search_contents", input_schema: schema}
      )

    [previous, result] = request.input
    [block] = previous.content
    call = %{block.tool_call | name: "history::search_contents"}
    request = %{request | input: [%{previous | content: [%{block | tool_call: call}]}, result]}
    assert {:ok, opts} = OpenAIResponses.codex_tool_options(request, history_notes: :local)
    assert {:ok, wire} = Codec.encode_request(:openai_responses, request, opts)

    assert length(wire["tools"]) == 2

    for {group, ns} <- Enum.zip(wire["tools"], ~w(local_history local_notes)) do
      assert %{
               "name" => ^ns,
               "tools" => [%{"name" => "search_contents", "parameters" => ^schema}]
             } = group
    end

    assert [%{"namespace" => "local_history", "name" => "search_contents"}, _] = wire["input"]

    item = %{
      "type" => "function_call",
      "name" => "search_contents",
      "namespace" => "local_notes",
      "id" => "fc_1",
      "call_id" => "call_1",
      "arguments" => ~s({"query":"example"})
    }

    document = %{"status" => "completed", "output" => [item]}

    assert {:ok, %{output: [%{tool_call: %{name: "notes::search_contents"}}]}} =
             Codec.decode_response(:openai_responses, 200, [], document, opts)

    for bad_item <- [%{item | "namespace" => "notes"}, %{item | "name" => "write_file"}] do
      assert {:error, %Error{}} =
               Codec.decode_response(
                 :openai_responses,
                 200,
                 [],
                 %{document | "output" => [bad_item]},
                 opts
               )
    end
  end

  test "local namespaces reject collisions with caller tools before transmission" do
    request = request([%{name: "notes::read_file"}, %{name: "local_notes::custom"}])
    assert {:error, %Error{}} = OpenAIResponses.codex_tool_options(request, history_notes: :local)

    assert {:ok, _} =
             OpenAIResponses.codex_tool_options(request, history_notes: :remote_encrypted)

    assert {:error, %Error{}} = OpenAIResponses.codex_tool_options(request, history_notes: :auto)
  end

  defp request(
         tools \\ [
           %{name: "collaboration::get_channels"},
           %{name: "history::search_contents", input_schema: @archive_schema},
           %{name: "ordinary", input_schema: @archive_schema}
         ]
       ) do
    {:ok, request} =
      Request.new(%{
        model: "gpt-6.2-sol",
        tools: tools,
        input: [
          %{
            role: :assistant,
            content: [
              %{
                type: :tool_call,
                tool_call: %{
                  id: "call_board",
                  name: "collaboration::get_channels",
                  raw_arguments: {:structured, %{}}
                }
              }
            ]
          },
          %{role: :tool, tool_call_id: "call_board", content: [%{type: :text, text: "[]"}]}
        ]
      })

    request
  end

  defp feed(state, type, data) do
    frame = "data: " <> Formata.JSON.encode!(Map.put(data, "type", type)) <> "\n\n"
    Codec.stream_feed(:openai_responses, state, frame)
  end
end

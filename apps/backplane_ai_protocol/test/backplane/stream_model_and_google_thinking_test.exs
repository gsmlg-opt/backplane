defmodule Backplane.AiProtocol.StreamModelAndGoogleThinkingTest do
  use ExUnit.Case, async: true

  alias Backplane.AiProtocol.{Codec, Error, Request}

  for protocol <- [:openai, :anthropic, :google, :openai_responses] do
    @protocol protocol
    test "#{protocol} retains the observed model across every ordinary chunk boundary" do
      wire = stream_fixture(@protocol, "resolved-model-v1")

      for split <- 0..byte_size(wire) do
        <<first::binary-size(split), second::binary>> = wire
        events = decode(@protocol, [first, second])
        assert Enum.any?(events, &(&1.type == :text_delta and &1.text == "7"))
        terminal = Enum.find(events, &(&1.type == :terminal))
        assert terminal.completeness == :complete
        assert Map.get(terminal, :resolved_model) == "resolved-model-v1"
        assert Enum.all?(events, &(Map.get(&1, :resolved_model) == "resolved-model-v1"))
      end
    end

    test "#{protocol} leaves absent model metadata unknown despite request affinity" do
      events = decode(@protocol, [stream_fixture(@protocol, nil)])
      assert Enum.any?(events, &(&1.type == :terminal))
      assert Enum.all?(events, &is_nil(Map.get(&1, :resolved_model)))
    end
  end

  test "OpenAI preserves ordered model observations through trailing usage without rewriting earlier events" do
    wire =
      sse(%{
        "model" => "observed-first",
        "choices" => [%{"index" => 0, "delta" => %{"content" => "7"}}]
      }) <>
        sse(%{
          "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}]
        }) <>
        sse(%{
          "model" => "observed-final",
          "choices" => [],
          "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}
        }) <> "data: [DONE]\n\n"

    assert [text, terminal, usage] = decode(:openai, [wire])
    assert text.type == :text_delta and text.resolved_model == "observed-first"
    assert terminal.type == :terminal and terminal.resolved_model == "observed-first"
    assert usage.type == :usage and usage.resolved_model == "observed-final"
  end

  test "Responses observes a model supplied only on its normal terminal document" do
    wire =
      sse(%{"type" => "response.output_text.delta", "delta" => "7"}) <>
        sse(%{
          "type" => "response.completed",
          "response" => %{"status" => "completed", "output" => [], "model" => "terminal-model"}
        })

    assert [text, terminal] = decode(:openai_responses, [wire])
    assert is_nil(text.resolved_model)
    assert terminal.resolved_model == "terminal-model"
  end

  test "Google maps explicitly resolved budget, level and disabled configurations in both APIs" do
    for {thinking, expected} <- [
          {%{include_thoughts: true, thinking_budget: 1024},
           %{"includeThoughts" => true, "thinkingBudget" => 1024}},
          {%{"include_thoughts" => true, "thinking_level" => "HIGH"},
           %{"includeThoughts" => true, "thinkingLevel" => "HIGH"}},
          {%{include_thoughts: false, thinking_budget: 0},
           %{"includeThoughts" => false, "thinkingBudget" => 0}},
          {%{thinking_level: "MINIMAL"}, %{"thinkingLevel" => "MINIMAL"}},
          {%{thinking_budget: -1}, %{"thinkingBudget" => -1}},
          {%{}, %{}}
        ] do
      {:ok, request} =
        Request.new(%{
          model: "caller-selected-model",
          input: [],
          settings: %{max_output_tokens: 4096, thinking_config: thinking}
        })

      assert {:ok, %{target: target, body: body}} =
               Codec.encode_rest_request(:google, request, stream: true)

      assert target == %{
               operation: :generate_content,
               model: "caller-selected-model",
               stream: true
             }

      assert body["generationConfig"] == %{
               "maxOutputTokens" => 4096,
               "thinkingConfig" => expected
             }

      assert {:ok, envelope} = Codec.encode_request(:google, request, stream: true)
      assert envelope == Map.merge(body, %{"model" => target.model, "stream" => true})
      refute Map.has_key?(body, "model")
      refute Map.has_key?(body, "stream")
    end
  end

  test "omitting Google thinking configuration preserves the existing request" do
    {:ok, request} =
      Request.new(%{model: "m", input: [], settings: %{max_output_tokens: 4096}})

    assert {:ok, %{body: %{"generationConfig" => config}}} =
             Codec.encode_rest_request(:google, request)

    assert config == %{"maxOutputTokens" => 4096}
  end

  test "Google rejects malformed or unknown thinking fields instead of dropping them" do
    for thinking <- [
          nil,
          true,
          %{include_thoughts: "true"},
          %{thinking_budget: 1.5},
          %{thinking_level: ""},
          %{unknown: 1}
        ] do
      {:ok, request} =
        Request.new(%{model: "m", input: [], settings: %{thinking_config: thinking}})

      assert {:error, %Error{kind: :incompatible}} =
               Codec.encode_rest_request(:google, request)
    end
  end

  defp decode(protocol, chunks) do
    state = Codec.stream_new(protocol, model: "requested-alias", profile: "fixture")

    {state, events} =
      Enum.reduce(chunks, {state, []}, fn chunk, {state, events} ->
        assert {:ok, next, observed} = Codec.stream_feed(protocol, state, chunk)
        {next, events ++ observed}
      end)

    assert {:ok, _state, tail} = Codec.stream_finish(protocol, state, :eof)
    events ++ tail
  end

  defp stream_fixture(:openai, model) do
    sse(with_model(%{"choices" => []}, "model", model)) <>
      sse(%{"choices" => [%{"index" => 0, "delta" => %{"content" => "7"}}]}) <>
      sse(%{"choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}]}) <>
      "data: [DONE]\n\n"
  end

  defp stream_fixture(:anthropic, model) do
    sse(%{"type" => "message_start", "message" => with_model(%{}, "model", model)}) <>
      sse(%{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "text", "text" => ""}
      }) <>
      sse(%{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "text_delta", "text" => "7"}
      }) <>
      sse(%{"type" => "content_block_stop", "index" => 0}) <>
      sse(%{"type" => "message_delta", "delta" => %{"stop_reason" => "end_turn"}}) <>
      sse(%{"type" => "message_stop"})
  end

  defp stream_fixture(:google, model) do
    sse(with_model(%{}, "modelVersion", model)) <>
      sse(%{
        "candidates" => [
          %{"index" => 0, "content" => %{"parts" => [%{"text" => "7"}]}, "finishReason" => "STOP"}
        ]
      })
  end

  defp stream_fixture(:openai_responses, model) do
    sse(%{"type" => "response.created", "response" => with_model(%{}, "model", model)}) <>
      sse(%{"type" => "response.output_text.delta", "delta" => "7"}) <>
      sse(%{
        "type" => "response.completed",
        "response" => %{"status" => "completed", "output" => []}
      })
  end

  defp with_model(value, _key, nil), do: value
  defp with_model(value, key, model), do: Map.put(value, key, model)
  defp sse(value), do: "data: " <> Jason.encode!(value) <> "\n\n"
end

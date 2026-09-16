defmodule Backplane.LLM.ModelResponseTest do
  use ExUnit.Case, async: true

  alias Backplane.LLM.ModelResponse

  test "restores the requested alias in a JSON response" do
    response = ~S({"id":"chat_1","model":"gpt-5.6-terra","choices":[]})

    normalized = ModelResponse.normalize_body(response, "smart", "gpt-5.6-terra")

    assert Jason.decode!(normalized)["model"] == "smart"
  end

  test "restores the requested alias in a Responses nested JSON response" do
    response = ~S({"id":"resp_1","model":"gpt-5.6-terra","response":{"model":"gpt-5.6-terra"}})

    normalized = ModelResponse.normalize_responses_body(response, "smart", "gpt-5.6-terra")
    decoded = Jason.decode!(normalized)

    assert decoded["model"] == "smart"
    assert decoded["response"]["model"] == "smart"
  end

  test "restores the requested alias in SSE data events" do
    chunk =
      ": keepalive\n\n" <>
        "data: {\"id\":\"chat_1\",\"model\":\"gpt-5.6-terra\",\"choices\":[]}\n\n" <>
        "data: {malformed}\n\n" <>
        "data: [DONE]\n\n"

    normalized = ModelResponse.normalize_chunk(chunk, "smart", "gpt-5.6-terra")

    assert normalized =~ ~S("model":"smart")
    assert normalized =~ "data: [DONE]\n\n"
    assert normalized =~ ": keepalive\n\n"
    assert normalized =~ "data: {malformed}\n\n"
    refute normalized =~ "gpt-5.6-terra"
  end

  test "restores the requested alias in Responses nested SSE events" do
    chunk =
      ": keepalive\n\n" <>
        "data: {\"type\":\"response.created\",\"response\":{\"model\":\"gpt-5.6-terra\"}}\n\n" <>
        "data: {malformed}\n\n" <>
        "data: [DONE]\n\n"

    normalized = ModelResponse.normalize_responses_chunk(chunk, "smart", "gpt-5.6-terra")

    assert normalized =~ ~S("response":{"model":"smart"})
    assert normalized =~ ": keepalive\n\n"
    assert normalized =~ "data: {malformed}\n\n"
    assert normalized =~ "data: [DONE]\n\n"
  end

  test "restores Responses aliases when SSE data is fragmented across transport chunks" do
    stream =
      ": keepalive\r\n\r\n" <>
        "data: {\"type\":\"response.created\",\"response\":{\"model\":\"gpt-5.6-terra\"}}\r\n\r\n" <>
        "data: {malformed}\n\n" <>
        "data: [DONE]\n\n"

    mapper = ModelResponse.responses_stream_mapper("smart", "gpt-5.6-terra")

    normalized =
      stream
      |> split_at_offsets([1, 9, 18, 47, 72, 91, 108])
      |> Enum.flat_map(mapper)
      |> IO.iodata_to_binary()

    assert normalized =~ ~S("response":{"model":"smart"})
    assert normalized =~ ": keepalive\r\n\r\n"
    assert normalized =~ "data: {malformed}\n\n"
    assert normalized =~ "data: [DONE]\n\n"
    refute normalized =~ "gpt-5.6-terra"
  end

  test "fails open instead of buffering an unbounded unterminated SSE line" do
    mapper = ModelResponse.responses_stream_mapper("smart", "gpt-5.6-terra")
    oversized = "data: " <> String.duplicate("x", 1_048_576)

    assert mapper.(oversized) == [oversized]

    next =
      "\n" <>
        "data: {\"type\":\"response.completed\",\"response\":{\"model\":\"gpt-5.6-terra\"}}\n\n"

    mapped = mapper.(next) |> IO.iodata_to_binary()
    assert mapped =~ ~S("response":{"model":"smart"})
  end

  test "does not replace nested or unrelated model fields" do
    response =
      ~S({"model":"another-model","response":{"model":"gpt-5.6-terra"}})

    assert ModelResponse.normalize_body(response, "smart", "gpt-5.6-terra") == response
  end

  test "Responses normalization leaves unrelated nested and nonmatching models unchanged" do
    response =
      ~S({"item":{"model":"gpt-5.6-terra"},"response":{"model":"another-model"}})

    assert ModelResponse.normalize_responses_body(response, "smart", "gpt-5.6-terra") ==
             response
  end

  test "preserves response bytes when the requested and resolved models match" do
    body = "{ \"model\" : \"gpt-5.6-terra\", \"future\": true }\n"
    chunk = "event: message\r\ndata: { \"model\" : \"gpt-5.6-terra\" }\r\n\r\n"

    assert ModelResponse.normalize_body(body, "gpt-5.6-terra", "gpt-5.6-terra") == body

    assert ModelResponse.normalize_chunk(chunk, "gpt-5.6-terra", "gpt-5.6-terra") ==
             chunk

    assert ModelResponse.normalize_responses_body(body, "gpt-5.6-terra", "gpt-5.6-terra") ==
             body

    assert ModelResponse.normalize_responses_chunk(
             chunk,
             "gpt-5.6-terra",
             "gpt-5.6-terra"
           ) == chunk
  end

  defp split_at_offsets(binary, offsets) do
    {chunks, offset} =
      Enum.reduce(offsets, {[], 0}, fn next_offset, {chunks, offset} ->
        {[binary_part(binary, offset, next_offset - offset) | chunks], next_offset}
      end)

    Enum.reverse([binary_part(binary, offset, byte_size(binary) - offset) | chunks])
  end
end

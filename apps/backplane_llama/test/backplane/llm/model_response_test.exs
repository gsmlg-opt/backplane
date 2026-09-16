defmodule Backplane.LLM.ModelResponseTest do
  use ExUnit.Case, async: true

  alias Backplane.LLM.ModelResponse

  test "restores the requested alias in a JSON response" do
    response = ~S({"id":"chat_1","model":"gpt-5.6-terra","choices":[]})

    normalized = ModelResponse.normalize_body(response, "smart", "gpt-5.6-terra")

    assert Jason.decode!(normalized)["model"] == "smart"
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

  test "does not replace nested or unrelated model fields" do
    response =
      ~S({"model":"another-model","response":{"model":"gpt-5.6-terra"}})

    assert ModelResponse.normalize_body(response, "smart", "gpt-5.6-terra") == response
  end

  test "preserves response bytes when the requested and resolved models match" do
    body = "{ \"model\" : \"gpt-5.6-terra\", \"future\": true }\n"
    chunk = "event: message\r\ndata: { \"model\" : \"gpt-5.6-terra\" }\r\n\r\n"

    assert ModelResponse.normalize_body(body, "gpt-5.6-terra", "gpt-5.6-terra") == body

    assert ModelResponse.normalize_chunk(chunk, "gpt-5.6-terra", "gpt-5.6-terra") ==
             chunk
  end
end

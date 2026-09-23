defmodule Backplane.LLM.Google.RequestTargetTest do
  use ExUnit.Case, async: true

  alias Backplane.LLM.Google.RequestTarget

  test "parses the M1 v1beta operations without decoding model separators" do
    assert {:ok, target} =
             RequestTarget.parse("POST", "/v1beta/models/gemini-2.5-flash:generateContent", "")

    assert target.model == "gemini-2.5-flash"
    assert target.operation == :generate
    assert target.upstream_operation == "generateContent"

    assert {:ok, %{operation: :count_tokens}} =
             RequestTarget.parse("POST", "/v1beta/models/fast:countTokens", "")

    assert {:ok, %{operation: :models_list}} =
             RequestTarget.parse("GET", "/v1beta/models", "pageSize=25")
  end

  test "requires alt=sse for streamGenerateContent" do
    assert {:ok, %{operation: :stream_generate}} =
             RequestTarget.parse(
               "POST",
               "/v1beta/models/gemini:streamGenerateContent",
               "alt=sse"
             )

    assert {:error, :stream_requires_sse} =
             RequestTarget.parse(
               "POST",
               "/v1beta/models/gemini:streamGenerateContent",
               ""
             )
  end

  test "rejects unsupported methods, encoded separators and non-single-segment aliases" do
    assert {:error, :unsupported_route} =
             RequestTarget.parse("DELETE", "/v1beta/models/gemini", "")

    for model <- ["google/gemini", "google%2Fgemini", "google%252Fgemini", "..", "bad:model"] do
      assert {:error, :invalid_model} =
               RequestTarget.parse(
                 "POST",
                 "/v1beta/models/#{model}:generateContent",
                 ""
               )
    end
  end

  test "builds the upstream path from the resolved model only" do
    assert RequestTarget.upstream_path(:generate, "gemini-2.5-pro") ==
             {:ok, "/models/gemini-2.5-pro:generateContent"}

    assert RequestTarget.upstream_path(:count_tokens, "models/gemini-2.5-pro") ==
             {:ok, "/models/gemini-2.5-pro:countTokens"}

    for unsafe <- ["../secret", "foo/bar", "foo?key=secret", "models/foo/bar"] do
      assert {:error, :invalid_model} = RequestTarget.upstream_path(:generate, unsafe)
    end
  end
end

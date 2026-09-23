defmodule Backplane.LLM.Google.RequestBodyTest do
  use ExUnit.Case, async: true

  alias Backplane.LLM.Google.RequestBody

  test "generation keeps the exact JSON bytes and rejects a body routing model" do
    raw = ~s({ "contents" : [{"parts":[{"text":"hello"}]}] })
    assert {:ok, ^raw} = RequestBody.prepare(:generate, raw, "fast", "gemini-2.5-flash")

    assert {:error, :body_model_conflict} =
             RequestBody.prepare(
               :generate,
               ~s({"model":"models/other","contents":[]}),
               "fast",
               "gemini-2.5-flash"
             )
  end

  test "countTokens explicitly normalizes a matching nested model and rejects conflicts" do
    assert {:ok, rewritten} =
             RequestBody.prepare(
               :count_tokens,
               ~s({"generateContentRequest":{"model":"models/fast","contents":[]}}),
               "fast",
               "gemini-2.5-flash"
             )

    assert Jason.decode!(rewritten)["generateContentRequest"]["model"] ==
             "models/gemini-2.5-flash"

    assert {:error, :body_model_conflict} =
             RequestBody.prepare(
               :count_tokens,
               ~s({"generateContentRequest":{"model":"models/other"}}),
               "fast",
               "gemini-2.5-flash"
             )
  end
end

defmodule Backplane.LLM.ModelExtractorTest do
  use ExUnit.Case, async: true

  alias Backplane.LLM.ModelExtractor

  # ── extract/1 ─────────────────────────────────────────────────────────────────

  describe "extract/1" do
    test "returns {:ok, model} for valid JSON with model field" do
      body = Jason.encode!(%{"model" => "claude-3-5-sonnet-20241022", "messages" => []})
      assert {:ok, "claude-3-5-sonnet-20241022"} = ModelExtractor.extract(body)
    end

    test "returns {:error, :no_model} when model field is missing" do
      body = Jason.encode!(%{"messages" => []})
      assert {:error, :no_model} = ModelExtractor.extract(body)
    end

    test "returns {:error, :no_model} when model field is not a string" do
      body = Jason.encode!(%{"model" => 42, "messages" => []})
      assert {:error, :no_model} = ModelExtractor.extract(body)
    end

    test "returns {:error, :invalid_json} for malformed JSON" do
      assert {:error, :invalid_json} = ModelExtractor.extract("not json {{{")
    end
  end

  # ── replace_model/2 ───────────────────────────────────────────────────────────

  describe "replace_model/2" do
    test "replaces the model field in the JSON body" do
      body = Jason.encode!(%{"model" => "gpt-4o", "temperature" => 0.7})
      assert {:ok, new_body} = ModelExtractor.replace_model(body, "gpt-4o-mini")
      assert {:ok, decoded} = Jason.decode(new_body)
      assert decoded["model"] == "gpt-4o-mini"
    end

    test "preserves all other fields when replacing model" do
      body = Jason.encode!(%{"model" => "old-model", "temperature" => 0.5, "max_tokens" => 1024})
      assert {:ok, new_body} = ModelExtractor.replace_model(body, "new-model")
      assert {:ok, decoded} = Jason.decode(new_body)
      assert decoded["model"] == "new-model"
      assert decoded["temperature"] == 0.5
      assert decoded["max_tokens"] == 1024
    end

    test "returns {:error, :invalid_json} for malformed JSON" do
      assert {:error, :invalid_json} = ModelExtractor.replace_model("bad json", "gpt-4o")
    end
  end
end

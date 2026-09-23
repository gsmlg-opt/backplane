defmodule Backplane.LLM.ModelMetadataTest do
  use ExUnit.Case, async: true

  alias Backplane.LLM.ModelMetadata

  test "normalizes OpenRouter limits, modalities and explicit parameter support" do
    raw = %{
      "context_length" => 128_000,
      "top_provider" => %{"max_completion_tokens" => 16_384},
      "architecture" => %{
        "input_modalities" => ["text", "image"],
        "output_modalities" => ["text"]
      },
      "supported_parameters" => ["tools", "reasoning"]
    }

    metadata = ModelMetadata.normalize("openrouter", raw)

    assert metadata["context_window"] == 128_000
    assert metadata["max_output_tokens"] == 16_384
    assert metadata["input_modalities"] == ["text", "image"]
    assert metadata["output_modalities"] == ["text"]
    assert metadata["supports_tool_calling"]
    assert metadata["supports_reasoning"]
    assert metadata["raw"] == raw
    refute Map.has_key?(metadata, "supported_reasoning_levels")
  end

  test "normalizes vLLM and SGLang context without guessing model capabilities" do
    assert ModelMetadata.normalize("vllm", %{"max_model_len" => 8192})["context_window"] ==
             8192

    metadata = ModelMetadata.normalize("sglang", %{"sglang" => %{"context_length" => 32768}})
    assert metadata["context_window"] == 32768
    refute Map.has_key?(metadata, "supports_tool_calling")
    refute Map.has_key?(metadata, "input_modalities")
  end

  test "SGLang model-list capacity and native modality flags describe the actual deployment" do
    raw = %{
      "max_model_len" => 16384,
      "sglang" => %{
        "has_image_understanding" => true,
        "has_audio_understanding" => false,
        "is_generation" => true,
        "tool_call_parser" => "configured-parser"
      }
    }

    metadata = ModelMetadata.normalize("sglang", raw)
    assert metadata["context_window"] == 16384
    assert metadata["input_modalities"] == ["text", "image"]
    assert metadata["output_modalities"] == ["text"]
    refute Map.has_key?(metadata, "supports_tool_calling")
  end

  test "Ollama configured num_ctx takes precedence over architecture capacity" do
    raw = %{
      "ollama" => %{
        "model_info" => %{"general.architecture" => "llama", "llama.context_length" => 131_072},
        "parameters" => "num_ctx 8192\nstop \"end\"\n",
        "capabilities" => ["completion", "vision", "tools", "thinking"]
      }
    }

    metadata = ModelMetadata.normalize("ollama", raw)
    assert metadata["context_window"] == 8192
    assert metadata["input_modalities"] == ["text", "image"]
    assert metadata["output_modalities"] == ["text"]
    assert metadata["supports_tool_calling"]
    assert metadata["supports_reasoning"]
    refute Map.has_key?(metadata, "supported_reasoning_levels")
  end

  test "unknown providers and missing fields remain unknown" do
    metadata = ModelMetadata.normalize("custom", %{"id" => "thinking-vision-model"})
    assert metadata == %{"raw" => %{"id" => "thinking-vision-model"}}
    assert ModelMetadata.normalize(nil, nil) == %{"raw" => %{}}
  end

  test "Anthropic limits and capabilities use advertised values, not schema example zeros" do
    raw = %{
      "max_input_tokens" => 200_000,
      "max_tokens" => 64000,
      "capabilities" => %{
        "thinking" => %{"supported" => true},
        "image_input" => %{"supported" => true},
        "effort" => %{
          "supported" => true,
          "low" => %{"supported" => true},
          "high" => %{"supported" => true},
          "max" => %{"supported" => false}
        }
      }
    }

    metadata = ModelMetadata.normalize("anthropic", raw)
    assert metadata["context_window"] == 200_000
    assert metadata["max_output_tokens"] == 64000
    assert metadata["supports_reasoning"]
    assert metadata["input_modalities"] == ["text", "image"]
    assert Enum.map(metadata["supported_reasoning_levels"], & &1["effort"]) == ["low", "high"]
    refute Map.has_key?(metadata, "supports_tool_calling")
    refute Map.has_key?(metadata, "default_reasoning_level")

    metadata = ModelMetadata.normalize("anthropic", %{"max_input_tokens" => 0, "max_tokens" => 0})
    refute Map.has_key?(metadata, "context_window")
    refute Map.has_key?(metadata, "max_output_tokens")
  end

  test "Google AI Studio token limits are normalized without invented modalities" do
    metadata =
      ModelMetadata.normalize("google-ai-studio", %{
        "inputTokenLimit" => 1_048_576,
        "outputTokenLimit" => 65536,
        "displayName" => "Gemini"
      })

    assert metadata["context_window"] == 1_048_576
    assert metadata["max_output_tokens"] == 65536
    assert metadata["display_name"] == "Gemini"
    refute Map.has_key?(metadata, "input_modalities")
  end

  test "Google Gemini Developer metadata preserves advertised methods and provenance" do
    metadata =
      ModelMetadata.normalize("google-gemini-developer", %{
        "name" => "models/gemini-2.5-pro",
        "displayName" => "Gemini 2.5 Pro",
        "inputTokenLimit" => 1_048_576,
        "outputTokenLimit" => 65_536,
        "supportedGenerationMethods" => ["generateContent", "countTokens"],
        "provenance" => "google_models_api"
      })

    assert metadata["context_window"] == 1_048_576
    assert metadata["max_output_tokens"] == 65_536
    assert metadata["display_name"] == "Gemini 2.5 Pro"
    assert metadata["raw"]["supportedGenerationMethods"] == ["generateContent", "countTokens"]
    refute Map.has_key?(metadata, "supports_tool_calling")
  end

  test "explicit canonical metadata including false overrides provider mappings" do
    raw = %{
      "max_model_len" => 32768,
      "context_window" => 4096,
      "supports_tool_calling" => false,
      "capabilities" => %{"tools" => true, "reasoning" => false}
    }

    metadata = ModelMetadata.normalize("vllm", raw)
    assert metadata["context_window"] == 4096
    assert metadata["supports_tool_calling"] == false
    assert metadata["supports_reasoning"] == false
  end

  test "rejects invalid limits and modality fields rather than fabricating zero" do
    for invalid <- [0, -1, "unknown", "4096tokens", 1.5, false, 9_223_372_036_854_775_808] do
      metadata = ModelMetadata.normalize("vllm", %{"max_model_len" => invalid})
      refute Map.has_key?(metadata, "context_window")
    end

    assert ModelMetadata.normalize("custom", %{"context_window" => "4096"})[
             "context_window"
           ] == 4096

    metadata = ModelMetadata.normalize("custom", %{"input_modalities" => "text"})
    refute Map.has_key?(metadata, "input_modalities")
  end

  test "malformed parameter lists are unknown rather than unsupported" do
    metadata = ModelMetadata.normalize("openrouter", %{"supported_parameters" => [nil, 42]})
    refute Map.has_key?(metadata, "supports_tool_calling")
    refute Map.has_key?(metadata, "supports_reasoning")
  end

  test "Codex descriptors use routable slugs and typed conservative defaults" do
    descriptor = ModelMetadata.codex("local/model", "My Model", ModelMetadata.normalize(nil, %{}))
    assert descriptor["slug"] == "local/model"
    assert descriptor["display_name"] == "My Model"
    assert descriptor["supported_reasoning_levels"] == []
    assert descriptor["default_reasoning_level"] == nil
    assert descriptor["input_modalities"] == ["text"]
    assert descriptor["support_verbosity"] == false
    assert descriptor["supports_reasoning_summary_parameter"] == false
    assert descriptor["visibility"] == "list"
    assert descriptor["shell_type"] == "unified_exec"
    assert String.trim(descriptor["base_instructions"]) != ""
    assert descriptor["truncation_policy"] == %{"mode" => "bytes", "limit" => 10000}
    refute Map.has_key?(descriptor, "context_window")
  end

  test "Codex fields retain upstream effort descriptions and known settings" do
    raw = %{
      "slug" => "upstream-id",
      "context_window" => 128_000,
      "max_output_tokens" => 8000,
      "input_modalities" => ["text", "image", "video"],
      "default_reasoning_level" => "high",
      "supported_reasoning_levels" => [%{"effort" => "high", "description" => "Think deeply"}],
      "support_verbosity" => true,
      "supports_reasoning_summary_parameter" => true,
      "base_instructions" => "Use tools carefully",
      "model_messages" => %{
        "instructions_template" => "Use tools carefully",
        "instructions_variables" => %{"personality_default" => "Be concise"}
      },
      "truncation_policy" => %{"mode" => "tokens", "limit" => 12000}
    }

    descriptor = ModelMetadata.codex("alias", nil, ModelMetadata.normalize("openai-codex", raw))
    assert descriptor["slug"] == "alias"
    assert descriptor["context_window"] == 128_000
    assert descriptor["supported_reasoning_levels"] == raw["supported_reasoning_levels"]
    assert descriptor["default_reasoning_level"] == "high"
    assert descriptor["input_modalities"] == ["text", "image"]
    assert descriptor["base_instructions"] == raw["base_instructions"]
    assert descriptor["model_messages"] == raw["model_messages"]
    assert descriptor["truncation_policy"] == raw["truncation_policy"]
    assert descriptor["support_verbosity"]
  end

  test "Codex ignores malformed typed metadata and unsupported default efforts" do
    metadata =
      ModelMetadata.normalize("custom", %{
        "supported_reasoning_levels" => [nil, %{"effort" => ""}, "low"],
        "default_reasoning_level" => "high",
        "support_verbosity" => "yes",
        "truncation_policy" => %{"mode" => "invalid", "limit" => -1}
      })

    descriptor = ModelMetadata.codex("local/model", nil, metadata)

    assert descriptor["supported_reasoning_levels"] == [
             %{"effort" => "low", "description" => "low"}
           ]

    assert descriptor["default_reasoning_level"] == nil
    assert descriptor["support_verbosity"] == false
    assert descriptor["truncation_policy"] == %{"mode" => "bytes", "limit" => 10000}
  end
end

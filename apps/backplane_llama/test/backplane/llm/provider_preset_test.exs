defmodule Backplane.LLM.ProviderPresetTest do
  use ExUnit.Case, async: true

  alias Backplane.LLM.ProviderPreset

  test "lists the built-in provider presets" do
    assert [
             "deepseek",
             "z-ai",
             "minimax",
             "opencode",
             "openrouter",
             "ollama",
             "ollama-cloud",
             "vllm",
             "sglang",
             "custom",
             "openai",
             "openai-codex",
             "anthropic",
             "x-ai",
             "google-gemini-developer",
             "moonshot-cn"
           ] = ProviderPreset.keys()
  end

  test "does not expose retired Google compatibility presets" do
    refute ProviderPreset.get("google-ai-studio")
    refute ProviderPreset.get("google-gemini-openai-compatible")
  end

  test "deepseek has openai and anthropic defaults" do
    preset = ProviderPreset.fetch!("deepseek")

    assert preset.default_base_url == "https://api.deepseek.com"
    assert preset.openai.enabled
    assert preset.openai.base_url == "https://api.deepseek.com"
    assert preset.openai.discovery_path == "/models"
    assert preset.anthropic.enabled
    assert preset.anthropic.base_url == "https://api.deepseek.com/anthropic"
    assert preset.anthropic.discovery_path == "/v1/models"
  end

  test "z-ai keeps anthropic disabled by default" do
    preset = ProviderPreset.fetch!("z-ai")

    assert preset.default_base_url == "https://open.bigmodel.cn/api"
    assert preset.openai.enabled
    refute preset.anthropic.enabled
    assert preset.anthropic.base_url == "https://api.z.ai/api/anthropic"
  end

  test "minimax uses the requested China base URL defaults" do
    preset = ProviderPreset.fetch!("minimax")

    assert preset.default_base_url == "https://api.minimaxi.com"
    assert preset.openai.base_url == "https://api.minimaxi.com/v1"
    assert preset.anthropic.base_url == "https://api.minimaxi.com/anthropic"
  end

  test "custom keeps only the openai surface enabled with blank URLs" do
    preset = ProviderPreset.fetch!("custom")

    assert preset.default_base_url == ""
    assert preset.openai.enabled
    assert preset.openai.base_url == ""
    assert preset.openai.discovery_path == nil
    refute preset.anthropic.enabled
    assert preset.anthropic.base_url == ""
    assert preset.anthropic.discovery_path == nil
  end

  test "ollama uses local openai and anthropic compatibility defaults" do
    preset = ProviderPreset.fetch!("ollama")

    assert preset.default_base_url == "http://localhost:11434"
    assert preset.openai.enabled
    assert preset.openai.base_url == "http://localhost:11434/v1"
    assert preset.openai.discovery_path == "/models"
    assert preset.anthropic.enabled
    assert preset.anthropic.base_url == "http://localhost:11434"
    assert preset.anthropic.discovery_path == "/v1/models"
  end

  test "ollama cloud uses hosted openai and anthropic compatibility defaults" do
    preset = ProviderPreset.fetch!("ollama-cloud")

    assert preset.name == "Ollama Cloud"
    assert preset.default_name == "ollama-cloud"
    assert preset.credential_kind == "llm"
    assert preset.credential_auth_type == "api_key"
    assert preset.default_base_url == "https://ollama.com"
    assert preset.openai.enabled
    assert preset.openai.base_url == "https://ollama.com/v1"
    assert preset.openai.discovery_path == "/models"
    assert preset.anthropic.enabled
    assert preset.anthropic.base_url == "https://ollama.com"
    assert preset.anthropic.discovery_path == "/v1/models"
  end

  test "anthropic enables only the anthropic surface" do
    preset = ProviderPreset.fetch!("anthropic")

    assert preset.default_base_url == "https://api.anthropic.com"
    refute preset.openai.enabled
    assert preset.openai.base_url == ""
    assert preset.openai.discovery_path == nil
    assert preset.anthropic.enabled
    assert preset.anthropic.base_url == "https://api.anthropic.com"
    assert preset.anthropic.discovery_path == "/v1/models"
  end

  test "vllm uses local OpenAI and Anthropic defaults on port 8000" do
    preset = ProviderPreset.fetch!("vllm")

    assert preset.name == "vLLM"
    assert preset.default_name == "vllm"
    assert preset.credential_kind == "llm"
    assert preset.default_credential == nil
    assert preset.credential_auth_type == "api_key"
    assert preset.default_base_url == "http://localhost:8000"

    assert preset.openai == %{
             enabled: true,
             base_url: "http://localhost:8000/v1",
             discovery_path: "/models"
           }

    assert preset.anthropic == %{
             enabled: true,
             base_url: "http://localhost:8000",
             discovery_path: nil
           }

    assert preset.docs_urls != []
  end

  test "sglang uses local OpenAI and Anthropic defaults on port 30000" do
    preset = ProviderPreset.fetch!("sglang")

    assert preset.name == "SGLang"
    assert preset.default_name == "sglang"
    assert preset.credential_kind == "llm"
    assert preset.default_credential == nil
    assert preset.credential_auth_type == "api_key"
    assert preset.default_base_url == "http://localhost:30000"

    assert preset.openai == %{
             enabled: true,
             base_url: "http://localhost:30000/v1",
             discovery_path: "/models"
           }

    assert preset.anthropic == %{
             enabled: true,
             base_url: "http://localhost:30000",
             discovery_path: nil
           }

    assert preset.docs_urls != []
  end

  test "self-hosted inference presets declare native wire protocols explicitly" do
    for key <- ["vllm", "sglang"] do
      preset = ProviderPreset.fetch!(key)

      assert ProviderPreset.native_protocols(preset, :openai) == [
               :openai_chat_completions,
               :openai_responses
             ]

      assert ProviderPreset.native_protocols(preset, :anthropic) == [:anthropic_messages]
    end
  end

  test "openrouter and x-ai use openai-compatible defaults" do
    openrouter = ProviderPreset.fetch!("openrouter")
    x_ai = ProviderPreset.fetch!("x-ai")

    assert openrouter.openai.enabled
    assert openrouter.openai.base_url == "https://openrouter.ai/api/v1"
    assert openrouter.openai.discovery_path == "/models"
    refute openrouter.anthropic.enabled

    assert x_ai.openai.enabled
    assert x_ai.openai.base_url == "https://api.x.ai/v1"
    assert x_ai.openai.discovery_path == "/models"
    refute x_ai.anthropic.enabled
  end

  test "openai codex uses the default openai oauth credential" do
    preset = ProviderPreset.fetch!("openai-codex")

    assert preset.default_credential == "openai-codex"
    assert preset.credential_kind == "llm"
    assert preset.credential_auth_type == "openai_oauth"
    assert preset.default_base_url == "https://chatgpt.com/backend-api/codex"
    assert preset.openai.base_url == "https://chatgpt.com/backend-api/codex"
  end

  test "moonshot.cn uses OpenAI-compatible defaults" do
    moonshot = ProviderPreset.fetch!("moonshot-cn")

    assert moonshot.name == "Moonshot.cn"
    assert moonshot.openai.enabled
    assert moonshot.openai.base_url == "https://api.moonshot.cn/v1"
    assert moonshot.openai.discovery_path == "/models"
    refute moonshot.anthropic.enabled
  end

  test "google gemini developer uses the native v1beta API-key surface" do
    preset = ProviderPreset.fetch!("google-gemini-developer")

    assert preset.default_credential == nil
    assert preset.credential_auth_type == "api_key"
    assert preset.default_base_url == "https://generativelanguage.googleapis.com/v1beta"

    assert ProviderPreset.surfaces(preset) == %{
             google: %{
               enabled: true,
               base_url: "https://generativelanguage.googleapis.com/v1beta",
               discovery_path: "/models",
               native_protocols: [:google_generate_content]
             }
           }

    assert ProviderPreset.native_protocols(preset, :google) == [:google_generate_content]
    refute preset.openai.enabled
    refute preset.anthropic.enabled
  end

  test "legacy slots remain available through normalized surfaces" do
    preset = ProviderPreset.fetch!("deepseek")

    assert ProviderPreset.surface(preset, :openai).base_url == preset.openai.base_url
    assert ProviderPreset.surface(preset, :anthropic).base_url == preset.anthropic.base_url
    assert ProviderPreset.surfaces(preset).openai.enabled
    assert ProviderPreset.surfaces(preset).anthropic.enabled
  end

  test "preserves declared OpenAI protocols without widening compatibility presets" do
    for preset <- ProviderPreset.all(), preset.openai.enabled do
      expected =
        case preset.key do
          "openai-codex" -> [:openai_responses]
          _ -> [:openai_chat_completions, :openai_responses]
        end

      assert ProviderPreset.native_protocols(preset, :openai) == expected,
             "unexpected OpenAI default protocols for #{preset.key}"
    end
  end

  test "preserves concrete Codex and Anthropic wire protocols" do
    assert ProviderPreset.native_protocols(ProviderPreset.fetch!("openai"), :openai) == [
             :openai_chat_completions,
             :openai_responses
           ]

    assert ProviderPreset.native_protocols(ProviderPreset.fetch!("openai-codex"), :openai) == [
             :openai_responses
           ]

    assert ProviderPreset.native_protocols(ProviderPreset.fetch!("deepseek"), :openai) == [
             :openai_chat_completions,
             :openai_responses
           ]

    assert ProviderPreset.native_protocols(ProviderPreset.fetch!("deepseek"), :anthropic) == [
             :anthropic_messages
           ]

    assert ProviderPreset.native_protocols(ProviderPreset.fetch!("custom"), :openai) == [
             :openai_chat_completions,
             :openai_responses
           ]
  end
end

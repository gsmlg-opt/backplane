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
             "custom",
             "openai",
             "openai-codex",
             "anthropic",
             "x-ai",
             "google-ai-studio",
             "moonshot-cn"
           ] = ProviderPreset.keys()
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

  test "google ai studio and moonshot.cn use openai-compatible defaults" do
    google = ProviderPreset.fetch!("google-ai-studio")
    moonshot = ProviderPreset.fetch!("moonshot-cn")

    assert google.default_credential == "google-antigravity"
    assert google.credential_kind == "llm"
    assert google.credential_auth_type == "google_oauth"
    assert google.openai.enabled
    assert google.openai.base_url == "https://generativelanguage.googleapis.com/v1beta/openai"
    assert google.openai.discovery_path == "/models"
    refute google.anthropic.enabled

    assert moonshot.name == "Moonshot.cn"
    assert moonshot.openai.enabled
    assert moonshot.openai.base_url == "https://api.moonshot.cn/v1"
    assert moonshot.openai.discovery_path == "/models"
    refute moonshot.anthropic.enabled
  end
end

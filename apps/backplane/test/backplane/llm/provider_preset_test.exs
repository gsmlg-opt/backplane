defmodule Backplane.LLM.ProviderPresetTest do
  use ExUnit.Case, async: true

  alias Backplane.LLM.ProviderPreset

  test "lists the built-in provider presets" do
    assert ["deepseek", "z-ai", "minimax"] = ProviderPreset.keys()
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
end

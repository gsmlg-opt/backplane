defmodule Backplane.LLM.CodexCatalogContractTest do
  use ExUnit.Case, async: true

  alias Backplane.LLM.CodexCatalog

  @required_fields ~w(
    slug display_name description default_reasoning_level supported_reasoning_levels shell_type
    visibility supported_in_api priority additional_speed_tiers service_tiers default_service_tier
    available_access_programs availability_nux upgrade base_instructions model_messages
    include_skills_usage_instructions include_plugin_usage_instructions include_apps_usage_instructions
    supports_reasoning_summary_parameter default_reasoning_summary support_verbosity default_verbosity
    apply_patch_tool_type web_search_tool_type truncation_policy supports_image_detail_original
    effective_context_window_percent experimental_supported_tools input_modalities supports_search_tool
    supports_experimental_context use_responses_lite supports_reasoning_effort_updates
    node_repl_auto_review_required node_repl_disabled auto_review_model_override model_specialty
    tool_mode multi_agent_version multi_agent_reasoning_effort
  )

  test "serializes the Codex 0.159 model info contract without inventing model limits" do
    model = CodexCatalog.serialize_model("vendor-fast", "Vendor Fast", nil, %{}, 10)

    assert Enum.all?(@required_fields, &Map.has_key?(model, &1))
    assert model["slug"] == "vendor-fast"
    assert model["display_name"] == "Vendor Fast"
    assert model["description"] == nil
    assert model["supported_in_api"]
    assert model["priority"] == 10
    assert model["supported_reasoning_levels"] == []
    assert model["context_window"] == nil
    assert model["truncation_policy"] == %{"mode" => "bytes", "limit" => 10_000}
    assert model["include_apps_usage_instructions"]
    assert model["supports_reasoning_summary_parameter"]
    refute Map.has_key?(model, "max_output_tokens")
    refute Map.has_key?(model, "supports_reasoning_summaries")
    refute Map.has_key?(model, "supports_parallel_tool_calls")

    assert Jason.decode!(Jason.encode!(%{"models" => [model]}))["models"] == [model]
  end

  test "catalog overrides preserve public ids while retaining canonical metadata" do
    model =
      CodexCatalog.serialize_model(
        "public-id",
        nil,
        "Configured description",
        %{
          "context_window" => 131_072,
          "supported_reasoning_levels" => [%{"effort" => "high", "description" => "deep"}],
          "default_reasoning_level" => "high"
        },
        2
      )

    assert model["slug"] == "public-id"
    assert model["description"] == "Configured description"
    assert model["context_window"] == 131_072
    assert model["default_reasoning_level"] == "high"
    assert model["supported_reasoning_levels"] == [%{"effort" => "high", "description" => "deep"}]
  end

  test "preserves provider-defined reasoning effort names" do
    model =
      CodexCatalog.serialize_model(
        "custom-reasoning",
        "Custom Reasoning",
        nil,
        %{
          "supported_reasoning_levels" => [
            %{"effort" => "deep-research", "description" => "research"}
          ],
          "default_reasoning_level" => "deep-research"
        }
      )

    assert model["supported_reasoning_levels"] == [
             %{"effort" => "deep-research", "description" => "research"}
           ]

    assert model["default_reasoning_level"] == "deep-research"
  end
end

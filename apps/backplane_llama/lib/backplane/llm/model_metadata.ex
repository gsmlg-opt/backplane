defmodule Backplane.LLM.ModelMetadata do
  @moduledoc """
  Normalizes provider model metadata and builds Codex model descriptors.

  Unknown limits and capabilities are omitted. Original discovery metadata is
  retained under `raw`; Codex-only defaults describe client behavior, not
  inferred model capabilities.
  """

  @default_base_instructions "You are a coding assistant. Follow the user's instructions and use the available tools to help complete their software tasks."

  @spec normalize(String.t() | nil, map() | nil) :: map()
  def normalize(preset_key, metadata) do
    raw = map(metadata)
    capabilities = map(raw["capabilities"])
    levels = reasoning_levels(raw["supported_reasoning_levels"] || raw["reasoning_levels"])

    canonical = %{
      "context_window" => positive_integer(raw["context_window"]),
      "max_output_tokens" =>
        positive_integer(raw["max_output_tokens"] || raw["max_output_length"]),
      "input_modalities" => modalities(raw["input_modalities"]),
      "output_modalities" => modalities(raw["output_modalities"]),
      "supports_tool_calling" =>
        first_boolean([
          raw["supports_tool_calling"],
          capabilities["tool_calling"],
          capabilities["tools"]
        ]),
      "supports_reasoning" =>
        first_boolean([
          raw["supports_reasoning"],
          capabilities["reasoning"],
          reasoning_support(levels)
        ]),
      "supported_reasoning_levels" => levels,
      "default_reasoning_level" => nonblank(raw["default_reasoning_level"]),
      "display_name" =>
        nonblank(raw["display_name"] || provider_display_name(preset_key, raw) || raw["name"]),
      "description" => nonblank(raw["description"])
    }

    preset_key
    |> provider_metadata(raw)
    |> known_fields()
    |> Map.merge(known_fields(canonical))
    |> Map.put("raw", raw)
  end

  @spec codex(String.t(), String.t() | nil, map(), keyword()) :: map()
  def codex(id, display_name, metadata, opts \\ []) do
    raw = map(metadata["raw"])
    levels = metadata["supported_reasoning_levels"] || []
    default_effort = supported_default(raw["default_reasoning_level"], levels)

    descriptor = %{
      "slug" => id,
      "display_name" => nonblank(display_name) || metadata["display_name"] || id,
      "description" => metadata["description"],
      "default_reasoning_level" => default_effort,
      "supported_reasoning_levels" => levels,
      "shell_type" => enum_value(raw["shell_type"], ~w(unified_exec disabled), "unified_exec"),
      "visibility" => enum_value(raw["visibility"], ~w(list hide none), "list"),
      "supported_in_api" => Keyword.get(opts, :supported_in_api, true),
      "priority" => integer(raw["priority"], Keyword.get(opts, :priority, 99)),
      "availability_nux" => nil,
      "upgrade" => nil,
      "base_instructions" => base_instructions(raw),
      "support_verbosity" => boolean(raw["support_verbosity"], false),
      "default_verbosity" => enum_value(raw["default_verbosity"], ~w(low medium high), nil),
      "apply_patch_tool_type" => enum_value(raw["apply_patch_tool_type"], ["freeform"], nil),
      "truncation_policy" => truncation_policy(raw["truncation_policy"]),
      "experimental_supported_tools" => modalities(raw["experimental_supported_tools"]) || [],
      "input_modalities" => codex_modalities(metadata["input_modalities"]),
      "supports_reasoning_summary_parameter" =>
        boolean(raw["supports_reasoning_summary_parameter"], false),
      "supports_reasoning_summaries" => boolean(raw["supports_reasoning_summaries"], false),
      "supports_parallel_tool_calls" => boolean(raw["supports_parallel_tool_calls"], false),
      "include_apps_usage_instructions" => boolean(raw["include_apps_usage_instructions"], false)
    }

    optional = %{
      "context_window" => metadata["context_window"],
      "max_output_tokens" => metadata["max_output_tokens"],
      "max_context_window" => positive_integer(raw["max_context_window"]),
      "auto_compact_token_limit" => positive_integer(raw["auto_compact_token_limit"]),
      "effective_context_window_percent" =>
        context_percent(raw["effective_context_window_percent"]),
      "model_messages" => model_messages(raw["model_messages"])
    }

    Map.merge(descriptor, known_fields(optional))
  end

  defp provider_metadata("openrouter", raw) do
    architecture = map(raw["architecture"])
    provider = map(raw["top_provider"])

    %{
      "context_window" => positive_integer(raw["context_length"] || provider["context_length"]),
      "max_output_tokens" => positive_integer(provider["max_completion_tokens"]),
      "input_modalities" => modalities(architecture["input_modalities"]),
      "output_modalities" => modalities(architecture["output_modalities"]),
      "supports_tool_calling" => parameter_support(raw["supported_parameters"], ["tools"]),
      "supports_reasoning" =>
        parameter_support(raw["supported_parameters"], ["reasoning", "reasoning_effort"])
    }
  end

  defp provider_metadata("vllm", raw) do
    %{"context_window" => positive_integer(raw["max_model_len"])}
  end

  defp provider_metadata("sglang", raw) do
    info = map(raw["sglang"])

    %{
      "context_window" =>
        positive_integer(raw["max_model_len"] || info["context_length"] || raw["context_length"]),
      "input_modalities" => sglang_modalities(info),
      "output_modalities" => if(info["is_generation"] == true, do: ["text"])
    }
  end

  defp provider_metadata(preset_key, raw) when preset_key in ["ollama", "ollama-cloud"] do
    info = if is_map(raw["ollama"]), do: raw["ollama"], else: raw
    model_info = map(info["model_info"])
    architecture = nonblank(model_info["general.architecture"])
    capacity = if architecture, do: model_info["#{architecture}.context_length"]

    %{
      "context_window" => ollama_context(info["parameters"]) || positive_integer(capacity),
      "input_modalities" => ollama_input_modalities(info["capabilities"]),
      "output_modalities" => ollama_output_modalities(info["capabilities"]),
      "supports_tool_calling" => parameter_support(info["capabilities"], ["tools"]),
      "supports_reasoning" => parameter_support(info["capabilities"], ["thinking"])
    }
  end

  defp provider_metadata("anthropic", raw) do
    capabilities = map(raw["capabilities"])

    %{
      "context_window" => positive_integer(raw["max_input_tokens"]),
      "max_output_tokens" => positive_integer(raw["max_tokens"]),
      "supports_reasoning" => capability_support(capabilities["thinking"]),
      "input_modalities" => anthropic_modalities(capabilities),
      "supported_reasoning_levels" => anthropic_efforts(capabilities["effort"])
    }
  end

  defp provider_metadata("google-gemini-developer", raw) do
    %{
      "context_window" => positive_integer(raw["inputTokenLimit"]),
      "max_output_tokens" => positive_integer(raw["outputTokenLimit"]),
      "display_name" => nonblank(raw["displayName"])
    }
  end

  defp provider_metadata(_preset_key, _raw), do: %{}

  defp provider_display_name("google-gemini-developer", raw), do: raw["displayName"]

  defp provider_display_name(_preset_key, _raw), do: nil

  defp ollama_context(parameters) when is_binary(parameters) do
    case Regex.run(~r/^\s*num_ctx\s+(\d+)\s*$/m, parameters) do
      [_, context] -> positive_integer(context)
      _ -> nil
    end
  end

  defp ollama_context(parameters) when is_map(parameters),
    do: positive_integer(parameters["num_ctx"])

  defp ollama_context(_parameters), do: nil

  defp ollama_input_modalities(capabilities) when is_list(capabilities) do
    if "completion" in capabilities do
      if "vision" in capabilities, do: ["text", "image"], else: ["text"]
    end
  end

  defp ollama_input_modalities(_capabilities), do: nil

  defp ollama_output_modalities(capabilities) when is_list(capabilities) do
    if "completion" in capabilities, do: ["text"]
  end

  defp ollama_output_modalities(_capabilities), do: nil

  defp parameter_support(parameters, supported) when is_list(parameters) do
    if modalities(parameters), do: Enum.any?(supported, &(&1 in parameters))
  end

  defp parameter_support(_parameters, _supported), do: nil

  defp sglang_modalities(info) do
    flags = [info["has_image_understanding"], info["has_audio_understanding"]]

    if Enum.any?(flags, &is_boolean/1) do
      ["text"] ++
        if(info["has_image_understanding"] == true, do: ["image"], else: []) ++
        if(info["has_audio_understanding"] == true, do: ["audio"], else: [])
    end
  end

  defp capability_support(%{"supported" => supported}) when is_boolean(supported), do: supported
  defp capability_support(_capability), do: nil

  defp anthropic_modalities(capabilities) do
    case capability_support(capabilities["image_input"]) do
      true -> ["text", "image"]
      false -> ["text"]
      nil -> nil
    end
  end

  defp anthropic_efforts(%{"supported" => true} = effort) do
    ~w(low medium high xhigh max)
    |> Enum.filter(&(capability_support(effort[&1]) == true))
    |> reasoning_levels()
  end

  defp anthropic_efforts(%{"supported" => false}), do: []
  defp anthropic_efforts(_effort), do: nil

  defp reasoning_levels(levels) when is_list(levels) do
    Enum.flat_map(levels, fn
      %{"effort" => effort} = level ->
        if nonblank(effort),
          do: [%{"effort" => effort, "description" => nonblank(level["description"]) || effort}],
          else: []

      effort when is_binary(effort) ->
        if nonblank(effort), do: [%{"effort" => effort, "description" => effort}], else: []

      _level ->
        []
    end)
    |> Enum.uniq_by(& &1["effort"])
  end

  defp reasoning_levels(_levels), do: nil
  defp reasoning_support([_level | _levels]), do: true
  defp reasoning_support(_levels), do: nil

  defp supported_default(effort, levels) do
    if Enum.any?(levels, &(&1["effort"] == effort)), do: effort
  end

  defp modalities(values) when is_list(values) do
    if Enum.all?(values, &(not is_nil(nonblank(&1)))), do: Enum.uniq(values)
  end

  defp modalities(_values), do: nil

  defp codex_modalities(nil), do: ["text"]
  defp codex_modalities(values), do: Enum.filter(values, &(&1 in ~w(text image audio)))

  defp truncation_policy(%{"mode" => mode, "limit" => limit}) when mode in ~w(bytes tokens) do
    case positive_integer(limit) do
      nil -> default_truncation_policy()
      limit -> %{"mode" => mode, "limit" => limit}
    end
  end

  defp truncation_policy(_policy), do: default_truncation_policy()
  defp default_truncation_policy, do: %{"mode" => "bytes", "limit" => 10000}

  defp base_instructions(%{"base_instructions" => instructions}) when is_binary(instructions),
    do: instructions

  defp base_instructions(raw) do
    case map(raw["model_messages"])["instructions_template"] do
      template when is_binary(template) -> template
      _ -> @default_base_instructions
    end
  end

  defp model_messages(%{"instructions_template" => template} = messages)
       when is_binary(template) or is_nil(template) do
    variables = map(messages["instructions_variables"])

    variables =
      Map.take(variables, ~w(personality_default personality_friendly personality_pragmatic))

    variables = Map.filter(variables, fn {_key, value} -> is_binary(value) or is_nil(value) end)

    if map_size(variables) > 0,
      do: %{"instructions_template" => template, "instructions_variables" => variables},
      else: %{"instructions_template" => template}
  end

  defp model_messages(_messages), do: nil

  defp context_percent(value) do
    case positive_integer(value) do
      percent when is_integer(percent) and percent <= 100 -> percent
      _ -> nil
    end
  end

  defp first_boolean(values), do: Enum.find(values, &is_boolean/1)
  defp boolean(value, _default) when is_boolean(value), do: value
  defp boolean(_value, default), do: default

  defp integer(value, _default)
       when is_integer(value) and value >= -2_147_483_648 and value <= 2_147_483_647,
       do: value

  defp integer(_value, default), do: default
  defp enum_value(value, allowed, default), do: if(value in allowed, do: value, else: default)

  defp positive_integer(value)
       when is_integer(value) and value > 0 and value <= 9_223_372_036_854_775_807,
       do: value

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> positive_integer(number)
      _ -> nil
    end
  end

  defp positive_integer(_value), do: nil
  defp nonblank(value) when is_binary(value), do: if(String.trim(value) != "", do: value)
  defp nonblank(_value), do: nil
  defp map(value) when is_map(value), do: value
  defp map(_value), do: %{}
  defp known_fields(metadata), do: Map.reject(metadata, fn {_key, value} -> is_nil(value) end)
end

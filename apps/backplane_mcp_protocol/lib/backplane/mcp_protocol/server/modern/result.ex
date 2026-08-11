defmodule Backplane.McpProtocol.Server.Modern.Result do
  @moduledoc """
  Normalizes callback outcomes for the stateless modern server path.

  The callback's result map remains application-owned except for protocol
  fields that the server must authoritatively provide.
  """

  alias Backplane.McpProtocol.MCP.ElicitationSchema
  alias Backplane.McpProtocol.MCP.Error
  alias Backplane.McpProtocol.Protocol.CacheHint
  alias Backplane.McpProtocol.Server.Frame
  alias Backplane.McpProtocol.Server.Modern.RequestContext

  @server_info_key "io.modelcontextprotocol/serverInfo"
  @input_required_methods ~w(tools/call prompts/get resources/read)

  @spec normalize(String.t(), term(), RequestContext.t(), module() | %{required(:server_info) => map()}) ::
          {:ok, map()} | {:error, Error.t()}
  def normalize(_method, {:error, %Error{} = error, %Frame{}}, %RequestContext{protocol_version: version}, _server_module) do
    if error.code == -32_002 or error.reason == :resource_not_found do
      {:error, Error.for_version(version, :resource_not_found, error.data)}
    else
      {:error, error}
    end
  end

  def normalize(method, {:reply, result, %Frame{}}, %RequestContext{} = context, server_module)
      when is_binary(method) and is_map(result) and (is_atom(server_module) or is_map(server_module)) do
    with {:ok, result_type} <- result_type(result),
         {:ok, meta} <- result_meta(result),
         {:ok, server_info} <- server_info(server_module) do
      result =
        result
        |> Map.put("resultType", result_type)
        |> Map.put("_meta", Map.put(meta, @server_info_key, server_info))

      with {:ok, normalized} <- normalize_success(method, result, context),
           :ok <- json_encodable?(normalized) do
        {:ok, normalized}
      end
    else
      _invalid -> internal_error()
    end
  rescue
    _exception -> internal_error()
  catch
    _kind, _reason -> internal_error()
  end

  def normalize(_method, _callback_outcome, %RequestContext{}, _server_module), do: internal_error()

  defp normalize_success(method, %{"resultType" => "input_required"} = result, context) do
    with true <- method in @input_required_methods,
         true <- Map.has_key?(result, "inputRequests") or Map.has_key?(result, "requestState"),
         true <- valid_optional_field?(result, "inputRequests", &is_map/1),
         true <- valid_optional_field?(result, "requestState", &is_binary/1),
         {:ok, requirements} <- input_requirements(Map.get(result, "inputRequests", %{})),
         :ok <- require_capabilities(requirements, context) do
      normalize_cache(method, result, context)
    else
      {:error, %Error{} = error} -> {:error, error}
      _invalid -> internal_error()
    end
  end

  defp normalize_success(method, result, context), do: normalize_cache(method, result, context)

  defp valid_optional_field?(container, field, validator) do
    case Map.fetch(container, field) do
      :error -> true
      {:ok, value} -> validator.(value)
    end
  end

  defp input_requirements(input_requests) do
    Enum.reduce_while(input_requests, {:ok, []}, fn
      {request_id, request}, {:ok, requirements} when is_binary(request_id) ->
        case request_requirements(request) do
          {:ok, request_requirements} ->
            {:cont, {:ok, request_requirements ++ requirements}}

          :error ->
            {:halt, :error}
        end

      _invalid, _acc ->
        {:halt, :error}
    end)
  end

  defp request_requirements(request) when is_map(request) do
    if bare_request?(request), do: typed_request_requirements(request), else: :error
  end

  defp request_requirements(_request), do: :error

  defp typed_request_requirements(%{"method" => "roots/list"} = request) do
    if optional_params?(request), do: {:ok, [:roots]}, else: :error
  end

  defp typed_request_requirements(%{
         "method" => "sampling/createMessage",
         "params" => %{"messages" => messages, "maxTokens" => max_tokens} = params
       })
       when is_list(messages) and is_number(max_tokens) do
    requirements =
      if Map.has_key?(params, "tools") or Map.has_key?(params, "toolChoice") do
        [:sampling_tools]
      else
        [:sampling]
      end

    if valid_sampling_optionals?(params), do: {:ok, requirements}, else: :error
  end

  defp typed_request_requirements(%{
         "method" => "elicitation/create",
         "params" => %{"mode" => "url", "message" => message, "url" => url}
       })
       when is_binary(message) and is_binary(url) do
    if valid_absolute_uri?(url), do: {:ok, [:elicitation_url]}, else: :error
  end

  defp typed_request_requirements(%{
         "method" => "elicitation/create",
         "params" =>
           %{
             "message" => message,
             "requestedSchema" => %{"type" => "object", "properties" => properties} = requested_schema
           } = params
       })
       when is_binary(message) and is_map(properties) do
    if Map.get(params, "mode", "form") == "form" and
         ElicitationSchema.validate(requested_schema) == :ok do
      {:ok, [:elicitation_form]}
    else
      :error
    end
  end

  defp typed_request_requirements(_request), do: :error

  defp bare_request?(request) do
    not Map.has_key?(request, "id") and not Map.has_key?(request, :id) and
      not Map.has_key?(request, "jsonrpc") and not Map.has_key?(request, :jsonrpc)
  end

  defp optional_params?(request) do
    case Map.fetch(request, "params") do
      :error ->
        true

      {:ok, params} when is_map(params) ->
        Enum.all?(Map.keys(params), &(&1 == "_meta")) and
          valid_optional_field?(params, "_meta", &is_map/1)

      {:ok, _invalid} ->
        false
    end
  end

  defp valid_sampling_optionals?(params) do
    Enum.all?(params["messages"], &valid_sampling_message?/1) and
      valid_optional_field?(params, "modelPreferences", &valid_model_preferences?/1) and
      valid_optional_field?(params, "systemPrompt", &is_binary/1) and
      valid_optional_field?(params, "includeContext", &(&1 in ~w(none thisServer allServers))) and
      valid_optional_field?(params, "temperature", &is_number/1) and
      valid_optional_field?(params, "stopSequences", &string_list?/1) and
      valid_optional_field?(params, "metadata", &is_map/1) and
      valid_optional_field?(params, "tools", &valid_sampling_tools?/1) and
      valid_optional_field?(params, "toolChoice", &valid_tool_choice?/1)
  end

  defp valid_model_preferences?(preferences) when is_map(preferences) do
    valid_optional_field?(preferences, "hints", &valid_model_hints?/1) and
      valid_optional_field?(preferences, "costPriority", &valid_priority?/1) and
      valid_optional_field?(preferences, "speedPriority", &valid_priority?/1) and
      valid_optional_field?(preferences, "intelligencePriority", &valid_priority?/1)
  end

  defp valid_model_preferences?(_preferences), do: false

  defp valid_model_hints?(hints) when is_list(hints), do: Enum.all?(hints, &valid_model_hint?/1)
  defp valid_model_hints?(_hints), do: false

  defp valid_model_hint?(hint) when is_map(hint) do
    valid_optional_field?(hint, "name", &is_binary/1)
  end

  defp valid_model_hint?(_hint), do: false

  defp valid_priority?(priority), do: is_number(priority) and priority >= 0 and priority <= 1

  defp valid_sampling_message?(%{"role" => role, "content" => content} = message) when role in ~w(user assistant) do
    valid_sampling_content?(content) and valid_optional_field?(message, "_meta", &is_map/1)
  end

  defp valid_sampling_message?(_message), do: false

  defp valid_sampling_content?(content) when is_map(content), do: valid_sampling_content_block?(content)

  defp valid_sampling_content?(content) when is_list(content) do
    Enum.all?(content, &valid_sampling_content_block?/1)
  end

  defp valid_sampling_content?(_content), do: false

  defp valid_sampling_content_block?(%{"type" => type} = block) when type in ~w(text image audio),
    do: valid_content_block?(block)

  defp valid_sampling_content_block?(%{"type" => "tool_use", "id" => id, "name" => name, "input" => input} = block)
       when is_binary(id) and is_binary(name) and is_map(input) do
    valid_optional_field?(block, "_meta", &is_map/1)
  end

  defp valid_sampling_content_block?(%{"type" => "tool_result", "toolUseId" => tool_use_id, "content" => content} = block)
       when is_binary(tool_use_id) and is_list(content) do
    Enum.all?(content, &valid_content_block?/1) and
      valid_optional_field?(block, "isError", &is_boolean/1) and
      valid_optional_field?(block, "_meta", &is_map/1)
  end

  defp valid_sampling_content_block?(_content), do: false

  defp valid_content_block?(%{"type" => "text", "text" => text} = block) when is_binary(text),
    do: valid_annotated_block?(block)

  defp valid_content_block?(%{"type" => "image", "data" => data, "mimeType" => mime_type} = block)
       when is_binary(data) and is_binary(mime_type),
       do: valid_annotated_block?(block)

  defp valid_content_block?(%{"type" => "audio", "data" => data, "mimeType" => mime_type} = block)
       when is_binary(data) and is_binary(mime_type),
       do: valid_annotated_block?(block)

  defp valid_content_block?(%{"type" => "resource_link", "name" => name, "uri" => uri} = block)
       when is_binary(name) and is_binary(uri) do
    valid_absolute_uri?(uri) and
      valid_optional_field?(block, "title", &is_binary/1) and
      valid_optional_field?(block, "description", &is_binary/1) and
      valid_optional_field?(block, "mimeType", &is_binary/1) and
      valid_optional_field?(block, "icons", &valid_icons?/1) and
      valid_optional_field?(block, "size", &is_number/1) and
      valid_annotated_block?(block)
  end

  defp valid_content_block?(%{"type" => "resource", "resource" => resource} = block) when is_map(resource) do
    valid_embedded_resource?(resource) and valid_annotated_block?(block)
  end

  defp valid_content_block?(_content), do: false

  defp valid_annotated_block?(block) do
    valid_optional_field?(block, "annotations", &valid_annotations?/1) and
      valid_optional_field?(block, "_meta", &is_map/1)
  end

  defp valid_annotations?(annotations) when is_map(annotations) do
    valid_optional_field?(annotations, "audience", &valid_audience?/1) and
      valid_optional_field?(annotations, "priority", &valid_priority?/1) and
      valid_optional_field?(annotations, "lastModified", &is_binary/1)
  end

  defp valid_annotations?(_annotations), do: false

  defp valid_audience?(audience) when is_list(audience) do
    Enum.all?(audience, &(&1 in ~w(user assistant)))
  end

  defp valid_audience?(_audience), do: false

  defp valid_embedded_resource?(%{"uri" => uri} = resource) when is_binary(uri) do
    valid_absolute_uri?(uri) and
      valid_optional_field?(resource, "mimeType", &is_binary/1) and
      valid_optional_field?(resource, "_meta", &is_map/1) and
      valid_embedded_resource_payload?(resource)
  end

  defp valid_embedded_resource?(_resource), do: false

  defp valid_embedded_resource_payload?(resource) do
    case {Map.fetch(resource, "text"), Map.fetch(resource, "blob")} do
      {{:ok, text}, :error} -> is_binary(text)
      {:error, {:ok, blob}} -> is_binary(blob)
      _missing_or_ambiguous -> false
    end
  end

  defp valid_sampling_tools?(tools) when is_list(tools) do
    Enum.all?(tools, &valid_sampling_tool?/1)
  end

  defp valid_sampling_tools?(_tools), do: false

  defp valid_sampling_tool?(%{"name" => name, "inputSchema" => input_schema} = tool)
       when is_binary(name) and is_map(input_schema) do
    valid_input_schema?(input_schema) and
      valid_optional_field?(tool, "title", &is_binary/1) and
      valid_optional_field?(tool, "description", &is_binary/1) and
      valid_optional_field?(tool, "icons", &valid_icons?/1) and
      valid_optional_field?(tool, "outputSchema", &valid_output_schema?/1) and
      valid_optional_field?(tool, "annotations", &valid_tool_annotations?/1) and
      valid_optional_field?(tool, "_meta", &is_map/1)
  end

  defp valid_sampling_tool?(_tool), do: false

  defp valid_input_schema?(%{"type" => "object"} = schema) do
    valid_optional_field?(schema, "$schema", &is_binary/1)
  end

  defp valid_input_schema?(_schema), do: false

  defp valid_output_schema?(schema) when is_map(schema) do
    valid_optional_field?(schema, "$schema", &is_binary/1)
  end

  defp valid_output_schema?(_schema), do: false

  defp valid_tool_annotations?(annotations) when is_map(annotations) do
    valid_optional_field?(annotations, "title", &is_binary/1) and
      valid_optional_field?(annotations, "readOnlyHint", &is_boolean/1) and
      valid_optional_field?(annotations, "destructiveHint", &is_boolean/1) and
      valid_optional_field?(annotations, "idempotentHint", &is_boolean/1) and
      valid_optional_field?(annotations, "openWorldHint", &is_boolean/1)
  end

  defp valid_tool_annotations?(_annotations), do: false

  defp valid_icons?(icons) when is_list(icons), do: Enum.all?(icons, &valid_icon?/1)
  defp valid_icons?(_icons), do: false

  defp valid_icon?(%{"src" => src} = icon) when is_binary(src) do
    valid_absolute_uri?(src) and
      valid_optional_field?(icon, "mimeType", &is_binary/1) and
      valid_optional_field?(icon, "sizes", &string_list?/1) and
      valid_optional_field?(icon, "theme", &(&1 in ~w(dark light)))
  end

  defp valid_icon?(_icon), do: false

  defp valid_tool_choice?(choice) when is_map(choice) do
    case Map.fetch(choice, "mode") do
      :error -> true
      {:ok, mode} -> mode in ~w(auto required none)
    end
  end

  defp valid_tool_choice?(_choice), do: false

  defp string_list?(values) when is_list(values), do: Enum.all?(values, &is_binary/1)
  defp string_list?(_values), do: false

  defp valid_absolute_uri?(value) do
    match?({:ok, %URI{scheme: scheme}} when is_binary(scheme) and scheme != "", URI.new(value))
  end

  defp require_capabilities(requirements, %RequestContext{} = context) do
    capabilities = normalize_keys(context.client_capabilities)

    missing =
      requirements
      |> Enum.uniq()
      |> Enum.reject(&capability_satisfied?(&1, capabilities))
      |> required_capabilities()

    if map_size(missing) == 0 do
      :ok
    else
      {:error,
       Error.for_version(context.protocol_version, :missing_client_capability, %{
         requiredCapabilities: missing
       })}
    end
  end

  defp capability_satisfied?(:roots, capabilities), do: is_map(capabilities["roots"])
  defp capability_satisfied?(:sampling, capabilities), do: is_map(capabilities["sampling"])

  defp capability_satisfied?(:sampling_tools, capabilities) do
    match?(%{"tools" => tools} when is_map(tools), capabilities["sampling"])
  end

  defp capability_satisfied?(:elicitation_form, capabilities) do
    case capabilities["elicitation"] do
      capability when is_map(capability) and map_size(capability) == 0 -> true
      %{"form" => form} when is_map(form) -> true
      _missing -> false
    end
  end

  defp capability_satisfied?(:elicitation_url, capabilities) do
    match?(%{"url" => url} when is_map(url), capabilities["elicitation"])
  end

  defp required_capabilities(requirements) do
    Enum.reduce(requirements, %{}, fn
      :roots, acc -> Map.put(acc, "roots", %{})
      :sampling, acc -> Map.put_new(acc, "sampling", %{})
      :sampling_tools, acc -> put_in(acc, [Access.key("sampling", %{}), "tools"], %{})
      :elicitation_form, acc -> put_in(acc, [Access.key("elicitation", %{}), "form"], %{})
      :elicitation_url, acc -> put_in(acc, [Access.key("elicitation", %{}), "url"], %{})
    end)
  end

  defp normalize_cache(method, result, context) do
    if CacheHint.cacheable_method?(method) do
      if result["resultType"] == "input_required" or retry_derived?(context) do
        {:ok, CacheHint.put(result, CacheHint.default())}
      else
        case CacheHint.new(result) do
          {:ok, hint} -> {:ok, CacheHint.put(result, hint)}
          {:error, _reason} -> internal_error()
        end
      end
    else
      {:ok, result}
    end
  end

  defp retry_derived?(%RequestContext{request: %{"params" => params}}) when is_map(params) do
    Map.has_key?(params, "inputResponses") or Map.has_key?(params, "requestState")
  end

  defp retry_derived?(_context), do: false

  defp result_type(result) do
    case Map.fetch(result, "resultType") do
      :error -> {:ok, "complete"}
      {:ok, result_type} when is_binary(result_type) -> {:ok, result_type}
      {:ok, _invalid} -> :error
    end
  end

  defp result_meta(result) do
    case Map.fetch(result, "_meta") do
      :error ->
        {:ok, %{}}

      {:ok, meta} when is_map(meta) ->
        if Enum.all?(Map.keys(meta), &(is_binary(&1) or is_atom(&1))) do
          {:ok, normalize_keys(meta)}
        else
          :error
        end

      {:ok, _invalid} ->
        :error
    end
  end

  defp server_info(%{server_info: info}) when is_map(info), do: normalize_implementation(info)

  defp server_info(server_module) when is_atom(server_module) do
    case server_module.server_info() do
      info when is_map(info) -> normalize_implementation(info)
      _invalid -> :error
    end
  end

  defp server_info(_invalid), do: :error

  defp normalize_implementation(info) do
    info = normalize_keys(info)

    case info do
      %{"name" => name, "version" => version} when is_binary(name) and is_binary(version) ->
        if valid_optional_field?(info, "title", &is_binary/1) and
             valid_optional_field?(info, "description", &is_binary/1) and
             valid_optional_field?(info, "websiteUrl", &valid_absolute_uri?/1) and
             valid_optional_field?(info, "icons", &valid_icons?/1) do
          {:ok, info}
        else
          :error
        end

      _invalid ->
        :error
    end
  end

  defp normalize_keys(value) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _nested} -> if is_binary(key), do: 1, else: 0 end)
    |> Enum.reduce(%{}, fn {key, nested}, acc ->
      Map.put(acc, normalize_key(key), normalize_keys(nested))
    end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: key

  defp json_encodable?(result) do
    _encoded = JSON.encode!(result)
    :ok
  end

  defp internal_error, do: {:error, Error.protocol(:internal_error)}
end

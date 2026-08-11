defmodule Backplane.McpProtocol.Client.Negotiation do
  @moduledoc false

  alias Backplane.McpProtocol.Client.Operation
  alias Backplane.McpProtocol.Client.Request
  alias Backplane.McpProtocol.Client.State
  alias Backplane.McpProtocol.MCP.Error
  alias Backplane.McpProtocol.Protocol
  alias Backplane.McpProtocol.Protocol.Profile
  alias Backplane.McpProtocol.Protocol.Registry
  alias Backplane.McpProtocol.Transport.STDIO
  alias Backplane.McpProtocol.Transport.StreamableHTTP

  @protocol_version_key "io.modelcontextprotocol/protocolVersion"
  @client_capabilities_key "io.modelcontextprotocol/clientCapabilities"
  @client_info_key "io.modelcontextprotocol/clientInfo"
  @server_info_key "io.modelcontextprotocol/serverInfo"

  @extension_identifier_pattern ~r/\A[A-Za-z](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z](?:[A-Za-z0-9-]*[A-Za-z0-9])?)*\/(?:[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?)?\z/
  @json_object_capabilities ~w(logging completions)
  @boolean_capability_fields %{
    "prompts" => ["listChanged"],
    "resources" => ["subscribe", "listChanged"],
    "tools" => ["listChanged"]
  }

  @stdio_legacy_errors [:parse_error, :invalid_request, :method_not_found, :invalid_params]

  @type action ::
          {:send, Operation.t(), State.t()}
          | {:ready, State.t()}
          | {:error, Error.t(), State.t()}

  @spec begin(State.t()) :: action()
  def begin(%State{protocol_preference: :auto} = state) do
    case preferred_modern_version() do
      nil -> fail(state, unsupported_version_error([]))
      version -> discover(state, version)
    end
  end

  def begin(%State{protocol_preference: version} = state) when is_binary(version) do
    case Registry.profile(version) do
      {:ok, %Profile{era: :modern}} -> discover(state, version)
      {:ok, %Profile{era: :legacy}} -> initialize(state, version)
      :error -> fail(state, unsupported_version_error([]))
    end
  end

  def begin(%State{} = state) do
    fail(state, Error.protocol(:invalid_params, %{message: "Invalid protocol preference"}))
  end

  @spec handle_result(State.t(), Request.t(), map()) :: action()
  def handle_result(%State{} = state, %Request{method: "server/discover"} = request, result) when is_map(result) do
    handle_discovery_result(state, request, result)
  end

  def handle_result(%State{} = state, %Request{method: "initialize"}, result) when is_map(result) do
    handle_initialize_result(state, result)
  end

  def handle_result(%State{} = state, %Request{}, _result) do
    fail(
      state,
      Error.protocol(:internal_error, %{message: "Unexpected response during protocol negotiation"})
    )
  end

  @spec handle_error(State.t(), Request.t(), Error.t()) :: action()
  def handle_error(%State{} = state, %Request{method: "server/discover"} = request, %Error{} = error) do
    state = %{state | era: :modern}

    case transport_kind(state) do
      :streamable_http -> handle_http_discovery_error(state, request, error)
      :stdio -> handle_stdio_discovery_error(state, request, error)
      _other -> fail(state, error)
    end
  end

  def handle_error(%State{} = state, %Request{}, %Error{} = error), do: fail(state, error)

  defp handle_discovery_result(state, request, result) do
    with :ok <- validate_result_type(result["resultType"]),
         {:ok, peer_versions} <- validate_peer_versions(result["supportedVersions"]),
         {:ok, capabilities} <- validate_capabilities(result["capabilities"]),
         :ok <- validate_cache_hint(result),
         :ok <- validate_instructions(result),
         {:ok, server_info} <- validate_discovery_metadata(result),
         {:ok, version} <- select_modern_version(state, peer_versions) do
      state = %{
        state
        | discovery: result,
          peer_versions: peer_versions,
          server_capabilities: capabilities,
          server_info: server_info,
          negotiation_error: nil
      }

      if requested_version(request) == version do
        {:ready,
         %{
           state
           | negotiation_status: :ready,
             era: :modern,
             protocol_version: version,
             negotiated_version: version
         }}
      else
        discover(state, version)
      end
    else
      {:error, %Error{} = error} -> fail(state, error)
    end
  end

  defp handle_initialize_result(state, result) do
    version = result["protocolVersion"]
    capabilities = result["capabilities"]
    server_info = result["serverInfo"]

    with true <- is_binary(version),
         {:ok, %Profile{era: :legacy}} <- Registry.profile(version),
         true <- is_map(capabilities),
         true <- is_map(server_info) do
      {:ready,
       %{
         state
         | negotiation_status: :ready,
           era: :legacy,
           protocol_version: version,
           negotiated_version: version,
           peer_versions: [version],
           server_capabilities: capabilities,
           server_info: server_info,
           discovery: nil,
           negotiation_error: nil
       }}
    else
      _invalid ->
        fail(
          state,
          Error.protocol(:invalid_params, %{
            message: "Invalid initialize result"
          })
        )
    end
  end

  defp handle_stdio_discovery_error(%State{protocol_pinned?: true} = state, _request, error) do
    fail(state, error)
  end

  defp handle_stdio_discovery_error(state, request, %Error{reason: :unsupported_protocol_version} = error) do
    retry_unsupported_version(state, request, error)
  end

  defp handle_stdio_discovery_error(state, _request, %Error{reason: reason}) when reason in @stdio_legacy_errors do
    initialize(state, Protocol.fallback_version())
  end

  defp handle_stdio_discovery_error(state, _request, %Error{reason: :request_timeout}) do
    initialize(state, Protocol.fallback_version())
  end

  defp handle_stdio_discovery_error(state, _request, error), do: fail(state, error)

  defp handle_http_discovery_error(state, request, %Error{reason: :unsupported_protocol_version} = error) do
    retry_unsupported_version(state, request, error)
  end

  defp handle_http_discovery_error(state, request, error) do
    case classify_http_error(error) do
      {:json_rpc, %Error{} = json_rpc_error} ->
        handle_recognized_modern_error(state, request, json_rpc_error)

      :unrecognized_legacy_response when not state.protocol_pinned? ->
        initialize(state, Protocol.fallback_version())

      _other ->
        fail(state, error)
    end
  end

  defp handle_recognized_modern_error(state, request, %Error{reason: :unsupported_protocol_version} = error) do
    retry_unsupported_version(state, request, error)
  end

  defp handle_recognized_modern_error(state, _request, error), do: fail(state, error)

  defp retry_unsupported_version(%State{protocol_pinned?: true} = state, _request, error) do
    fail(state, error)
  end

  defp retry_unsupported_version(state, request, error) do
    requested_version = requested_version(request)

    case supported_versions(error, requested_version) do
      {:ok, peer_versions} ->
        case select_modern_version(state, peer_versions) do
          {:ok, version} when version != requested_version ->
            state = %{state | peer_versions: peer_versions, negotiation_error: nil}
            discover(state, version)

          _no_new_version ->
            fail(state, error)
        end

      :error ->
        fail(state, error)
    end
  end

  defp discover(state, version) do
    metadata = %{
      @protocol_version_key => version,
      @client_capabilities_key => state.capabilities
    }

    metadata =
      if valid_client_info?(state.client_info) do
        Map.put(metadata, @client_info_key, state.client_info)
      else
        metadata
      end

    operation =
      Operation.new(%{
        method: "server/discover",
        params: %{"_meta" => metadata},
        timeout: state.timeout
      })

    {:send, operation,
     %{
       state
       | negotiation_status: :discovering,
         era: :modern,
         protocol_version: version,
         negotiated_version: nil,
         negotiation_error: nil
     }}
  end

  defp initialize(state, version) do
    operation =
      Operation.new(%{
        method: "initialize",
        params: %{
          "protocolVersion" => version,
          "capabilities" => state.capabilities,
          "clientInfo" => state.client_info
        },
        timeout: state.timeout
      })

    {:send, operation,
     %{
       state
       | negotiation_status: :initializing,
         era: :legacy,
         protocol_version: version,
         negotiated_version: nil,
         server_capabilities: nil,
         server_info: nil,
         discovery: nil,
         negotiation_error: nil
     }}
  end

  defp fail(state, error) do
    {:error, error, %{state | negotiation_status: :failed, negotiation_error: error}}
  end

  defp validate_peer_versions(versions) when is_list(versions) do
    if Enum.all?(versions, &is_binary/1) do
      {:ok, Enum.uniq(versions)}
    else
      invalid_discovery_result("supportedVersions must contain only strings")
    end
  end

  defp validate_peer_versions(_versions) do
    invalid_discovery_result("supportedVersions must be an array")
  end

  defp validate_result_type("complete"), do: :ok
  defp validate_result_type(_result_type), do: invalid_discovery_result("resultType must be complete")

  defp validate_capabilities(capabilities) when is_map(capabilities) do
    valid? =
      json_object?(capabilities) and
        Enum.all?(@json_object_capabilities, &valid_optional_json_object?(capabilities, &1)) and
        Enum.all?(@boolean_capability_fields, fn {capability, fields} ->
          valid_optional_boolean_capability?(capabilities, capability, fields)
        end) and
        valid_optional_object_map?(capabilities, "experimental") and
        valid_extensions?(capabilities)

    if valid?,
      do: {:ok, capabilities},
      else: invalid_discovery_result("capabilities must match ServerCapabilities")
  end

  defp validate_capabilities(_capabilities), do: invalid_discovery_result("capabilities must be an object")

  defp valid_optional_json_object?(container, field) do
    case Map.fetch(container, field) do
      :error -> true
      {:ok, value} -> json_object?(value)
    end
  end

  defp valid_optional_boolean_capability?(container, capability, fields) do
    case Map.fetch(container, capability) do
      :error ->
        true

      {:ok, value} when is_map(value) ->
        Enum.all?(fields, fn field ->
          case Map.fetch(value, field) do
            :error -> true
            {:ok, declared} -> is_boolean(declared)
          end
        end)

      {:ok, _invalid} ->
        false
    end
  end

  defp valid_optional_object_map?(container, field) do
    case Map.fetch(container, field) do
      :error ->
        true

      {:ok, value} when is_map(value) ->
        Enum.all?(value, fn {key, nested} -> is_binary(key) and json_object?(nested) end)

      {:ok, _invalid} ->
        false
    end
  end

  defp valid_extensions?(capabilities) do
    case Map.fetch(capabilities, "extensions") do
      :error ->
        true

      {:ok, extensions} when is_map(extensions) ->
        Enum.all?(extensions, fn {identifier, settings} ->
          extension_identifier?(identifier) and json_object?(settings)
        end)

      {:ok, _invalid} ->
        false
    end
  end

  defp extension_identifier?(identifier) when is_binary(identifier) do
    Regex.match?(@extension_identifier_pattern, identifier)
  end

  defp extension_identifier?(_identifier), do: false

  defp json_object?(value) when is_map(value) do
    Enum.all?(value, fn {key, nested} -> is_binary(key) and json_value?(nested) end)
  end

  defp json_object?(_value), do: false

  defp json_value?(value) when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value), do: true

  defp json_value?(value) when is_list(value), do: Enum.all?(value, &json_value?/1)
  defp json_value?(value) when is_map(value), do: json_object?(value)
  defp json_value?(_value), do: false

  defp validate_cache_hint(result) do
    with {:ok, ttl_ms} when is_integer(ttl_ms) and ttl_ms >= 0 <- Map.fetch(result, "ttlMs"),
         {:ok, scope} when scope in ["public", "private"] <- Map.fetch(result, "cacheScope") do
      :ok
    else
      _invalid -> invalid_discovery_result("ttlMs and cacheScope must be valid")
    end
  end

  defp validate_instructions(result) do
    case Map.fetch(result, "instructions") do
      :error -> :ok
      {:ok, instructions} when is_binary(instructions) -> :ok
      {:ok, _invalid} -> invalid_discovery_result("instructions must be a string")
    end
  end

  defp validate_discovery_metadata(result) do
    case Map.fetch(result, "_meta") do
      :error -> {:ok, nil}
      {:ok, metadata} when is_map(metadata) -> validate_server_info(metadata)
      {:ok, _invalid} -> invalid_discovery_result("_meta must be an object")
    end
  end

  defp validate_server_info(metadata) do
    case Map.fetch(metadata, @server_info_key) do
      :error ->
        {:ok, nil}

      {:ok, info} when is_map(info) ->
        if valid_client_info?(info),
          do: {:ok, info},
          else: invalid_discovery_result("serverInfo must be a valid Implementation")

      {:ok, _invalid} ->
        invalid_discovery_result("serverInfo must be a valid Implementation")
    end
  end

  defp invalid_discovery_result(message) do
    {:error, Error.protocol(:invalid_params, %{message: "Invalid server/discover result: #{message}"})}
  end

  defp select_modern_version(%State{protocol_pinned?: true, protocol_preference: version}, peer_versions) do
    if version in peer_versions and modern_version?(version) do
      {:ok, version}
    else
      {:error, unsupported_version_error(peer_versions, version)}
    end
  end

  defp select_modern_version(_state, peer_versions) do
    case Enum.find(local_modern_versions(), &(&1 in peer_versions)) do
      nil -> {:error, unsupported_version_error(peer_versions)}
      version -> {:ok, version}
    end
  end

  defp preferred_modern_version, do: List.first(local_modern_versions())

  defp local_modern_versions do
    Enum.filter(Registry.supported_versions(), &modern_version?/1)
  end

  defp modern_version?(version) do
    match?({:ok, %Profile{era: :modern}}, Registry.profile(version))
  end

  defp unsupported_version_error(peer_versions, requested \\ nil) do
    data = %{
      "requested" => requested,
      "supported" => peer_versions,
      "clientSupported" => local_modern_versions()
    }

    Error.for_version("2026-07-28", :unsupported_protocol_version, data)
  end

  defp requested_version(request) do
    get_in(request.params, ["_meta", @protocol_version_key])
  end

  defp supported_versions(%Error{data: %{"requested" => requested, "supported" => versions}}, requested)
       when is_binary(requested) and is_list(versions) do
    if Enum.all?(versions, &is_binary/1), do: {:ok, Enum.uniq(versions)}, else: :error
  end

  defp supported_versions(_error, _requested), do: :error

  defp classify_http_error(%Error{data: data}) when is_map(data) do
    case data[:original_reason] || data["original_reason"] do
      {:http_error, status, body} -> classify_http_response(status, body)
      _other -> :other
    end
  end

  defp classify_http_error(_error), do: :other

  defp classify_http_response(400, body) do
    case decode_json_rpc_error(body) do
      {:ok, error} ->
        {:json_rpc, error}

      :malformed_modern ->
        :malformed_modern

      :unrecognized ->
        :unrecognized_legacy_response
    end
  end

  defp classify_http_response(404, body) do
    case decode_json_rpc_error(body) do
      :unrecognized -> :unrecognized_legacy_response
      _json_rpc_looking -> :other
    end
  end

  defp classify_http_response(_status, _body), do: :other

  defp decode_json_rpc_error(body) when is_binary(body) do
    case JSON.decode(body) do
      {:ok,
       %{
         "jsonrpc" => "2.0",
         "error" => %{"code" => code, "message" => message} = json_error
       }}
      when is_integer(code) and is_binary(message) ->
        {:ok, Error.from_json_rpc(json_error)}

      {:ok, %{} = decoded} ->
        if Map.has_key?(decoded, "jsonrpc") or Map.has_key?(decoded, "error") do
          :malformed_modern
        else
          :unrecognized
        end

      _invalid ->
        :unrecognized
    end
  end

  defp decode_json_rpc_error(_body), do: :unrecognized

  defp transport_kind(%State{transport: %{layer: STDIO}}), do: :stdio
  defp transport_kind(%State{transport: %{layer: StreamableHTTP}}), do: :streamable_http
  defp transport_kind(_state), do: :other

  defp valid_client_info?(%{"name" => name, "version" => version} = info) when is_binary(name) and is_binary(version) do
    valid_optional_string?(info, "title") and
      valid_optional_string?(info, "description") and
      valid_optional_uri?(info, "websiteUrl") and
      valid_optional_icons?(info)
  end

  defp valid_client_info?(_info), do: false

  defp valid_optional_string?(info, key), do: valid_optional?(info, key, &is_binary/1)

  defp valid_optional_uri?(info, key) do
    valid_optional?(info, key, fn value ->
      is_binary(value) and
        match?({:ok, %URI{scheme: scheme}} when is_binary(scheme) and scheme != "", URI.new(value))
    end)
  end

  defp valid_optional_icons?(info) do
    valid_optional?(info, "icons", fn
      icons when is_list(icons) -> Enum.all?(icons, &valid_icon?/1)
      _invalid -> false
    end)
  end

  defp valid_icon?(%{"src" => src} = icon) when is_binary(src) do
    valid_optional_uri?(%{"uri" => src}, "uri") and
      valid_optional_string?(icon, "mimeType") and
      valid_optional?(icon, "sizes", fn values -> is_list(values) and Enum.all?(values, &is_binary/1) end) and
      valid_optional?(icon, "theme", &(&1 in ~w(light dark)))
  end

  defp valid_icon?(_icon), do: false

  defp valid_optional?(container, key, validator) do
    case Map.fetch(container, key) do
      :error -> true
      {:ok, value} -> validator.(value)
    end
  end
end

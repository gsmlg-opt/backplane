defmodule Backplane.McpProtocol.Server.Modern.RequestContext do
  @moduledoc """
  Validated, request-local context for the stateless modern server path.

  The protocol envelope remains separate from transport state. In particular,
  the protocol version and client capabilities must be present in the body even
  when equivalent HTTP headers are available.
  """

  alias Backplane.McpProtocol.MCP.Error
  alias Backplane.McpProtocol.Protocol.Profile
  alias Backplane.McpProtocol.Server.Context

  @protocol_version_key "io.modelcontextprotocol/protocolVersion"
  @client_capabilities_key "io.modelcontextprotocol/clientCapabilities"
  @client_info_key "io.modelcontextprotocol/clientInfo"
  @log_level_key "io.modelcontextprotocol/logLevel"
  @log_levels ~w(debug info notice warning error critical alert emergency)

  @enforce_keys [
    :profile,
    :protocol_version,
    :client_capabilities,
    :request_meta,
    :request,
    :method,
    :request_id
  ]
  defstruct [
    :profile,
    :protocol_version,
    :client_info,
    :log_level,
    :progress_token,
    :input_responses,
    :request_state,
    :request,
    :method,
    :request_id,
    :remote_ip,
    :auth,
    client_capabilities: %{},
    request_meta: %{},
    headers: %{},
    assigns: %{},
    transport: :stdio
  ]

  @type t :: %__MODULE__{
          profile: Profile.t(),
          protocol_version: String.t(),
          client_capabilities: map(),
          client_info: map() | nil,
          log_level: String.t() | nil,
          progress_token: String.t() | number() | nil,
          input_responses: map() | nil,
          request_state: String.t() | nil,
          request_meta: map(),
          request: map(),
          method: String.t(),
          request_id: String.t() | integer(),
          headers: %{optional(String.t()) => String.t()},
          remote_ip: :inet.ip_address() | nil,
          auth: term(),
          assigns: map(),
          transport: atom()
        }

  @spec build(Profile.t(), map(), map()) :: {:ok, t()} | {:error, Error.t()}
  def build(%Profile{era: :modern} = profile, request, transport_context)
      when is_map(request) and is_map(transport_context) do
    with {:ok, params} <- require_map(request["params"], "params"),
         {:ok, meta} <- require_map(params["_meta"], "params._meta"),
         {:ok, protocol_version} <- require_string(meta[@protocol_version_key], @protocol_version_key),
         :ok <- require_profile_version(protocol_version, profile.version),
         {:ok, client_capabilities} <-
           require_map(meta[@client_capabilities_key], @client_capabilities_key),
         :ok <- validate_client_capabilities(client_capabilities),
         {:ok, client_info} <- optional_client_info(meta),
         {:ok, log_level} <- optional_log_level(meta),
         {:ok, progress_token} <- optional_progress_token(meta),
         {:ok, input_responses} <- optional_map(params, "inputResponses"),
         {:ok, request_state} <- optional_string(params, "requestState") do
      {:ok,
       %__MODULE__{
         profile: profile,
         protocol_version: protocol_version,
         client_capabilities: client_capabilities,
         client_info: client_info,
         log_level: log_level,
         progress_token: progress_token,
         input_responses: input_responses,
         request_state: request_state,
         request_meta: meta,
         request: request,
         method: request["method"],
         request_id: request["id"],
         headers: normalize_headers(transport_context),
         remote_ip: transport_context[:remote_ip],
         auth: transport_context[:auth],
         assigns: normalize_assigns(transport_context[:assigns]),
         transport: transport_context[:transport] || transport_context[:type] || :stdio
       }}
    end
  end

  @doc false
  @spec validate_required_metadata(map()) :: :ok | {:error, Error.t()}
  def validate_required_metadata(request) when is_map(request) do
    with {:ok, params} <- require_map(request["params"], "params"),
         {:ok, meta} <- require_map(params["_meta"], "params._meta"),
         {:ok, _protocol_version} <-
           require_string(meta[@protocol_version_key], @protocol_version_key) do
      :ok
    end
  end

  @spec to_server_context(t()) :: Context.t()
  def to_server_context(%__MODULE__{} = context) do
    %Context{
      session_id: nil,
      client_info: context.client_info,
      protocol_version: context.protocol_version,
      era: :modern,
      execution_mode: :stateless,
      client_capabilities: context.client_capabilities,
      request_meta: context.request_meta,
      log_level: context.log_level,
      progress_token: context.progress_token,
      input_responses: context.input_responses,
      request_state: context.request_state,
      headers: context.headers,
      remote_ip: context.remote_ip,
      auth: context.auth
    }
  end

  defp require_map(value, _field) when is_map(value), do: {:ok, value}
  defp require_map(_value, field), do: invalid(field, "must be an object")

  defp require_string(value, _field) when is_binary(value), do: {:ok, value}
  defp require_string(_value, field), do: invalid(field, "must be a string")

  defp require_profile_version(version, version), do: :ok
  defp require_profile_version(_version, _expected), do: invalid(@protocol_version_key, "does not match profile")

  defp optional_client_info(meta) do
    case Map.fetch(meta, @client_info_key) do
      :error ->
        {:ok, nil}

      {:ok, info} when is_map(info) ->
        if valid_implementation?(info) do
          {:ok, info}
        else
          invalid(@client_info_key, "is not a valid implementation")
        end

      {:ok, _value} ->
        invalid(@client_info_key, "is not a valid implementation")
    end
  end

  defp valid_implementation?(info) do
    is_binary(info["name"]) and
      is_binary(info["version"]) and
      valid_optional_string?(info, "title") and
      valid_optional_string?(info, "description") and
      valid_optional_absolute_uri?(info, "websiteUrl") and
      valid_optional_icons?(info)
  end

  defp valid_optional_string?(container, field) do
    valid_optional_field?(container, field, &is_binary/1)
  end

  defp valid_optional_absolute_uri?(container, field) do
    valid_optional_field?(container, field, &absolute_uri?/1)
  end

  defp valid_optional_icons?(info) do
    valid_optional_field?(info, "icons", fn
      icons when is_list(icons) -> Enum.all?(icons, &valid_icon?/1)
      _invalid -> false
    end)
  end

  defp valid_icon?(%{} = icon) do
    absolute_uri?(icon["src"]) and
      valid_optional_string?(icon, "mimeType") and
      valid_optional_field?(icon, "sizes", &string_list?/1) and
      valid_optional_field?(icon, "theme", &(&1 in ~w(light dark)))
  end

  defp valid_icon?(_icon), do: false

  defp valid_optional_field?(container, field, validator) do
    case Map.fetch(container, field) do
      :error -> true
      {:ok, value} -> validator.(value)
    end
  end

  defp absolute_uri?(value) when is_binary(value) do
    match?({:ok, %URI{scheme: scheme}} when is_binary(scheme) and scheme != "", URI.new(value))
  end

  defp absolute_uri?(_value), do: false

  defp string_list?(values) when is_list(values), do: Enum.all?(values, &is_binary/1)
  defp string_list?(_values), do: false

  defp validate_client_capabilities(capabilities) do
    with :ok <- optional_capability_map(capabilities, "roots"),
         :ok <- validate_sampling_capability(capabilities),
         :ok <- validate_elicitation_capability(capabilities),
         :ok <- optional_map_values(capabilities, "experimental") do
      optional_map_values(capabilities, "extensions")
    end
  end

  defp validate_sampling_capability(capabilities) do
    case Map.fetch(capabilities, "sampling") do
      :error ->
        :ok

      {:ok, sampling} when is_map(sampling) ->
        with :ok <- optional_capability_map(sampling, "context") do
          optional_capability_map(sampling, "tools")
        end

      {:ok, _invalid} ->
        invalid(@client_capabilities_key, "contains an invalid sampling declaration")
    end
  end

  defp validate_elicitation_capability(capabilities) do
    case Map.fetch(capabilities, "elicitation") do
      :error ->
        :ok

      {:ok, elicitation} when is_map(elicitation) ->
        with :ok <- optional_capability_map(elicitation, "form") do
          optional_capability_map(elicitation, "url")
        end

      {:ok, _invalid} ->
        invalid(@client_capabilities_key, "contains an invalid elicitation declaration")
    end
  end

  defp optional_capability_map(container, field) do
    case Map.fetch(container, field) do
      :error -> :ok
      {:ok, value} when is_map(value) -> :ok
      {:ok, _invalid} -> invalid(@client_capabilities_key, "contains an invalid #{field} declaration")
    end
  end

  defp optional_map_values(container, field) do
    case Map.fetch(container, field) do
      :error ->
        :ok

      {:ok, value} when is_map(value) ->
        if Enum.all?(value, fn {key, nested} -> is_binary(key) and is_map(nested) end),
          do: :ok,
          else: invalid(@client_capabilities_key, "contains an invalid #{field} declaration")

      {:ok, _invalid} ->
        invalid(@client_capabilities_key, "contains an invalid #{field} declaration")
    end
  end

  defp optional_log_level(meta) do
    case Map.fetch(meta, @log_level_key) do
      :error -> {:ok, nil}
      {:ok, level} when level in @log_levels -> {:ok, level}
      {:ok, _value} -> invalid(@log_level_key, "is invalid")
    end
  end

  defp optional_progress_token(meta) do
    case Map.fetch(meta, "progressToken") do
      :error -> {:ok, nil}
      {:ok, value} when is_binary(value) or is_number(value) -> {:ok, value}
      {:ok, _value} -> invalid("progressToken", "must be a string or number")
    end
  end

  defp optional_map(container, field) do
    case Map.fetch(container, field) do
      :error -> {:ok, nil}
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, _value} -> invalid(field, "must be an object")
    end
  end

  defp optional_string(container, field) do
    case Map.fetch(container, field) do
      :error -> {:ok, nil}
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, _value} -> invalid(field, "must be a string")
    end
  end

  defp invalid(field, message) do
    {:error,
     Error.protocol(:invalid_params, %{
       message: "Invalid modern request metadata: #{field} #{message}"
     })}
  end

  defp normalize_headers(%{headers: headers}) when is_map(headers) do
    Map.new(headers, fn {name, value} -> {name |> to_string() |> String.downcase(), value} end)
  end

  defp normalize_headers(%{req_headers: headers}) when is_list(headers) do
    Map.new(headers, fn {name, value} -> {String.downcase(name), value} end)
  end

  defp normalize_headers(_transport_context), do: %{}

  defp normalize_assigns(assigns) when is_map(assigns), do: assigns
  defp normalize_assigns(_assigns), do: %{}
end

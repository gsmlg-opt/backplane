defmodule Backplane.McpProtocol.Server.Modern.Headers do
  @moduledoc """
  Pure validation for the HTTP fields mirrored by modern MCP requests.

  Standard headers are validated separately from tool parameter mirrors so the
  latter can use the effective request-local tool definition after
  `init_request/2`.
  """

  alias Backplane.McpProtocol.MCP.Error
  alias Backplane.McpProtocol.Protocol.Profile
  alias Backplane.McpProtocol.Server.Component.Tool

  @protocol_version_key "io.modelcontextprotocol/protocolVersion"
  @max_safe_integer 9_007_199_254_740_991
  @header_token ~r/\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/

  @spec validate(Profile.t(), map(), map()) :: :ok | {:error, Error.t()}
  def validate(%Profile{era: :modern} = profile, request, transport_context)
      when is_map(request) and is_map(transport_context) do
    if http?(transport_context) do
      headers = normalized_headers(transport_context)
      body_version = get_in(request, ["params", "_meta", @protocol_version_key])
      method = request["method"]

      with :ok <- reject_duplicate_routing_headers(profile, transport_context),
           :ok <- compare_plain(headers["mcp-protocol-version"], body_version, profile, "MCP-Protocol-Version"),
           :ok <- compare_plain(headers["mcp-method"], method, profile, "Mcp-Method") do
        validate_name(profile, method, request["params"], headers)
      end
    else
      :ok
    end
  end

  @doc "Validates recognized `x-mcp-header` mirrors for an effective tool definition."
  @spec validate_tool_params(Tool.t(), map(), map()) :: :ok | {:error, Error.t()}
  def validate_tool_params(%Tool{} = tool, request, transport_context)
      when is_map(request) and is_map(transport_context) do
    if http?(transport_context) do
      headers = normalized_headers(transport_context)
      arguments = get_in(request, ["params", "arguments"])
      arguments = if is_map(arguments), do: arguments, else: %{}
      version = get_in(request, ["params", "_meta", @protocol_version_key]) || "2026-07-28"

      tool.input_schema
      |> recognized_tool_headers()
      |> Enum.reduce_while(:ok, fn header, :ok ->
        case validate_tool_header(header, arguments, headers, transport_context) do
          :ok -> {:cont, :ok}
          :error -> {:halt, parameter_mismatch(version, header.name)}
        end
      end)
    else
      :ok
    end
  end

  defp validate_name(%Profile{named_methods: methods} = profile, method, params, headers) do
    if method in methods do
      body_value =
        if method == "resources/read", do: params && params["uri"], else: params && params["name"]

      with {:ok, header_value} <- decode_mirrored(headers["mcp-name"]),
           true <- is_binary(body_value) and header_value == body_value do
        :ok
      else
        _other -> mismatch(profile, "Mcp-Name")
      end
    else
      :ok
    end
  end

  defp compare_plain(header_value, body_value, profile, field)
       when is_binary(header_value) and is_binary(body_value) and header_value == body_value do
    if safe_plain?(header_value), do: :ok, else: mismatch(profile, field)
  end

  defp compare_plain(_header_value, _body_value, profile, field), do: mismatch(profile, field)

  defp reject_duplicate_routing_headers(profile, transport_context) do
    [
      {"mcp-protocol-version", "MCP-Protocol-Version"},
      {"mcp-method", "Mcp-Method"},
      {"mcp-name", "Mcp-Name"}
    ]
    |> Enum.find(fn {name, _field} -> duplicate_header?(transport_context, name) end)
    |> case do
      nil -> :ok
      {_name, field} -> mismatch(profile, field)
    end
  end

  defp decode_mirrored(nil), do: :error

  defp decode_mirrored("=?base64?" <> rest) do
    if String.ends_with?(rest, "?=") do
      encoded = binary_part(rest, 0, byte_size(rest) - 2)
      Base.decode64(encoded)
    else
      :error
    end
  end

  defp decode_mirrored(value) when is_binary(value) do
    if safe_plain?(value), do: {:ok, value}, else: :error
  end

  defp decode_mirrored(_value), do: :error

  defp recognized_tool_headers(schema) when is_map(schema) do
    candidates = collect_tool_headers(schema, [])

    frequencies =
      Enum.frequencies_by(candidates, fn header -> String.downcase(header.name) end)

    Enum.filter(candidates, fn header -> frequencies[String.downcase(header.name)] == 1 end)
  end

  defp recognized_tool_headers(_schema), do: []

  defp collect_tool_headers(%{"properties" => properties}, path) when is_map(properties) do
    Enum.flat_map(properties, fn
      {property, schema} when is_binary(property) and is_map(schema) ->
        property_path = path ++ [property]
        current = maybe_tool_header(schema, property_path)
        current ++ collect_tool_headers(schema, property_path)

      _other ->
        []
    end)
  end

  defp collect_tool_headers(_schema, _path), do: []

  defp maybe_tool_header(%{"x-mcp-header" => name} = schema, path) when is_binary(name) do
    case header_type(schema["type"]) do
      type when type in [:string, :boolean, :integer] ->
        if Regex.match?(@header_token, name), do: [%{name: name, path: path, type: type}], else: []

      _other ->
        []
    end
  end

  defp maybe_tool_header(_schema, _path), do: []

  defp header_type("string"), do: :string
  defp header_type("boolean"), do: :boolean
  defp header_type("integer"), do: :integer

  defp header_type(types) when is_list(types) do
    case Enum.reject(types, &(&1 == "null")) do
      [type] -> header_type(type)
      _other -> nil
    end
  end

  defp header_type(_type), do: nil

  defp validate_tool_header(header, arguments, headers, transport_context) do
    header_name = "mcp-param-" <> String.downcase(header.name)

    if duplicate_header?(transport_context, header_name) do
      :error
    else
      case fetch_path(arguments, header.path) do
        :error ->
          if Map.has_key?(headers, header_name), do: :error, else: :ok

        {:ok, nil} ->
          if Map.has_key?(headers, header_name), do: :error, else: :ok

        {:ok, value} ->
          with :ok <- validate_body_value(header.type, value),
               {:ok, decoded} <- decode_mirrored(headers[header_name]),
               true <- mirrored_value_equal?(header.type, value, decoded) do
            :ok
          else
            _other -> :error
          end
      end
    end
  end

  defp fetch_path(value, []), do: {:ok, value}

  defp fetch_path(value, [key | rest]) when is_map(value) do
    case Map.fetch(value, key) do
      {:ok, nested} -> fetch_path(nested, rest)
      :error -> :error
    end
  end

  defp fetch_path(_value, _path), do: :error

  defp validate_body_value(:string, value) when is_binary(value), do: :ok
  defp validate_body_value(:boolean, value) when is_boolean(value), do: :ok

  defp validate_body_value(:integer, value)
       when is_integer(value) and value >= -@max_safe_integer and value <= @max_safe_integer,
       do: :ok

  defp validate_body_value(_type, _value), do: :error

  defp mirrored_value_equal?(:string, body, header), do: body == header
  defp mirrored_value_equal?(:boolean, body, header), do: Atom.to_string(body) == header

  defp mirrored_value_equal?(:integer, body, header) do
    if byte_size(header) <= 64 and Regex.match?(~r/\A[+-]?\d+(?:\.0+)?\z/, header) do
      integer_text = header |> String.split(".", parts: 2) |> hd()

      case Integer.parse(integer_text) do
        {parsed, ""} -> parsed == body
        _other -> false
      end
    else
      false
    end
  end

  defp parameter_mismatch(version, name) do
    {:error,
     Error.for_version(version, :header_mismatch, %{
       "field" => "Mcp-Param-#{name}"
     })}
  end

  defp safe_plain?(value) when is_binary(value) do
    value == String.trim(value) and
      Enum.all?(:binary.bin_to_list(value), fn byte -> byte == 9 or byte in 32..126 end)
  end

  defp mismatch(profile, field) do
    {:error,
     Error.for_version(profile.version, :header_mismatch, %{
       "field" => field
     })}
  end

  defp http?(%{transport: :http}), do: true
  defp http?(%{type: :http}), do: true
  defp http?(_transport_context), do: false

  defp normalized_headers(%{headers: headers}) when is_map(headers) do
    Map.new(headers, fn {name, value} -> {name |> to_string() |> String.downcase(), value} end)
  end

  defp normalized_headers(%{req_headers: headers}) when is_list(headers) do
    Map.new(headers, fn {name, value} -> {String.downcase(name), value} end)
  end

  defp normalized_headers(_transport_context), do: %{}

  defp duplicate_header?(transport_context, header_name) do
    transport_context
    |> raw_header_pairs()
    |> Enum.count(fn {name, _value} -> name |> to_string() |> String.downcase() == header_name end)
    |> Kernel.>(1)
  end

  defp raw_header_pairs(%{req_headers: headers}) when is_list(headers), do: headers
  defp raw_header_pairs(%{headers: headers}) when is_list(headers), do: headers
  defp raw_header_pairs(_transport_context), do: []
end

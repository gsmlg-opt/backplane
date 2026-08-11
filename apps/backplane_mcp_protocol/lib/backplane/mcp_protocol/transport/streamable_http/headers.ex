defmodule Backplane.McpProtocol.Transport.StreamableHTTP.Headers do
  @moduledoc """
  Builds request-local Streamable HTTP headers for legacy and modern MCP sends.

  Modern routing fields are derived from the encoded wire request so configured
  values cannot disagree with the body that is actually sent.
  """

  alias Backplane.McpProtocol.Transport.RequestContext

  @protocol_version_key "io.modelcontextprotocol/protocolVersion"
  @max_safe_integer 9_007_199_254_740_991
  @header_token ~r/\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/
  @parameter_prefix "mcp-param-"
  @routing_headers ~w(mcp-protocol-version mcp-method mcp-name)
  @legacy_protocol_header_versions ~w(2025-06-18 2025-11-25)
  @default_headers %{
    "accept" => "application/json, text/event-stream",
    "content-type" => "application/json"
  }

  @spec build(map() | list(), binary(), RequestContext.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def build(base_headers, encoded_message, %RequestContext{} = context) do
    with {:ok, base_headers} <- configured(base_headers) do
      if RequestContext.modern?(context) do
        build_modern(base_headers, encoded_message, context)
      else
        headers =
          base_headers
          |> strip_legacy_routing_headers()
          |> Map.merge(@default_headers)
          |> maybe_put_legacy_protocol_header(context)

        {:ok, headers}
      end
    end
  end

  def build(base_headers, _encoded_message, nil) do
    with {:ok, base_headers} <- legacy_configured(base_headers) do
      {:ok, Map.merge(base_headers, @default_headers)}
    end
  end

  @doc "Validates configured legacy headers and removes modern routing fields."
  @spec legacy_configured(map() | list()) :: {:ok, map()} | {:error, term()}
  def legacy_configured(headers) do
    with {:ok, headers} <- configured(headers) do
      {:ok, strip_legacy_routing_headers(headers)}
    end
  end

  @doc "Adds the negotiated legacy protocol header when that revision requires it."
  @spec put_legacy_protocol_header(map(), String.t() | nil) :: map()
  def put_legacy_protocol_header(headers, version) when version in @legacy_protocol_header_versions do
    Map.put(headers, "mcp-protocol-version", version)
  end

  def put_legacy_protocol_header(headers, _version), do: headers

  @doc "Validates configured headers and canonicalizes their names to lower case."
  @spec configured(map() | list()) :: {:ok, map()} | {:error, term()}
  def configured(headers) when is_map(headers), do: configured(Map.to_list(headers))

  def configured(headers) when is_list(headers) do
    Enum.reduce_while(headers, {:ok, %{}}, fn
      {name, value}, {:ok, acc} when is_binary(name) and is_binary(value) ->
        normalized = String.downcase(name)

        cond do
          not Regex.match?(@header_token, name) ->
            {:halt, {:error, {:invalid_header_name, name}}}

          contains_crlf?(value) ->
            {:halt, {:error, {:invalid_header_value, normalized}}}

          Map.has_key?(acc, normalized) ->
            {:halt, {:error, {:duplicate_header, normalized}}}

          true ->
            {:cont, {:ok, Map.put(acc, normalized, value)}}
        end

      {name, _value}, _acc ->
        {:halt, {:error, {:invalid_header_name, name}}}

      invalid, _acc ->
        {:halt, {:error, {:invalid_header, invalid}}}
    end)
  end

  def configured(_headers), do: {:error, :invalid_headers}

  @doc "Validates and encodes a set of declared `Mcp-Param-*` headers."
  @spec parameter_headers(map()) :: {:ok, map()} | {:error, term()}
  def parameter_headers(headers) when is_map(headers) do
    entries = Map.to_list(headers)

    with :ok <- reject_parameter_collisions(entries) do
      Enum.reduce_while(entries, {:ok, %{}}, fn {name, value}, {:ok, acc} ->
        case normalize_parameter_name(name) do
          {:ok, header_name} ->
            encoded = encode_mirrored(value)

            case encoded do
              {:ok, header_value} -> {:cont, {:ok, Map.put(acc, header_name, header_value)}}
              :omit -> {:cont, {:ok, acc}}
              {:error, reason} -> {:halt, {:error, {reason, header_name}}}
            end

          {:error, _reason} = error ->
            {:halt, error}
        end
      end)
    end
  end

  def parameter_headers(_headers), do: {:error, :invalid_parameter_headers}

  @doc "Encodes one mirrored primitive using the MCP lower-case base64 sentinel."
  @spec encode_mirrored(term()) :: {:ok, String.t()} | :omit | {:error, atom()}
  def encode_mirrored(nil), do: :omit
  def encode_mirrored(value) when is_boolean(value), do: {:ok, Atom.to_string(value)}

  def encode_mirrored(value) when is_integer(value) and value >= -@max_safe_integer and value <= @max_safe_integer,
    do: {:ok, Integer.to_string(value)}

  def encode_mirrored(value) when is_integer(value), do: {:error, :unsafe_integer}

  def encode_mirrored(value) when is_binary(value) do
    if safe_plain?(value) and not base64_sentinel?(value) do
      {:ok, value}
    else
      {:ok, "=?base64?" <> Base.encode64(value) <> "?="}
    end
  end

  def encode_mirrored(_value), do: {:error, :unsupported_value}

  defp build_modern(base_headers, encoded_message, context) do
    with {:ok, request} <- decode_request(encoded_message),
         {:ok, method} <- require_string(request["method"]),
         {:ok, params} <- require_map(request["params"]),
         {:ok, version} <- body_protocol_version(params),
         {:ok, parameter_headers} <- parameter_headers(context.parameter_headers),
         {:ok, routing_headers} <- routing_headers(context, method, params, version) do
      headers =
        base_headers
        |> strip_modern_owned_headers()
        |> Map.merge(@default_headers)
        |> Map.merge(parameter_headers)
        |> Map.merge(routing_headers)

      {:ok, headers}
    end
  end

  defp decode_request(encoded_message) when is_binary(encoded_message) do
    case JSON.decode(encoded_message) do
      {:ok, %{"jsonrpc" => "2.0", "id" => id} = request}
      when is_binary(id) or is_number(id) ->
        {:ok, request}

      _invalid ->
        {:error, :invalid_encoded_message}
    end
  end

  defp decode_request(_encoded_message), do: {:error, :invalid_encoded_message}

  defp require_string(value) when is_binary(value), do: {:ok, value}
  defp require_string(_value), do: {:error, :invalid_encoded_message}

  defp require_map(value) when is_map(value), do: {:ok, value}
  defp require_map(_value), do: {:error, :invalid_encoded_message}

  defp body_protocol_version(params) do
    case get_in(params, ["_meta", @protocol_version_key]) do
      version when is_binary(version) -> {:ok, version}
      _invalid -> {:error, :missing_protocol_version_metadata}
    end
  rescue
    _error -> {:error, :missing_protocol_version_metadata}
  end

  defp routing_headers(context, method, params, version) do
    if safe_plain?(version) and safe_plain?(method) do
      headers = %{
        "mcp-protocol-version" => version,
        "mcp-method" => method
      }

      if method in context.profile.named_methods do
        name = if method == "resources/read", do: params["uri"], else: params["name"]

        with {:ok, name} <- encode_named_value(name) do
          {:ok, Map.put(headers, "mcp-name", name)}
        end
      else
        {:ok, headers}
      end
    else
      {:error, :invalid_routing_header_value}
    end
  end

  defp encode_named_value(value) when is_binary(value), do: encode_mirrored(value)
  defp encode_named_value(_value), do: {:error, :missing_routing_name}

  defp strip_modern_owned_headers(headers) do
    Map.reject(headers, fn {name, _value} ->
      name in ["mcp-session-id", "last-event-id"] or name in @routing_headers or
        String.starts_with?(name, @parameter_prefix)
    end)
  end

  defp strip_legacy_routing_headers(headers) do
    Map.reject(headers, fn {name, _value} ->
      name in ~w(mcp-method mcp-name) or String.starts_with?(name, @parameter_prefix)
    end)
  end

  defp maybe_put_legacy_protocol_header(headers, %RequestContext{method: method, protocol_version: version})
       when method != "initialize" and version in @legacy_protocol_header_versions do
    put_legacy_protocol_header(headers, version)
  end

  defp maybe_put_legacy_protocol_header(headers, _context), do: headers

  defp reject_parameter_collisions(entries) do
    entries
    |> Enum.reduce_while({:ok, MapSet.new()}, fn
      {name, _value}, {:ok, seen} when is_binary(name) ->
        normalized = String.downcase(name)

        if MapSet.member?(seen, normalized) do
          {:halt, {:error, {:duplicate_parameter_header, normalized}}}
        else
          {:cont, {:ok, MapSet.put(seen, normalized)}}
        end

      {name, _value}, _acc ->
        {:halt, {:error, {:invalid_parameter_header, name}}}
    end)
    |> case do
      {:ok, _seen} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp normalize_parameter_name(name) when is_binary(name) do
    normalized = String.downcase(name)

    if Regex.match?(@header_token, name) and
         String.starts_with?(normalized, @parameter_prefix) and
         byte_size(normalized) > byte_size(@parameter_prefix) do
      {:ok, normalized}
    else
      {:error, {:invalid_parameter_header, name}}
    end
  end

  defp normalize_parameter_name(name), do: {:error, {:invalid_parameter_header, name}}

  defp safe_plain?(value) do
    String.valid?(value) and
      value == String.trim(value) and
      Enum.all?(:binary.bin_to_list(value), fn byte -> byte == 9 or byte in 32..126 end)
  end

  defp base64_sentinel?(value) do
    String.starts_with?(value, "=?base64?") and String.ends_with?(value, "?=")
  end

  defp contains_crlf?(value), do: String.contains?(value, ["\r", "\n"])
end

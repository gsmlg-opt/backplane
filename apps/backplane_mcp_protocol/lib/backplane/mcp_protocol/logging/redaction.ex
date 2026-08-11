defmodule Backplane.McpProtocol.Logging.Redaction do
  @moduledoc false

  @redacted "[REDACTED]"
  @mcp_parameter_prefix "mcp_param_"
  @sensitive_keys ~w(
    authorization
    proxy_authorization
    proxyauthorization
    token
    access_token
    accesstoken
    refresh_token
    refreshtoken
    id_token
    idtoken
    bearer_token
    bearertoken
    registration_token
    registrationtoken
    registration_access_token
    registrationaccesstoken
    client_secret
    clientsecret
    client_assertion
    clientassertion
    assertion
    code_verifier
    codeverifier
    authorization_code
    authorizationcode
    requeststate
    request_state
  )
  @embedded_credential ~r/\b(bearer|basic)([ \t]+)([^ \t\r\n,;]+)/iu
  @key_value_syntax ~r/["']?([A-Za-z][A-Za-z0-9_-]*)["']?\s*[:=]\s*(.)?/u
  @quoted_json_string ~r/"((?:\\.|[^"\\])*)"/u
  @unquoted_container_key ~r/(?:^|[\{\[,])\s*([A-Za-z][A-Za-z0-9_-]*)\b/u

  @doc "Recursively replaces authentication material with a stable marker."
  @spec redact(term()) :: term()
  def redact(value) do
    do_redact(value)
  rescue
    _error -> @redacted
  catch
    _kind, _reason -> @redacted
  end

  defp do_redact(value) when is_binary(value), do: redact_binary(value)

  defp do_redact(value) when is_map(value) do
    value
    |> Map.to_list()
    |> Enum.reduce(value, fn {key, nested}, acc ->
      redacted_key = redact_map_key(key)
      redacted_value = redact_keyed_value(key, nested)
      acc = if redacted_key == key, do: acc, else: Map.delete(acc, key)
      Map.put(acc, redacted_key, redacted_value)
    end)
  end

  defp do_redact([]), do: []

  defp do_redact([_head | _tail] = value) do
    case redact_chardata(value) do
      {:redacted, redacted} -> redacted
      :unchanged -> redact_list(value)
      :not_chardata -> redact_list(value)
    end
  end

  defp do_redact({key, value}) do
    if sensitive_value?(key, value) do
      {key, @redacted}
    else
      {do_redact(key), do_redact(value)}
    end
  end

  defp do_redact(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&do_redact/1)
    |> List.to_tuple()
  end

  defp do_redact(value), do: value

  defp redact_list([head | tail]), do: [do_redact(head) | do_redact(tail)]

  defp redact_chardata(value) do
    binary = IO.chardata_to_string(value)
    redacted = redact_binary(binary)

    if redacted == binary, do: :unchanged, else: {:redacted, redacted}
  rescue
    _error -> :not_chardata
  catch
    _kind, _reason -> :not_chardata
  end

  defp redact_keyed_value(key, value) do
    if sensitive_value?(key, value), do: @redacted, else: do_redact(value)
  end

  defp redact_map_key(key) when is_binary(key) or is_list(key) do
    normalized = normalize_key(key)

    if normalized == "code" or sensitive_normalized_key?(normalized) do
      key
    else
      do_redact(key)
    end
  end

  defp redact_map_key(key), do: do_redact(key)

  defp sensitive_value?(key, value) do
    case normalize_key(key) do
      "code" -> is_binary(value)
      normalized -> sensitive_normalized_key?(normalized)
    end
  end

  defp sensitive_normalized_key?(normalized) do
    normalized in @sensitive_keys or starts_with?(normalized, @mcp_parameter_prefix)
  end

  defp normalize_key(key) when is_atom(key), do: key |> Atom.to_string() |> normalize_ascii()
  defp normalize_key(key) when is_binary(key), do: normalize_ascii(key)

  defp normalize_key(key) when is_list(key) do
    key
    |> IO.chardata_to_string()
    |> normalize_ascii()
  rescue
    _error -> ""
  catch
    _kind, _reason -> ""
  end

  defp normalize_key(_key), do: ""

  defp normalize_ascii(binary) do
    for <<byte <- binary>>, into: <<>> do
      cond do
        byte in ?A..?Z -> <<byte + 32>>
        byte == ?- -> <<?_>>
        true -> <<byte>>
      end
    end
  end

  defp starts_with?(binary, prefix) when byte_size(binary) >= byte_size(prefix) do
    binary_part(binary, 0, byte_size(prefix)) == prefix
  end

  defp starts_with?(_binary, _prefix), do: false

  defp redact_binary(binary) do
    if String.valid?(binary) do
      case JSON.decode(binary) do
        {:ok, decoded} -> redact_json(binary, decoded)
        {:error, _reason} -> redact_text(binary)
      end
    else
      redact_invalid_binary(binary)
    end
  end

  defp redact_json(original, decoded) do
    redacted = do_redact(decoded)

    if redacted != decoded or json_contains_sensitive_syntax?(original) or
         Regex.match?(@embedded_credential, original) do
      JSON.encode!(redacted)
    else
      original
    end
  end

  defp redact_text(original) do
    {form, form_recognized?} = redact_form(original)
    {headers, headers_recognized?} = redact_header_lines(form)
    {credentials, credentials_recognized?} = redact_embedded_credentials(headers)

    if form_recognized? or headers_recognized? or credentials_recognized? do
      credentials
    else
      if malformed_sensitive_syntax?(original), do: @redacted, else: original
    end
  end

  defp redact_form(binary) do
    binary
    |> String.split("&", trim: false)
    |> Enum.map_reduce(false, fn segment, recognized? ->
      case String.split(segment, "=", parts: 2) do
        [raw_key, _raw_value] ->
          key = raw_key |> query_parameter_key() |> URI.decode_www_form()

          if sensitive_value?(key, "form-value") do
            {raw_key <> "=" <> @redacted, true}
          else
            {segment, recognized?}
          end

        [raw_key] ->
          key = raw_key |> query_parameter_key() |> URI.decode_www_form()

          if sensitive_value?(key, "form-value") do
            {raw_key <> "=" <> @redacted, true}
          else
            {segment, recognized?}
          end
      end
    end)
    |> then(fn {segments, recognized?} -> {Enum.join(segments, "&"), recognized?} end)
  end

  defp query_parameter_key(raw_key) do
    case :binary.matches(raw_key, "?") do
      [] ->
        raw_key

      matches ->
        {position, length} = List.last(matches)
        binary_part(raw_key, position + length, byte_size(raw_key) - position - length)
    end
  end

  defp redact_header_lines(binary) do
    ~r/(\r\n|\n|\r)/
    |> Regex.split(binary, include_captures: true, trim: false)
    |> Enum.map_reduce({false, false}, fn part, {recognized?, redact_continuation?} ->
      if part in ["\r\n", "\n", "\r"] do
        {part, {recognized?, redact_continuation?}}
      else
        redact_header_line(part, recognized?, redact_continuation?)
      end
    end)
    |> then(fn {parts, {recognized?, _redact_continuation?}} ->
      {IO.iodata_to_binary(parts), recognized?}
    end)
  end

  defp redact_header_line(line, recognized?, true) do
    if continuation_line?(line) do
      {@redacted, {true, true}}
    else
      redact_header_line(line, recognized?, false)
    end
  end

  defp redact_header_line(line, recognized?, false) do
    case String.split(line, ":", parts: 2) do
      [raw_key, _raw_value] ->
        key = String.trim(raw_key)

        if sensitive_value?(key, "header-value") do
          {raw_key <> ": " <> @redacted, {true, true}}
        else
          {line, {recognized?, false}}
        end

      [_line] ->
        {line, {recognized?, false}}
    end
  end

  defp continuation_line?(<<character, _rest::binary>>) when character in [32, 9], do: true
  defp continuation_line?(_line), do: false

  defp redact_embedded_credentials(binary) do
    if Regex.match?(@embedded_credential, binary) do
      redacted =
        Regex.replace(@embedded_credential, binary, fn _match, scheme, whitespace, _credential ->
          scheme <> whitespace <> @redacted
        end)

      {redacted, true}
    else
      {binary, false}
    end
  end

  defp json_contains_sensitive_syntax?(binary) do
    @key_value_syntax
    |> Regex.scan(binary)
    |> Enum.any?(fn
      [_match, raw_key, first_value_character] ->
        json_sensitive_value?(normalize_key(raw_key), first_value_character)

      [_match, raw_key] ->
        sensitive_normalized_key?(normalize_key(raw_key))
    end)
  end

  defp json_sensitive_value?("code", first_value_character), do: first_value_character in ["\"", "'"]

  defp json_sensitive_value?(normalized, _first_value_character), do: sensitive_normalized_key?(normalized)

  defp malformed_sensitive_syntax?(binary) do
    malformed_json_sensitive_key?(binary) or
      @key_value_syntax
      |> Regex.scan(binary)
      |> Enum.any?(fn
        [_match, raw_key, first_value_character] ->
          malformed_sensitive_value?(normalize_key(raw_key), first_value_character)

        [_match, raw_key] ->
          sensitive_normalized_key?(normalize_key(raw_key))
      end)
  end

  defp malformed_json_sensitive_key?(binary) do
    if binary |> String.trim_leading() |> starts_with_json_container?() do
      quoted_sensitive_key?(binary) or unquoted_sensitive_key?(binary)
    else
      false
    end
  end

  defp quoted_sensitive_key?(binary) do
    @quoted_json_string
    |> Regex.scan(binary, capture: :all_but_first)
    |> Enum.any?(fn [encoded] ->
      case JSON.decode("\"" <> encoded <> "\"") do
        {:ok, key} -> sensitive_value?(key, "unknown")
        {:error, _reason} -> false
      end
    end)
  end

  defp unquoted_sensitive_key?(binary) do
    @unquoted_container_key
    |> Regex.scan(binary, capture: :all_but_first)
    |> Enum.any?(fn [key] -> sensitive_value?(key, "unknown") end)
  end

  defp starts_with_json_container?(<<"{", _rest::binary>>), do: true
  defp starts_with_json_container?(<<"[", _rest::binary>>), do: true
  defp starts_with_json_container?(_binary), do: false

  defp malformed_sensitive_value?("code", <<character::utf8>>) when character in ?0..?9 or character == ?-, do: false

  defp malformed_sensitive_value?("code", _first_value_character), do: true

  defp malformed_sensitive_value?(normalized, _first_value_character), do: sensitive_normalized_key?(normalized)

  defp redact_invalid_binary(binary) do
    normalized = normalize_ascii(binary)

    if invalid_binary_sensitive?(normalized) do
      @redacted
    else
      binary
    end
  end

  defp invalid_binary_sensitive?(normalized) do
    Enum.any?(@sensitive_keys, &(:binary.match(normalized, &1) != :nomatch)) or
      :binary.match(normalized, @mcp_parameter_prefix) != :nomatch or
      :binary.match(normalized, "bearer ") != :nomatch or
      :binary.match(normalized, "bearer\t") != :nomatch or
      :binary.match(normalized, "basic ") != :nomatch or
      :binary.match(normalized, "basic\t") != :nomatch or
      :binary.match(normalized, "code=") != :nomatch or
      :binary.match(normalized, "code:") != :nomatch
  end
end

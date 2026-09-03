defmodule Backplane.Observability.Redaction do
  @moduledoc false

  @redacted "[REDACTED]"

  @credential_keys ~w(
    authorization
    proxy_authorization
    cookie
    set-cookie
    token
    access_token
    refresh_token
    id_token
    client_secret
    client_assertion
    code_verifier
    authorization_code
    api_key
    x-api-key
    credential
    password
    bearer
    basic
  )

  @payload_keys ~w(
    messages
    prompt
    input
    content
    arguments
    result
    resource
    raw_request
    raw_response
  )

  @embedded_credential ~r/\b(bearer|basic)([ \t]+)([^ \t\r\n,;]+)/iu

  @doc "Recursively redacts credentials and payload-classified values."
  @spec redact(term()) :: term()
  def redact(value) do
    do_redact(value)
  rescue
    _ -> @redacted
  catch
    _, _ -> @redacted
  end

  @doc "Sanitizes event attributes for enqueue and persistence."
  @spec sanitize_attributes(map()) :: map()
  def sanitize_attributes(attrs) when is_map(attrs) do
    attrs
    |> redact()
    |> sanitize_terms()
  end

  defp do_redact(value) when is_binary(value), do: redact_binary(value)

  defp do_redact(value) when is_map(value) do
    Map.new(value, fn {key, nested} ->
      if sensitive_key?(key) or payload_key?(key) do
        {key, @redacted}
      else
        {key, do_redact(nested)}
      end
    end)
  end

  defp do_redact(value) when is_list(value), do: Enum.map(value, &do_redact/1)

  defp do_redact({key, value}) do
    if sensitive_key?(key) or payload_key?(key) do
      {key, @redacted}
    else
      {do_redact(key), do_redact(value)}
    end
  end

  defp do_redact(value) when is_tuple(value) do
    value |> Tuple.to_list() |> do_redact() |> List.to_tuple()
  end

  defp do_redact(value) when is_atom(value), do: value
  defp do_redact(value) when is_number(value), do: value
  defp do_redact(value) when is_boolean(value), do: value
  defp do_redact(value), do: value

  defp redact_binary(value) do
    if String.match?(value, @embedded_credential) do
      String.replace(value, @embedded_credential, "\\1\\2[REDACTED]")
    else
      value
    end
  end

  defp sensitive_key?(key), do: normalized_key(key) in @credential_keys
  defp payload_key?(key), do: normalized_key(key) in @payload_keys

  defp normalized_key(key) when is_atom(key), do: key |> Atom.to_string() |> normalized_key()
  defp normalized_key(key) when is_binary(key), do: key |> String.downcase() |> String.replace("-", "_")
  defp normalized_key(_), do: ""

  defp sanitize_terms(value) when is_map(value) do
    Map.new(value, fn {k, v} -> {to_string(k), sanitize_terms(v)} end)
  end

  defp sanitize_terms(value) when is_list(value), do: Enum.map(value, &sanitize_terms/1)

  defp sanitize_terms(value) when is_struct(value) do
    if is_exception(value) do
      Exception.message(value)
    else
      value |> Map.from_struct() |> sanitize_terms()
    end
  end

  defp sanitize_terms(value) when is_tuple(value) do
    value |> Tuple.to_list() |> sanitize_terms()
  end

  defp sanitize_terms(value) when is_pid(value) or is_reference(value), do: inspect(value)
  defp sanitize_terms(value) when is_atom(value), do: Atom.to_string(value)
  defp sanitize_terms(value), do: value
end

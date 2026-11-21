defmodule Backplane.LLM.HeaderPolicy do
  @moduledoc """
  Shared, case-insensitive request header policy for LLM proxy routes.

  Normalizes header names case-insensitively, merges shared Provider defaults
  with API-specific defaults (API defaults win on ordinary configurable headers),
  strips hop-by-hop and connection-nominated headers, and protects server-owned
  credential/protocol headers from replacement by callers or configured defaults.
  """

  @hop_by_hop ~w(
    connection
    keep-alive
    proxy-authenticate
    proxy-authorization
    te
    trailer
    trailers
    transfer-encoding
    upgrade
    host
    content-length
    cookie
    set-cookie
  )

  @websocket_handshake ~w(
    sec-websocket-key
    sec-websocket-accept
    sec-websocket-version
    sec-websocket-protocol
    sec-websocket-extensions
  )

  @credential_headers ~w(
    authorization
    x-api-key
    api-key
    x-goog-api-key
  )

  @codex_owned ~w(
    authorization
    x-api-key
    api-key
    chatgpt-account-id
    x-openai-fedramp
  )

  @antigravity_owned ~w(
    authorization
    x-api-key
    api-key
    x-goog-api-key
    proxy-authorization
    cookie
    x-goog-user-project
    x-machine-session-id
    x-client-name
    x-client-version
    user-agent
    content-type
    accept
  )

  @doc "Returns header names nominated by any `Connection` header in `headers`."
  @spec connection_nominated([{String.t(), String.t()}]) :: [String.t()]
  def connection_nominated(headers) when is_list(headers) do
    headers
    |> Enum.flat_map(fn
      {name, value} when is_binary(name) and is_binary(value) ->
        if String.downcase(name) == "connection" do
          value
          |> String.split(",")
          |> Enum.map(&String.downcase(String.trim(&1)))
          |> Enum.reject(&(&1 == ""))
        else
          []
        end

      _ ->
        []
    end)
    |> Enum.uniq()
  end

  def connection_nominated(_), do: []

  @doc "Returns the protected header names for a given LLM API surface or route."
  @spec protected_headers(atom()) :: [String.t()]
  def protected_headers(:antigravity), do: @hop_by_hop ++ @antigravity_owned
  def protected_headers(:codex), do: @hop_by_hop ++ @credential_headers ++ @codex_owned

  def protected_headers(:responses_websocket),
    do: @hop_by_hop ++ @credential_headers ++ @codex_owned ++ @websocket_handshake

  def protected_headers(:openai_native),
    do: @hop_by_hop ++ @credential_headers ++ @websocket_handshake ++ ["content-type"]

  def protected_headers(_surface), do: @hop_by_hop ++ @credential_headers

  @doc """
  Normalizes a header map into `%{lowercased_name => value}`, dropping invalid
  entries (empty names, non-binary values, or CR/LF injection characters).
  """
  @spec normalize_map(map() | nil) :: %{optional(String.t()) => String.t()}
  def normalize_map(headers) when is_map(headers) do
    Enum.reduce(headers, %{}, fn {name, value}, acc ->
      with {:ok, key, val} <- sanitize_pair(name, value) do
        Map.put(acc, key, val)
      else
        :error -> acc
      end
    end)
  end

  def normalize_map(_), do: %{}

  @doc """
  Merges Provider default headers with API-specific default headers.

  Names are normalized case-insensitively. API-specific defaults override
  Provider defaults for ordinary configurable headers. Hop-by-hop headers and
  any forbidden/protected headers are removed.
  """
  @spec merge_defaults(map() | nil, map() | nil, keyword()) :: [{String.t(), String.t()}]
  def merge_defaults(provider_headers, api_headers, opts \\ []) do
    forbidden =
      opts
      |> Keyword.get(:forbidden, protected_headers(Keyword.get(opts, :surface, :default)))
      |> MapSet.new(&String.downcase(to_string(&1)))

    provider_headers
    |> normalize_map()
    |> Map.merge(normalize_map(api_headers))
    |> Enum.reject(fn {key, _value} -> MapSet.member?(forbidden, key) end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  @doc """
  Merges ordered header layers (from lowest to highest precedence) using
  case-insensitive matching.

  Later layers replace earlier entries with the same lowercased header name.
  A `{name, nil}` entry removes any earlier value; when `keep_nil: true` is
  passed (for Relayixir `inject_request_headers`), the `{name, nil}` deletion
  marker is retained in the output.
  """
  @spec merge_ordered([[{String.t(), String.t() | nil}]], keyword()) :: [
          {String.t(), String.t() | nil}
        ]
  def merge_ordered(layers, opts \\ []) when is_list(layers) do
    keep_nil? = Keyword.get(opts, :keep_nil, false)

    layers
    |> List.flatten()
    |> Enum.reduce([], fn {name, value}, acc ->
      key = String.downcase(to_string(name))
      filtered = Enum.reject(acc, fn {existing, _} -> existing == key end)

      cond do
        is_nil(value) and keep_nil? ->
          filtered ++ [{key, nil}]

        is_nil(value) ->
          filtered

        valid_pair?(key, value) ->
          filtered ++ [{key, value}]

        true ->
          filtered
      end
    end)
  end

  @doc "Filters out protected headers from a list of `{name, value}` pairs."
  @spec reject_headers([{String.t(), term()}], [String.t()]) :: [{String.t(), term()}]
  def reject_headers(headers, forbidden) when is_list(headers) do
    forbidden_set = MapSet.new(forbidden, &String.downcase(to_string(&1)))

    Enum.reject(headers, fn {name, _value} ->
      MapSet.member?(forbidden_set, String.downcase(to_string(name)))
    end)
  end

  defp sanitize_pair(name, value) when is_binary(value) do
    key = name |> to_string() |> String.trim() |> String.downcase()
    if valid_pair?(key, value), do: {:ok, key, value}, else: :error
  end

  defp sanitize_pair(_name, _value), do: :error

  defp valid_pair?(key, value)
       when is_binary(key) and key != "" and is_binary(value) do
    not String.contains?(key <> value, ["\r", "\n"])
  end

  defp valid_pair?(_, _), do: false
end

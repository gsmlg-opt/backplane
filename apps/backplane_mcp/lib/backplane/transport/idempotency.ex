defmodule Backplane.Transport.Idempotency do
  @moduledoc """
  Identity-bound replay for buffered MCP responses carrying an Idempotency-Key.

  Concurrent first requests may both execute; ETS insertion is atomic and the
  last buffered response wins. This is replay, not single-flight execution.
  """

  require Logger

  import Plug.Conn
  alias Backplane.MCP.{Info, ModernServer}

  @behaviour Plug

  @table __MODULE__
  @default_ttl_ms 300_000
  @max_table_size 10_000
  @auth_kinds [:oauth, :client_token, :legacy, :open]
  @identity_headers ~w(mcp-protocol-version mcp-method mcp-name mcp-session-id if-none-match)
  @replay_headers ~w(mcp-session-id etag cache-control content-type)

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    cond do
      event_stream_requested?(conn) ->
        assign(conn, :mcp_idempotency_status, "bypass")

      true ->
        case get_req_header(conn, "idempotency-key") do
          [external_key | _] when byte_size(external_key) > 0 ->
            case cache_key(conn, external_key) do
              {:ok, key} ->
                ensure_table()
                check_cache(conn, key)

              :error ->
                assign(conn, :mcp_idempotency_status, "bypass")
            end

          _ ->
            conn
        end
    end
  end

  defp cache_key(conn, external_key) do
    with {:ok, raw_body} <- fetch_raw_body(conn.assigns),
         {:ok, auth} <- auth_identity(conn.assigns[:resource_auth]),
         era when era in [:legacy, :modern] <- conn.assigns[:mcp_era],
         {:ok, header_digest} <- header_digest(conn.req_headers) do
      message = plain_map(conn.body_params)

      identity = {
        conn.method,
        auth,
        era,
        message["method"],
        request_name(message),
        :crypto.hash(:sha256, raw_body),
        header_digest
      }

      {:ok, {external_key, identity}}
    else
      _invalid -> :error
    end
  end

  defp fetch_raw_body(assigns) do
    case Map.fetch(assigns, :raw_body) do
      {:ok, body} when is_binary(body) -> {:ok, body}
      _missing_or_invalid -> :error
    end
  end

  defp plain_map(value) when is_map(value) and not is_struct(value), do: value
  defp plain_map(_value), do: %{}
  defp request_name(%{"params" => %{"name" => name}}), do: name
  defp request_name(_message), do: nil

  defp auth_identity(auth) when is_map(auth) do
    with {:ok, kind} <- auth_field(auth, :kind, &normalize_kind/1),
         {:ok, subject} <- auth_field(auth, :subject, &optional_string/1),
         {:ok, client_id} <- auth_field(auth, :client_id, &optional_string/1),
         {:ok, scopes} <- auth_field(auth, :scopes, &normalize_scopes/1),
         {:ok, metadata} <- auth_field(auth, :principal_metadata, &canonical_metadata/1) do
      {:ok, {kind, subject, client_id, scopes, metadata}}
    else
      _invalid -> :error
    end
  end

  defp auth_identity(_auth), do: :error

  defp auth_field(auth, field, normalizer) do
    case {Map.fetch(auth, field), Map.fetch(auth, Atom.to_string(field))} do
      {{:ok, left}, {:ok, right}} ->
        with {:ok, left} <- normalizer.(left),
             {:ok, right} <- normalizer.(right),
             true <- left == right,
             do: {:ok, left}

      {{:ok, value}, :error} ->
        normalizer.(value)

      {:error, {:ok, value}} ->
        normalizer.(value)

      {:error, :error} ->
        :error
    end
  end

  defp normalize_kind(kind) when kind in @auth_kinds, do: {:ok, kind}
  defp normalize_kind("oauth"), do: {:ok, :oauth}
  defp normalize_kind("client_token"), do: {:ok, :client_token}
  defp normalize_kind("legacy"), do: {:ok, :legacy}
  defp normalize_kind("open"), do: {:ok, :open}
  defp normalize_kind(_kind), do: :error

  defp optional_string(value) when is_binary(value) or is_nil(value), do: {:ok, value}
  defp optional_string(_value), do: :error

  defp normalize_scopes(scopes) when is_list(scopes) do
    if Enum.all?(scopes, &is_binary/1),
      do: {:ok, scopes |> Enum.uniq() |> Enum.sort()},
      else: :error
  end

  defp normalize_scopes(_scopes), do: :error

  defp canonical_metadata(map) when is_map(map) and not is_struct(map), do: canonical_map(map)
  defp canonical_metadata(_map), do: :error

  defp canonical_map(map) do
    map
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn {key, value}, {:ok, pairs, seen} ->
      with {:ok, key} <- canonical_key(key),
           false <- MapSet.member?(seen, key),
           {:ok, value} <- canonical_value(value) do
        {:cont, {:ok, [{key, value} | pairs], MapSet.put(seen, key)}}
      else
        _invalid_or_duplicate -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, pairs, _seen} -> {:ok, {:map, Enum.sort(pairs)}}
      :error -> :error
    end
  end

  defp canonical_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}

  defp canonical_key(key) when is_binary(key) do
    if String.valid?(key), do: {:ok, key}, else: :error
  end

  defp canonical_key(_key), do: :error

  defp canonical_value(map) when is_map(map) and not is_struct(map), do: canonical_map(map)

  defp canonical_value(list) when is_list(list), do: canonical_list(list, [])

  defp canonical_value(nil), do: {:ok, :null}
  defp canonical_value(value) when is_boolean(value), do: {:ok, {:boolean, value}}
  defp canonical_value(value) when is_integer(value), do: {:ok, {:integer, value}}
  defp canonical_value(value) when is_float(value), do: {:ok, {:float, value}}

  defp canonical_value(value) when is_binary(value) do
    if String.valid?(value), do: {:ok, {:string, value}}, else: :error
  end

  defp canonical_value(_value), do: :error

  defp canonical_list([], values), do: {:ok, {:list, Enum.reverse(values)}}

  defp canonical_list([value | rest], values) do
    case canonical_value(value) do
      {:ok, value} -> canonical_list(rest, [value | values])
      :error -> :error
    end
  end

  defp canonical_list(_improper_tail, _values), do: :error

  defp header_digest(headers) when is_list(headers) do
    headers
    |> Enum.reduce_while({:ok, []}, fn
      {name, value}, {:ok, pairs} when is_binary(name) and is_binary(value) ->
        name = String.downcase(name)
        pairs = if relevant_header?(name), do: [{name, value} | pairs], else: pairs
        {:cont, {:ok, pairs}}

      _malformed, _pairs ->
        {:halt, :error}
    end)
    |> case do
      {:ok, pairs} ->
        digest =
          pairs |> Enum.sort() |> :erlang.term_to_binary() |> then(&:crypto.hash(:sha256, &1))

        {:ok, digest}

      :error ->
        :error
    end
  end

  defp relevant_header?(name),
    do: name in @identity_headers or String.starts_with?(name, "mcp-param-")

  defp check_cache(conn, key) do
    now = System.monotonic_time(:millisecond)
    ttl = config(:ttl_ms, @default_ttl_ms)

    case :ets.lookup(@table, key) do
      [{^key, entry}] ->
        case validate_cached_entry(entry, now, ttl) do
          {:ok, body, status, headers, version} ->
            conn
            |> assign(:mcp_idempotency_status, "hit")
            |> maybe_assign_protocol_version(version)
            |> replace_resp_headers(headers)
            |> send_resp(status, body)
            |> halt()

          :error ->
            cache_miss(conn, key, now, ttl)
        end

      _missing_or_invalid ->
        cache_miss(conn, key, now, ttl)
    end
  end

  defp validate_cached_entry({body, status, headers, version, timestamp}, now, ttl)
       when is_binary(body) and is_integer(status) and status in 100..599 and
              is_integer(timestamp) and timestamp <= now and now - timestamp < ttl do
    with {:ok, headers} <- normalize_replay_headers(headers),
         :ok <- validate_protocol_version(version) do
      {:ok, body, status, headers, version}
    else
      _invalid -> :error
    end
  end

  defp validate_cached_entry(_entry, _now, _ttl), do: :error

  defp normalize_replay_headers(headers) when is_list(headers),
    do: normalize_replay_headers(headers, [], MapSet.new())

  defp normalize_replay_headers(_headers), do: :error

  defp normalize_replay_headers([], headers, _seen), do: {:ok, Enum.reverse(headers)}

  defp normalize_replay_headers([{name, value} | rest], headers, seen)
       when is_binary(name) and is_binary(value) do
    if name in @replay_headers and safe_header_value?(value) and
         not MapSet.member?(seen, name) do
      normalize_replay_headers(rest, [{name, value} | headers], MapSet.put(seen, name))
    else
      :error
    end
  end

  defp normalize_replay_headers(_malformed_or_improper, _headers, _seen), do: :error

  defp safe_header_value?(value) do
    value
    |> :binary.bin_to_list()
    |> Enum.all?(fn byte -> byte == ?\t or (byte >= 32 and byte != 127) end)
  end

  defp validate_protocol_version(nil), do: :ok

  defp validate_protocol_version(version) when is_binary(version) do
    if version in Info.supported_versions() or
         version in ModernServer.supported_protocol_versions(),
       do: :ok,
       else: :error
  end

  defp validate_protocol_version(_version), do: :error

  defp cache_miss(conn, key, now, ttl) do
    :ets.delete(@table, key)
    maybe_sweep(now, ttl)

    conn = assign(conn, :mcp_idempotency_status, "miss")

    register_before_send(conn, fn response ->
      if cacheable_response?(response) do
        entry = {
          response.resp_body,
          response.status,
          replay_headers(response),
          protocol_version(response),
          now
        }

        :ets.insert(@table, {key, entry})
      end

      response
    end)
  end

  defp event_stream_requested?(conn) do
    conn
    |> get_req_header("accept")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.any?(fn range ->
      range |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase() ==
        "text/event-stream"
    end)
  end

  defp cacheable_response?(%{state: state, resp_body: body}),
    do: state not in [:set_chunked, :chunked] and is_binary(body)

  defp replay_headers(conn) do
    Enum.filter(conn.resp_headers, fn {name, value} ->
      String.downcase(name) in @replay_headers and is_binary(value)
    end)
  end

  defp replace_resp_headers(conn, headers) do
    conn = Enum.reduce(@replay_headers, conn, fn name, acc -> delete_resp_header(acc, name) end)
    prepend_resp_headers(conn, headers)
  end

  defp protocol_version(conn) do
    case conn.assigns[:mcp_protocol_version] do
      version when is_binary(version) -> version
      _missing -> nil
    end
  end

  defp maybe_assign_protocol_version(conn, version) when is_binary(version),
    do: assign(conn, :mcp_protocol_version, version)

  defp maybe_assign_protocol_version(conn, nil), do: conn

  defp maybe_sweep(now, ttl) do
    size = :ets.info(@table, :size)
    if :rand.uniform(50) == 1 or size > @max_table_size, do: sweep(now, ttl)
  end

  defp sweep(now, ttl) do
    Enum.each(:ets.tab2list(@table), fn
      {key, entry} ->
        case validate_cached_entry(entry, now, ttl) do
          {:ok, _body, _status, _headers, _version} -> :ok
          :error -> :ets.delete_object(@table, {key, entry})
        end

      malformed ->
        :ets.delete_object(@table, malformed)
    end)
  end

  defp ensure_table do
    if :ets.info(@table) == :undefined do
      try do
        :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
      rescue
        ArgumentError -> Logger.debug("Idempotency ETS table already created by another process")
      end
    end

    :ok
  end

  defp config(key, default) do
    :backplane |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
  end
end

defmodule Relayixir.Proxy.HttpPlug do
  @moduledoc """
  Orchestrates HTTP reverse proxying: upstream resolution, header preparation,
  request forwarding, and response streaming.
  """

  require Logger

  alias Relayixir.Proxy.{Headers, HttpClient, ErrorMapper, Upstream, Request, Response, ConnPool}
  alias Relayixir.Config.HookConfig

  @doc """
  Proxies the HTTP request to the resolved upstream.

  ## Options

    * `:body` (`binary() | nil`) — when present, sends this body directly to upstream
      instead of streaming from `Plug.Conn.read_body/1`.

    * `:on_response_chunk` (`(binary() -> :ok) | nil`) — when present, called for each
      response chunk in the streaming path (no content-length), before `Plug.Conn.chunk/2`
      forwards it to the client. Does not affect non-streaming (content-length) responses.

    * `:on_response_body` (`(binary() -> :ok) | nil`) — when present, called once with a
      collected response body before the unchanged body is sent downstream.

    * `:map_response_chunk` — when present, maps each upstream streaming chunk to
      zero or more downstream chunks before forwarding.

    * `:map_response_body` — when present, maps a collected non-streaming response
      body before it is sent downstream.

    * `:response_stream_mapper` — `{module, init_arg}` for a request-local streaming
      mapper implementing `init/3`, `feed/2`, and `finish/2`. This path remains
      streaming even when upstream supplies `content-length`.

  """
  @spec call(Plug.Conn.t(), Upstream.t(), keyword()) :: Plug.Conn.t()
  def call(%Plug.Conn{} = conn, %Upstream{} = upstream, opts \\ []) do
    start_time = System.monotonic_time()

    metadata = %{
      method: conn.method,
      path: build_upstream_path(conn, upstream),
      incoming_path: conn.request_path,
      upstream: "#{upstream.host}:#{upstream.port}"
    }

    :telemetry.execute(
      [:relayixir, :http, :request, :start],
      %{system_time: System.system_time()},
      metadata
    )

    case do_proxy(conn, upstream, opts) do
      {:ok, conn, request} ->
        duration_ms =
          System.convert_time_unit(System.monotonic_time() - start_time, :native, :millisecond)

        response = Response.new(conn.status, conn.resp_headers, duration_ms)

        :telemetry.execute(
          [:relayixir, :http, :request, :stop],
          %{duration: System.monotonic_time() - start_time},
          Map.merge(metadata, %{status: conn.status, request: request, response: response})
        )

        invoke_hook(request, response)
        conn

      {:error, reason, conn} ->
        duration = System.monotonic_time() - start_time
        conn = Plug.Conn.put_private(conn, :relayixir_proxy_error, reason)

        :telemetry.execute(
          [:relayixir, :http, :request, :exception],
          %{duration: duration},
          Map.merge(metadata, %{reason: reason})
        )

        handle_proxy_error(conn, reason, opts)
    end
  end

  @doc false
  def handle_proxy_error(%Plug.Conn{state: state} = conn, _reason, _opts)
      when state in [:sent, :chunked],
      do: conn

  def handle_proxy_error(conn, reason, opts) do
    case Keyword.get(opts, :on_proxy_error) do
      callback when is_function(callback, 2) -> callback.(conn, reason)
      _ -> ErrorMapper.send_error(conn, reason)
    end
  end

  defp do_proxy(conn, upstream, opts) do
    # Strip content-length so Mint uses chunked transfer encoding for streaming.
    # Replace route-level injected headers case-insensitively, then apply defaults
    # for provider metadata headers only when absent.
    request_headers =
      conn
      |> Headers.prepare_request_headers(upstream)
      |> Enum.reject(fn {name, _} -> String.downcase(name) == "content-length" end)
      |> Headers.merge_request_headers(
        upstream.inject_request_headers,
        upstream.default_request_headers
      )

    request = Request.from_conn(conn, request_headers, "#{upstream.host}:#{upstream.port}")
    path = build_upstream_path(conn, upstream)
    method = String.upcase(conn.method)

    with {:ok, mint_conn} <- connect_upstream(upstream),
         {:ok, mint_conn} <-
           send_request_with_body(conn, mint_conn, method, path, request_headers, upstream, opts) do
      case stream_response(conn, mint_conn, upstream, opts) do
        {:ok, conn} -> {:ok, conn, request}
        {:error, reason, conn} -> {:error, reason, conn}
      end
    else
      {:error, reason} ->
        {:error, map_error(reason, "connect_or_send", upstream, path), conn}

      {:error, mint_conn, reason} ->
        HttpClient.close(mint_conn)
        {:error, map_error(reason, "send", upstream, path), conn}
    end
  end

  defp send_request_with_body(conn, mint_conn, method, path, headers, upstream, opts) do
    case Keyword.get(opts, :body) do
      body when is_binary(body) ->
        # body: opt provided — send it directly (non-streaming).
        case HttpClient.send_request(mint_conn, method, path, headers, body) do
          {:ok, mint_conn, _ref} -> {:ok, mint_conn}
          {:error, mint_conn, reason} -> {:error, mint_conn, reason}
        end

      _ ->
        # Default: stream request body from Plug.Conn (original behavior).
        with {:ok, mint_conn, request_ref} <-
               HttpClient.send_request(mint_conn, method, path, headers, :stream),
             {:ok, mint_conn} <-
               stream_request_body(conn, mint_conn, request_ref, upstream.max_request_body_size) do
          {:ok, mint_conn}
        end
    end
  end

  # Reads the client request body in chunks and forwards each chunk to the upstream
  # via Mint's streaming API. Sends :eof after the last chunk.
  defp stream_request_body(conn, mint_conn, request_ref, max_size, bytes_read \\ 0)

  defp stream_request_body(conn, mint_conn, request_ref, max_size, bytes_read) do
    case Plug.Conn.read_body(conn, length: 65_536, read_length: 65_536) do
      {:ok, chunk, _conn} ->
        total = bytes_read + byte_size(chunk)

        if max_size != nil && total > max_size do
          {:error, mint_conn, :request_too_large}
        else
          with {:ok, mint_conn} <- HttpClient.stream_body_chunk(mint_conn, request_ref, chunk) do
            HttpClient.stream_body_chunk(mint_conn, request_ref, :eof)
          end
        end

      {:more, chunk, conn} ->
        total = bytes_read + byte_size(chunk)

        if max_size != nil && total > max_size do
          {:error, mint_conn, :request_too_large}
        else
          with {:ok, mint_conn} <- HttpClient.stream_body_chunk(mint_conn, request_ref, chunk) do
            stream_request_body(conn, mint_conn, request_ref, max_size, total)
          end
        end

      {:error, reason} ->
        {:error, mint_conn, reason}
    end
  end

  defp connect_upstream(upstream) do
    upstream_label = "#{upstream.host}:#{upstream.port}"

    :telemetry.execute(
      [:relayixir, :http, :upstream, :connect, :start],
      %{system_time: System.system_time()},
      %{upstream: upstream_label}
    )

    result = checkout_or_connect(upstream)

    case result do
      {:ok, _mint_conn} ->
        :telemetry.execute(
          [:relayixir, :http, :upstream, :connect, :stop],
          %{system_time: System.system_time()},
          %{upstream: upstream_label, result: :ok}
        )

      {:error, reason} ->
        :telemetry.execute(
          [:relayixir, :http, :upstream, :connect, :stop],
          %{system_time: System.system_time()},
          %{upstream: upstream_label, result: :error, reason: reason}
        )
    end

    result
  end

  defp checkout_or_connect(%Upstream{pool_size: nil} = upstream) do
    case HttpClient.connect(upstream) do
      {:ok, _} = ok -> ok
      {:error, _} -> {:error, :upstream_connect_failed}
    end
  end

  defp checkout_or_connect(%Upstream{pool_size: pool_size} = upstream)
       when is_integer(pool_size) and pool_size > 0 do
    case ConnPool.ensure_started(upstream) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "ConnPool.ensure_started failed: #{inspect(reason)}, falling back to fresh connection"
        )
    end

    case ConnPool.checkout(upstream) do
      {:ok, conn} ->
        {:ok, conn}

      {:error, :empty} ->
        case HttpClient.connect(upstream) do
          {:ok, _} = ok -> ok
          {:error, _} -> {:error, :upstream_connect_failed}
        end
    end
  end

  # Returns a connection to the pool (if pooling enabled) or closes it.
  defp release_conn(upstream, mint_conn) do
    if upstream.pool_size do
      ConnPool.checkin(upstream, mint_conn)
    else
      HttpClient.close(mint_conn)
    end
  end

  defp build_upstream_path(conn, upstream) do
    path =
      case upstream.path_prefix_rewrite do
        nil -> conn.request_path
        rewrite -> rewrite <> conn.request_path
      end

    case conn.query_string do
      "" -> path
      qs -> "#{path}?#{qs}"
    end
  end

  defp stream_response(conn, mint_conn, upstream, opts) do
    timeout = upstream.request_timeout
    fbt = upstream.first_byte_timeout

    case HttpClient.recv_until_headers(mint_conn, timeout, fbt) do
      {:ok, mint_conn, status, resp_headers, chunks, completeness} ->
        response_headers = Headers.prepare_response_headers(resp_headers)

        forward_response(
          conn,
          mint_conn,
          upstream,
          status,
          response_headers,
          chunks,
          completeness,
          opts
        )

      {:error, reason} ->
        {:error,
         map_error(reason, "receive_headers", upstream, build_upstream_path(conn, upstream)),
         conn}
    end
  end

  defp forward_response(
         conn,
         mint_conn,
         upstream,
         status,
         response_headers,
         _chunks,
         _complete,
         _opts
       )
       when status in [204, 304] do
    release_conn(upstream, mint_conn)

    conn =
      conn
      |> put_response_headers(response_headers)
      |> Plug.Conn.send_resp(status, "")

    {:ok, conn}
  end

  defp forward_response(
         conn,
         mint_conn,
         upstream,
         status,
         response_headers,
         chunks,
         completeness,
         opts
       ) do
    with {:ok, stream_mapper} <- init_stream_mapper(opts, status, response_headers) do
      forward_response_body(
        conn,
        mint_conn,
        upstream,
        status,
        response_headers,
        chunks,
        completeness,
        opts,
        stream_mapper
      )
    else
      {:error, reason} ->
        HttpClient.close(mint_conn)
        {:error, reason, conn}
    end
  end

  defp forward_response_body(
         conn,
         mint_conn,
         upstream,
         status,
         response_headers,
         chunks,
         completeness,
         opts,
         stream_mapper
       ) do
    if (has_content_length?(response_headers) and is_nil(stream_mapper)) or
         map_response_body?(opts) do
      # Collect body — bounded by the declared content-length.
      case collect_body(
             mint_conn,
             upstream.request_timeout,
             upstream.max_response_body_size,
             chunks,
             completeness
           ) do
        {:ok, mint_conn, body_chunks} ->
          release_conn(upstream, mint_conn)

          mapped =
            body_chunks
            |> IO.iodata_to_binary()
            |> maybe_map_response_body(status, response_headers, opts)

          {result, mapped_status, mapped_headers, body} =
            normalize_mapped_body(mapped, status, response_headers)

          observe_response_body(body, opts)

          conn =
            conn
            |> put_response_headers(body_response_headers(mapped_headers, opts))
            |> Plug.Conn.send_resp(mapped_status, body)

          case result do
            :ok -> {:ok, conn}
            {:error, reason} -> {:error, reason, conn}
          end

        {:error, reason} ->
          {:error, map_error(reason, "collect_body", upstream, conn.request_path), conn}
      end
    else
      # Stream each chunk to downstream immediately — no buffering.
      conn =
        conn
        |> put_response_headers(stream_response_headers(response_headers, stream_mapper))
        |> Plug.Conn.send_chunked(status)

      case completeness do
        :done ->
          send_pending_chunks(conn, mint_conn, upstream, chunks, opts, stream_mapper)

        :more ->
          stream_chunks_from_mint(conn, mint_conn, upstream, chunks, opts, stream_mapper)
      end
    end
  end

  defp collect_body(mint_conn, _timeout, max_size, chunks, :done) do
    if max_size != nil do
      total = chunks |> Enum.map(&byte_size/1) |> Enum.sum()

      if total > max_size do
        HttpClient.close(mint_conn)
        {:error, :response_too_large}
      else
        {:ok, mint_conn, chunks}
      end
    else
      {:ok, mint_conn, chunks}
    end
  end

  defp collect_body(mint_conn, timeout, max_size, chunks, :more) do
    HttpClient.recv_body(mint_conn, timeout, chunks, max_size)
  end

  defp send_pending_chunks(conn, mint_conn, upstream, [], opts, stream_mapper) do
    case finish_mapped_stream(conn, stream_mapper, :eof, opts) do
      {:ok, conn, _stream_mapper} ->
        release_conn(upstream, mint_conn)
        {:ok, conn}

      {:error, reason, conn, _stream_mapper} ->
        HttpClient.close(mint_conn)

        if reason == :closed do
          emit_downstream_disconnect()
          {:ok, Plug.Conn.put_private(conn, :relayixir_downstream_disconnected, true)}
        else
          {:error, reason, conn}
        end
    end
  end

  defp send_pending_chunks(conn, mint_conn, upstream, [chunk | rest], opts, stream_mapper) do
    case send_mapped_chunk(conn, chunk, opts, stream_mapper) do
      {:ok, conn, stream_mapper} ->
        send_pending_chunks(conn, mint_conn, upstream, rest, opts, stream_mapper)

      {:error, :closed} ->
        HttpClient.close(mint_conn)
        finish_stream_mapper(stream_mapper, :cancelled)
        emit_downstream_disconnect()
        {:ok, Plug.Conn.put_private(conn, :relayixir_downstream_disconnected, true)}

      {:error, reason, conn, _stream_mapper} ->
        HttpClient.close(mint_conn)
        {:error, reason, conn}
    end
  end

  defp has_content_length?(headers) do
    Enum.any?(headers, fn {name, _} -> String.downcase(name) == "content-length" end)
  end

  # Streams chunks from Mint to the downstream client immediately as they arrive.
  # pending_chunks holds any data already received during the headers phase.
  defp stream_chunks_from_mint(conn, mint_conn, upstream, pending_chunks, opts, stream_mapper) do
    conn_key = {__MODULE__, :stream_conn, make_ref()}
    Process.put(conn_key, {conn, stream_mapper, nil})

    try do
      on_chunk = fn chunk ->
        {current_conn, current_mapper, _error} =
          Process.get(conn_key, {conn, stream_mapper, nil})

        case send_mapped_chunk(current_conn, chunk, opts, current_mapper) do
          {:ok, next_conn, next_mapper} ->
            Process.put(conn_key, {next_conn, next_mapper, nil})
            :ok

          {:error, :closed} ->
            finish_stream_mapper(current_mapper, :cancelled)
            emit_downstream_disconnect()
            :stop

          {:error, reason, next_conn, next_mapper} ->
            Process.put(conn_key, {next_conn, next_mapper, reason})
            :stop
        end
      end

      case HttpClient.recv_body_streaming(
             mint_conn,
             upstream.request_timeout,
             pending_chunks,
             on_chunk
           ) do
        {:ok, mint_conn} ->
          {final_conn, final_mapper, _error} =
            Process.get(conn_key, {conn, stream_mapper, nil})

          case finish_mapped_stream(final_conn, final_mapper, :eof, opts) do
            {:ok, final_conn, _final_mapper} ->
              release_conn(upstream, mint_conn)
              {:ok, final_conn}

            {:error, reason, final_conn, _final_mapper} ->
              HttpClient.close(mint_conn)

              if reason == :closed do
                emit_downstream_disconnect()

                {:ok,
                 Plug.Conn.put_private(
                   final_conn,
                   :relayixir_downstream_disconnected,
                   true
                 )}
              else
                {:error, reason, final_conn}
              end
          end

        {:stop, mint_conn} ->
          HttpClient.close(mint_conn)

          {stopped_conn, _stopped_mapper, mapper_error} =
            Process.get(conn_key, {conn, stream_mapper, nil})

          if mapper_error do
            {:error, mapper_error, stopped_conn}
          else
            # Downstream disconnected — don't return to pool (request may be incomplete)
            disconnected_conn =
              Plug.Conn.put_private(stopped_conn, :relayixir_downstream_disconnected, true)

            {:ok, disconnected_conn}
          end

        {:error, reason} ->
          {final_conn, final_mapper, _error} =
            Process.get(conn_key, {conn, stream_mapper, nil})

          final_conn =
            case finish_mapped_stream(final_conn, final_mapper, reason, opts) do
              {:ok, mapped_conn, _mapper} -> mapped_conn
              {:error, _mapper_error, mapped_conn, _mapper} -> mapped_conn
            end

          {:error, map_error(reason, "stream_body", upstream, final_conn.request_path),
           final_conn}
      end
    after
      Process.delete(conn_key)
    end
  end

  defp maybe_map_response_body(body, status, headers, opts) do
    case opts[:map_response_body] do
      mapper when is_function(mapper, 3) -> mapper.(status, headers, body)
      mapper when is_function(mapper, 1) -> mapper.(body)
      _ -> body
    end
  end

  defp normalize_mapped_body({:ok, body}, status, headers) when is_binary(body),
    do: {:ok, status, headers, body}

  defp normalize_mapped_body({:error, reason, status, headers, body}, _status, _headers)
       when is_integer(status) and is_list(headers) and is_binary(body),
       do: {{:error, reason}, status, headers, body}

  defp normalize_mapped_body(body, status, headers) when is_binary(body),
    do: {:ok, status, headers, body}

  defp normalize_mapped_body(_mapped, _status, headers),
    do: {{:error, :invalid_response_body_mapping}, 502, headers, "Invalid mapped response"}

  defp observe_response_body(body, opts) do
    case opts[:on_response_body] do
      observer when is_function(observer, 1) -> safe_observe(observer, body)
      _ -> :ok
    end
  end

  defp map_response_body?(opts),
    do: is_function(opts[:map_response_body], 1) or is_function(opts[:map_response_body], 3)

  defp body_response_headers(headers, opts) do
    if map_response_body?(opts) do
      Enum.reject(headers, fn {name, _value} -> String.downcase(name) == "content-length" end)
    else
      headers
    end
  end

  defp send_mapped_chunk(conn, chunk, opts, stream_mapper) do
    case feed_stream_mapper(stream_mapper, chunk) do
      {:ok, stream_mapper, chunks} ->
        send_mapped_chunks(conn, chunks, opts, stream_mapper)

      {:error, reason, stream_mapper, chunks} ->
        case send_mapped_chunks(conn, chunks, opts, stream_mapper) do
          {:ok, conn, stream_mapper} -> {:error, reason, conn, stream_mapper}
          error -> error
        end
    end
  end

  defp send_mapped_chunks(conn, chunks, opts, stream_mapper) do
    response_callback = opts[:on_response_chunk]

    chunks
    |> Enum.flat_map(&mapped_response_chunks(&1, opts))
    |> Enum.reduce_while({:ok, conn}, fn mapped_chunk, {:ok, acc} ->
      if response_callback, do: safe_observe(response_callback, mapped_chunk)

      case Plug.Conn.chunk(acc, mapped_chunk) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        {:error, :closed} -> {:halt, {:error, :closed}}
      end
    end)
    |> case do
      {:ok, conn} -> {:ok, conn, stream_mapper}
      {:error, :closed} -> {:error, :closed}
    end
  end

  defp init_stream_mapper(opts, status, headers) do
    case opts[:response_stream_mapper] do
      {module, init_arg} when is_atom(module) ->
        case module.init(status, headers, init_arg) do
          {:ok, state} -> {:ok, %{module: module, state: state}}
          {:error, reason} -> {:error, {:response_stream_mapper, reason}}
        end

      nil ->
        {:ok, nil}

      _ ->
        {:error, {:response_stream_mapper, :invalid}}
    end
  end

  defp feed_stream_mapper(nil, chunk), do: {:ok, nil, [chunk]}

  defp feed_stream_mapper(%{module: module, state: state} = mapper, chunk) do
    case module.feed(state, chunk) do
      {:ok, state, chunks} ->
        {:ok, %{mapper | state: state}, normalize_mapped_chunks(chunks)}

      {:error, reason, state, chunks} ->
        {:error, {:response_stream_mapper, reason}, %{mapper | state: state},
         normalize_mapped_chunks(chunks)}
    end
  end

  defp finish_mapped_stream(conn, stream_mapper, reason, opts) do
    case finish_stream_mapper(stream_mapper, reason) do
      {:ok, stream_mapper, chunks} ->
        case send_mapped_chunks(conn, chunks, opts, stream_mapper) do
          {:error, :closed} -> {:error, :closed, conn, stream_mapper}
          result -> result
        end

      {:error, error, stream_mapper, chunks} ->
        case send_mapped_chunks(conn, chunks, opts, stream_mapper) do
          {:ok, conn, stream_mapper} -> {:error, error, conn, stream_mapper}
          {:error, :closed} -> {:error, :closed, conn, stream_mapper}
        end
    end
  end

  defp finish_stream_mapper(nil, _reason), do: {:ok, nil, []}

  defp finish_stream_mapper(%{module: module, state: state} = mapper, reason) do
    case module.finish(state, reason) do
      {:ok, state, chunks} ->
        {:ok, %{mapper | state: state}, normalize_mapped_chunks(chunks)}

      {:error, error, state, chunks} ->
        {:error, {:response_stream_mapper, error}, %{mapper | state: state},
         normalize_mapped_chunks(chunks)}
    end
  end

  defp stream_response_headers(headers, nil), do: headers

  defp stream_response_headers(headers, _mapper) do
    Enum.reject(headers, fn {name, _value} -> String.downcase(name) == "content-length" end)
  end

  defp mapped_response_chunks(chunk, opts) do
    case opts[:map_response_chunk] do
      mapper when is_function(mapper, 1) ->
        chunk
        |> mapper.()
        |> normalize_mapped_chunks()

      _ ->
        [chunk]
    end
  end

  defp normalize_mapped_chunks(nil), do: []
  defp normalize_mapped_chunks(chunk) when is_binary(chunk), do: [chunk]
  defp normalize_mapped_chunks(chunks) when is_list(chunks), do: chunks
  defp normalize_mapped_chunks(_chunk), do: []

  # Observation receives copies of already-forwardable bytes. An observer is not
  # part of transport correctness and must never fail the native relay.
  defp safe_observe(observer, bytes) do
    observer.(bytes)
    :ok
  rescue
    error ->
      Logger.warning("response observer raised: #{Exception.message(error)}")
      :ok
  catch
    kind, reason ->
      Logger.warning("response observer stopped: #{kind}=#{inspect(reason)}")
      :ok
  end

  defp put_response_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {name, value}, conn ->
      Plug.Conn.put_resp_header(conn, String.downcase(name), value)
    end)
  end

  defp emit_downstream_disconnect do
    :telemetry.execute(
      [:relayixir, :http, :downstream, :disconnect],
      %{system_time: System.system_time()},
      %{}
    )

    Logger.info("Downstream client disconnected during chunked response")
  end

  defp invoke_hook(request, response) do
    case HookConfig.get_on_request_complete() do
      nil -> :ok
      hook_fn -> hook_fn.(request, response)
    end
  rescue
    error ->
      Logger.warning("on_request_complete hook raised: #{inspect(error)}")
      :ok
  end

  defp map_error(:upstream_timeout, _stage, _upstream, _path), do: :upstream_timeout
  defp map_error(:upstream_connect_failed, _stage, _upstream, _path), do: :upstream_connect_failed

  defp map_error(:upstream_invalid_response, _stage, _upstream, _path),
    do: :upstream_invalid_response

  defp map_error(:response_too_large, _stage, _upstream, _path), do: :response_too_large
  defp map_error(:request_too_large, _stage, _upstream, _path), do: :request_too_large
  defp map_error(:nxdomain, _stage, _upstream, _path), do: :upstream_connect_failed
  defp map_error(:econnrefused, _stage, _upstream, _path), do: :upstream_connect_failed
  defp map_error(%Mint.TransportError{}, _stage, _upstream, _path), do: :upstream_connect_failed

  defp map_error(reason, stage, upstream, path) do
    raw_reason = inspect(reason)
    upstream = upstream_label(upstream)

    Logger.warning(
      "Relayixir mapped unexpected HTTP proxy error to internal_error stage=#{stage} upstream=#{upstream} path=#{path} raw_reason=#{raw_reason}",
      stage: stage,
      upstream: upstream,
      path: path,
      raw_reason: raw_reason
    )

    :internal_error
  end

  defp upstream_label(%Upstream{} = upstream), do: "#{upstream.host}:#{upstream.port}"
  defp upstream_label(_), do: nil
end

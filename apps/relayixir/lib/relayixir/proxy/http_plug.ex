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

  """
  @spec call(Plug.Conn.t(), Upstream.t(), keyword()) :: Plug.Conn.t()
  def call(%Plug.Conn{} = conn, %Upstream{} = upstream, opts \\ []) do
    start_time = System.monotonic_time()

    metadata = %{
      method: conn.method,
      path: conn.request_path,
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

        :telemetry.execute(
          [:relayixir, :http, :request, :exception],
          %{duration: duration},
          Map.merge(metadata, %{reason: reason})
        )

        if conn.state == :sent do
          conn
        else
          ErrorMapper.send_error(conn, reason)
        end
    end
  end

  defp do_proxy(conn, upstream, opts) do
    # Strip content-length so Mint uses chunked transfer encoding for streaming.
    # Then append any route-level injected headers (overriding earlier values if same name).
    request_headers =
      conn
      |> Headers.prepare_request_headers(upstream)
      |> Enum.reject(fn {name, _} -> String.downcase(name) == "content-length" end)
      |> Kernel.++(upstream.inject_request_headers)

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
        {:error, map_error(reason), conn}

      {:error, _mint_conn, reason} ->
        {:error, map_error(reason), conn}
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
          {:error, :request_too_large}
        else
          with {:ok, mint_conn} <- HttpClient.stream_body_chunk(mint_conn, request_ref, chunk) do
            HttpClient.stream_body_chunk(mint_conn, request_ref, :eof)
          end
        end

      {:more, chunk, conn} ->
        total = bytes_read + byte_size(chunk)

        if max_size != nil && total > max_size do
          {:error, :request_too_large}
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
        {:error, map_error(reason), conn}
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
    if has_content_length?(response_headers) do
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
          body = IO.iodata_to_binary(body_chunks)

          conn =
            conn
            |> put_response_headers(response_headers)
            |> Plug.Conn.send_resp(status, body)

          {:ok, conn}

        {:error, reason} ->
          {:error, map_error(reason), conn}
      end
    else
      # Stream each chunk to downstream immediately — no buffering.
      conn =
        conn
        |> put_response_headers(response_headers)
        |> Plug.Conn.send_chunked(status)

      case completeness do
        :done ->
          send_pending_chunks(conn, mint_conn, upstream, chunks, opts)

        :more ->
          stream_chunks_from_mint(conn, mint_conn, upstream, chunks, opts)
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

  defp send_pending_chunks(conn, mint_conn, upstream, [], _opts) do
    release_conn(upstream, mint_conn)
    {:ok, conn}
  end

  defp send_pending_chunks(conn, mint_conn, upstream, [chunk | rest], opts) do
    response_callback = opts[:on_response_chunk]
    if response_callback, do: response_callback.(chunk)

    case Plug.Conn.chunk(conn, chunk) do
      {:ok, conn} ->
        send_pending_chunks(conn, mint_conn, upstream, rest, opts)

      {:error, :closed} ->
        HttpClient.close(mint_conn)
        {:ok, conn}
    end
  end

  defp has_content_length?(headers) do
    Enum.any?(headers, fn {name, _} -> String.downcase(name) == "content-length" end)
  end

  # Streams chunks from Mint to the downstream client immediately as they arrive.
  # pending_chunks holds any data already received during the headers phase.
  defp stream_chunks_from_mint(conn, mint_conn, upstream, pending_chunks, opts) do
    response_callback = opts[:on_response_chunk]

    on_chunk = fn chunk ->
      if response_callback, do: response_callback.(chunk)

      case Plug.Conn.chunk(conn, chunk) do
        {:ok, _conn} ->
          :ok

        {:error, :closed} ->
          :telemetry.execute(
            [:relayixir, :http, :downstream, :disconnect],
            %{system_time: System.system_time()},
            %{}
          )

          Logger.info("Downstream client disconnected during chunked response")
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
        release_conn(upstream, mint_conn)
        {:ok, conn}

      {:stop, mint_conn} ->
        # Downstream disconnected — don't return to pool (request may be incomplete)
        HttpClient.close(mint_conn)
        {:ok, conn}

      {:error, reason} ->
        {:error, map_error(reason), conn}
    end
  end

  defp put_response_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {name, value}, conn ->
      Plug.Conn.put_resp_header(conn, String.downcase(name), value)
    end)
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

  defp map_error(:upstream_timeout), do: :upstream_timeout
  defp map_error(:upstream_connect_failed), do: :upstream_connect_failed
  defp map_error(:upstream_invalid_response), do: :upstream_invalid_response
  defp map_error(:response_too_large), do: :response_too_large
  defp map_error(:request_too_large), do: :request_too_large
  defp map_error(:nxdomain), do: :upstream_connect_failed
  defp map_error(:econnrefused), do: :upstream_connect_failed
  defp map_error(%Mint.TransportError{}), do: :upstream_connect_failed
  defp map_error(_), do: :internal_error
end

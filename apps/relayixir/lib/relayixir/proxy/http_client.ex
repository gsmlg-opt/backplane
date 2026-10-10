defmodule Relayixir.Proxy.HttpClient do
  @moduledoc """
  HTTP Fetch outbound requests with raw, acknowledged response streams.

  A connection is a request handle. Fetch owns socket establishment and optional
  HTTP/1 reuse; Relayixir owns header/body deadlines and downstream consumption.
  """

  require Logger

  alias Relayixir.Proxy.{ConnPool, EnvironmentProxy, RequestGuard, Upstream}

  defstruct [:upstream, :options, :promise, :controller, :guard, :upload, :response]

  @type t :: %__MODULE__{}

  @spec connect(Upstream.t(), map()) :: {:ok, t()}
  def connect(%Upstream{} = upstream, env \\ System.get_env()) do
    {:ok, %__MODULE__{upstream: upstream, options: connect_options(upstream, env)}}
  end

  @doc false
  @spec connect_options(Upstream.t(), map()) :: keyword()
  def connect_options(%Upstream{} = upstream, env \\ System.get_env()) do
    proxy_options =
      if upstream.proxy == :environment do
        options =
          EnvironmentProxy.connect_options(
            upstream.scheme || :http,
            upstream.host,
            upstream.port,
            env
          )

        case Keyword.get(options, :proxy) do
          nil ->
            []

          {scheme, host, port, _} ->
            [
              proxy:
                {scheme, host, port,
                 [
                   headers: Keyword.get(options, :proxy_headers, []),
                   timeout: upstream.connect_timeout
                 ]}
            ]
        end
      else
        []
      end

    [
      http_version: :http1,
      error_mode: :structured,
      request_mode: :proxy,
      redirect: :manual,
      decode_body: false,
      stream_response: true,
      tls_backend: :ssl,
      connect_timeout: upstream.connect_timeout,
      # Allow separate header and body phases; the adapter enforces each deadline.
      timeout: upstream.connect_timeout + 2 * upstream.request_timeout
    ] ++ proxy_options ++ ConnPool.options(upstream)
  end

  @spec send_request(t(), String.t(), String.t(), list(), binary() | nil | :stream) ::
          {:ok, t(), reference()} | {:error, t(), term()}
  def send_request(conn, method, path, headers, body \\ nil) do
    {:ok, guard, controller} = RequestGuard.start(self(), Keyword.fetch!(conn.options, :timeout))
    {body, upload} = request_body(body)

    options =
      conn.options ++
        [method: method, headers: headers, body: body, signal: controller] ++
        if(upload, do: [duplex: "half"], else: [])

    promise = HTTP.fetch(request_url(conn.upstream, path), options)
    if upload, do: RequestGuard.track_upload(guard, upload)
    conn = %{conn | promise: promise, controller: controller, guard: guard, upload: upload}
    {:ok, conn, promise.task.ref}
  end

  defp request_body(:stream) do
    {:ok, stream} = HTTP.Stream.start_link(0)
    {stream, stream}
  end

  defp request_body(body), do: {body, nil}

  defp request_url(upstream, path) do
    [path | query] = String.split(path, "?", parts: 2)
    uri = URI.parse("#{upstream.scheme || :http}:")

    %{
      uri
      | host: upstream.host,
        port: upstream.port,
        path: path,
        query: List.first(query)
    }
  end

  @spec stream_body_chunk(t(), reference(), binary() | :eof) ::
          {:ok, t()} | {:halt, t()} | {:error, t(), term()}
  def stream_body_chunk(%{upload: upload} = conn, _ref, :eof) do
    :ok = HTTP.Stream.finish(upload)
    {:ok, conn}
  end

  def stream_body_chunk(%{upload: upload} = conn, _ref, chunk) do
    case HTTP.Stream.chunk(upload, chunk, conn.upstream.request_timeout) do
      :ok ->
        {:ok, conn}

      {:error, _reason} ->
        case await_response(conn, conn.upstream.request_timeout) do
          {:ok, conn} -> {:halt, conn}
          {:error, reason} -> {:error, conn, reason}
        end
    end
  end

  @spec recv_until_headers(t(), non_neg_integer(), non_neg_integer() | nil) ::
          {:ok, t(), non_neg_integer(), list(), [binary()], :done | :more} | {:error, term()}
  def recv_until_headers(conn, timeout, first_byte_timeout \\ nil) do
    with {:ok, conn} <- await_response(conn, min(timeout, first_byte_timeout || timeout)) do
      response = conn.response

      headers =
        Enum.map(HTTP.Headers.to_list(response.headers), fn {name, value} ->
          {String.downcase(name), value}
        end)

      if is_pid(response.body) do
        {:ok, conn, response.status, headers, [], :more}
      else
        chunks = if response.body in [nil, ""], do: [], else: [response.body]
        {:ok, conn, response.status, headers, chunks, :done}
      end
    end
  end

  defp await_response(%{response: %HTTP.Response{}} = conn, _timeout), do: {:ok, conn}

  defp await_response(conn, timeout) do
    case Task.yield(conn.promise.task, timeout) do
      {:ok, %HTTP.Response{} = response} ->
        {:ok, %{conn | response: response}}

      {:ok, {:error, reason}} ->
        close(conn)
        {:error, map_reason(reason)}

      {:exit, _reason} ->
        close(conn)
        {:error, :upstream_invalid_response}

      nil ->
        close(conn)
        {:error, :upstream_timeout}
    end
  end

  @spec recv_response(t(), non_neg_integer(), non_neg_integer() | nil) ::
          {:ok, t(), list()} | {:error, term()}
  def recv_response(conn, timeout, first_byte_timeout \\ nil) do
    with {:ok, conn, status, headers, chunks, completeness} <-
           recv_until_headers(conn, timeout, first_byte_timeout),
         {:ok, conn, chunks} <- collect_response(conn, timeout, chunks, completeness) do
      {:ok, conn,
       [{:status, status}, {:headers, headers}] ++ Enum.map(chunks, &{:data, &1}) ++ [:done]}
    end
  end

  defp collect_response(conn, _timeout, chunks, :done), do: {:ok, conn, chunks}
  defp collect_response(conn, timeout, chunks, :more), do: recv_body(conn, timeout, chunks)

  @spec recv_body(t(), non_neg_integer(), [binary()], non_neg_integer() | nil) ::
          {:ok, t(), [binary()]} | {:error, term()}
  def recv_body(conn, timeout, pending_chunks \\ [], max_size \\ nil) do
    initial_size = Enum.reduce(pending_chunks, 0, &(byte_size(&1) + &2))

    callback = fn chunk, {chunks, size} ->
      size = size + byte_size(chunk)

      if max_size && size > max_size,
        do: {:halt, :response_too_large},
        else: {:cont, {[chunk | chunks], size}}
    end

    if max_size && initial_size > max_size do
      close(conn)
      {:error, :response_too_large}
    else
      case consume_stream(conn, timeout, callback, {Enum.reverse(pending_chunks), initial_size}) do
        {:ok, {chunks, _size}} ->
          {:ok, conn, Enum.reverse(chunks)}

        {:halt, reason} ->
          close(conn)
          {:error, reason}

        {:error, reason} ->
          close(conn)
          {:error, reason}
      end
    end
  end

  @spec recv_body_streaming(t(), non_neg_integer(), [binary()], (binary() -> :ok | :stop)) ::
          {:ok, t()} | {:stop, t()} | {:error, term()}
  def recv_body_streaming(conn, timeout, pending_chunks, on_chunk) do
    callback = fn chunk, :ok ->
      case on_chunk.(chunk) do
        :ok -> {:cont, :ok}
        :stop -> {:halt, :stop}
      end
    end

    pending =
      Enum.reduce_while(pending_chunks, :ok, fn chunk, :ok ->
        case on_chunk.(chunk) do
          :ok -> {:cont, :ok}
          :stop -> {:halt, :stop}
        end
      end)

    result =
      if pending == :stop, do: {:halt, :stop}, else: consume_stream(conn, timeout, callback, :ok)

    case result do
      {:ok, :ok} ->
        {:ok, conn}

      {:halt, :stop} ->
        {:stop, conn}

      {:error, reason} ->
        close(conn)
        {:error, reason}
    end
  end

  defp consume_stream(conn, timeout, callback, acc) do
    stream = conn.response.body
    monitor = Process.monitor(stream)
    send(stream, {:read_chunk, self(), :ack})

    try do
      read_stream(stream, monitor, System.monotonic_time(:millisecond) + timeout, callback, acc)
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  defp read_stream(stream, monitor, deadline, callback, acc) do
    receive do
      {:stream_chunk, ^stream, chunk, ref} ->
        case callback.(chunk, acc) do
          {:cont, acc} ->
            send(stream, {:stream_chunk_ack, ref})
            read_stream(stream, monitor, deadline, callback, acc)

          {:halt, reason} ->
            {:halt, reason}
        end

      {:stream_end, ^stream} ->
        {:ok, acc}

      {:stream_trailers, ^stream, _headers} ->
        read_stream(stream, monitor, deadline, callback, acc)

      {:stream_error, ^stream, reason} ->
        {:error, map_reason(reason)}

      {:DOWN, ^monitor, :process, ^stream, _reason} ->
        {:error, :upstream_invalid_response}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> {:error, :upstream_timeout}
    end
  end

  @doc """
  Releases a fully consumed request, returning Fetch's cleanup confirmation result.
  Fetch retains eligible HTTP/1 sockets. Explicit proxies return unsupported completion.
  """
  @spec release(t()) :: HTTP.RequestCompletion.result()
  def release(conn) do
    result =
      HTTP.RequestCompletion.await(
        HTTP.Promise.completion(conn.promise),
        conn.upstream.connect_timeout
      )

    finish_cleanup(conn, result)
  end

  @spec close(t()) :: {:ok, t()}
  def close(%__MODULE__{} = conn) do
    if conn.controller && Process.alive?(conn.controller),
      do: HTTP.AbortController.abort(conn.controller)

    result =
      if conn.promise do
        completion = HTTP.Promise.completion(conn.promise)
        result = HTTP.RequestCompletion.abort_and_await(completion, conn.upstream.connect_timeout)
        _ = Task.shutdown(conn.promise.task, :brutal_kill)
        result
      else
        :ok
      end

    stop_stream(conn.upload)
    if conn.response && is_pid(conn.response.body), do: stop_stream(conn.response.body)
    finish_cleanup(conn, result)
    {:ok, conn}
  end

  defp finish_cleanup(conn, :ok) do
    RequestGuard.release(conn.guard)
    :ok
  end

  defp finish_cleanup(conn, {:error, {:unsupported_completion, :proxy}} = result) do
    # credo:disable-for-next-line Credo.Check.Design.TagTODO
    # TODO(upstream): gsmlg-dev/http_fetch#82 - cleanup confirmation for explicit proxies.
    # WORKAROUND(upstream): gsmlg-dev/http_fetch#82 - public abort plus local teardown only.
    RequestGuard.release(conn.guard)
    result
  end

  defp finish_cleanup(_conn, {:error, reason} = result) do
    Logger.warning("Upstream request cleanup not confirmed: #{inspect(reason)}")
    result
  end

  defp stop_stream(nil), do: :ok

  defp stop_stream(stream) do
    Process.unlink(stream)
    if Process.alive?(stream), do: Process.exit(stream, :shutdown)
    :ok
  end

  defp map_reason(%HTTP.RequestError{reason: reason}), do: map_reason(reason)

  defp map_reason(reason)
       when reason in [:timeout, :request_timeout, :connect_timeout, :proxy_tunnel_timeout],
       do: :upstream_timeout

  defp map_reason(reason) when reason in [:econnrefused, :nxdomain, :enetunreach, :ehostunreach],
    do: :upstream_connect_failed

  defp map_reason({:proxy_connect_status, _}), do: :upstream_connect_failed
  defp map_reason({:tls_alert, _}), do: :upstream_connect_failed
  defp map_reason(_reason), do: :upstream_invalid_response
end

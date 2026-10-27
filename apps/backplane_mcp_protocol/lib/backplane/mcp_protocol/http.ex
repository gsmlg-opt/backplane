defmodule Backplane.McpProtocol.HTTP do
  @moduledoc false

  alias Backplane.McpProtocol.HTTP.Lifecycle
  alias Elixir.HTTP, as: Fetch

  @max_redirects 3
  @fetch_options ~w(http_version tls_backend ssl socket_opts proxy proxy_headers connect_address telemetry decode_body read_idle_timeout write_idle_timeout response_stream_ack_timeout http1_reuse http1_scope http1_pool_size http1_idle_timeout http2_reuse http2_scope)a
  @mcp_options ~w(allowed_origin request_timeout receive_timeout connect_timeout max_reconnections default_backoff max_backoff dest)a

  # request_timeout bounds the entire manual redirect chain; receive_timeout maps
  # to Fetch's stream inactivity policy. connect_timeout remains finite and is
  # capped by the request deadline. Retry/backoff settings belong to MCP SSE.
  # Supported Fetch extensions are @fetch_options; legacy pool/connection options
  # reject with names only, so configuration errors cannot expose credentials.
  # Fetch retains its default HTTP/1 + OTP TLS policy and never follows redirects.
  def build(method, url, headers \\ %{}, body \\ nil) do
    case URI.new(url) do
      {:ok, uri} ->
        headers = Enum.to_list(headers)

        headers =
          if Enum.any?(headers, fn {name, _} -> String.downcase(name) == "content-type" end),
            do: headers,
            else: [{"content-type", "application/json"} | headers]

        %{method: method, url: uri, headers: headers, body: body}

      {:error, _} ->
        {:error, :invalid_url}
    end
  end

  def post(url, headers \\ %{}, body \\ nil), do: build(:post, url, headers, body)

  @doc false
  def validate_options(opts) when is_list(opts) do
    if Keyword.keyword?(opts),
      do: validate_keyword_options(opts),
      else: {:error, {:invalid_http_options, %{reason: :expected_keyword}}}
  end

  def validate_options(_), do: {:error, {:invalid_http_options, %{reason: :expected_keyword}}}

  defp validate_keyword_options(opts) do
    unknown = Keyword.keys(opts) -- (@fetch_options ++ @mcp_options)

    cond do
      unknown != [] ->
        {:error, {:invalid_http_options, %{unsupported: unknown}}}

      not valid_timeout?(Keyword.get(opts, :request_timeout, 15_000), true) ->
        {:error, {:invalid_http_options, %{option: :request_timeout}}}

      not valid_timeout?(Keyword.get(opts, :receive_timeout, 15_000), true) ->
        {:error, {:invalid_http_options, %{option: :receive_timeout}}}

      not valid_timeout?(Keyword.get(opts, :connect_timeout, 10_000), false) ->
        {:error, {:invalid_http_options, %{option: :connect_timeout}}}

      true ->
        :ok
    end
  end

  defp valid_timeout?(:infinity, true), do: true
  defp valid_timeout?(value, _), do: is_integer(value) and value > 0

  def follow_redirect(request, opts \\ [], attempts \\ @max_redirects) do
    with :ok <- validate_options(opts), do: buffered_redirect(request, opts, attempts, deadline(opts))
  end

  # Authorization endpoints intentionally retain their existing no-redirect policy.
  def request(request, opts \\ []) do
    with :ok <- validate_options(opts),
         {:ok, response, completion} <- fetch(request, opts, deadline(opts)),
         {:ok, body} <- read_body(response, completion) do
      {:ok, normalize(response, body)}
    end
  end

  def stream_while(request, acc, callback, opts \\ []) do
    case validate_options(opts) do
      :ok -> stream_redirect(request, acc, callback, opts, @max_redirects, deadline(opts))
      {:error, reason} -> {:error, reason, acc}
    end
  end

  defp buffered_redirect(request, opts, attempts, deadline) do
    with {:ok, response, completion} <- fetch(request, opts, deadline),
         {:ok, body} <- read_body(response, completion) do
      response = normalize(response, body)

      if response.status == 307 do
        with {:ok, next} <- redirect(request, response.headers, opts, attempts) do
          buffered_redirect(next, opts, attempts - 1, deadline)
        end
      else
        {:ok, response}
      end
    end
  end

  defp stream_redirect(request, acc, callback, opts, attempts, deadline) do
    case fetch(request, opts, deadline) do
      {:ok, response, completion} ->
        headers = response.headers

        if response.status == 307 do
          with {:ok, _body} <- read_body(response, completion),
               {:ok, next} <- redirect(request, headers, opts, attempts) do
            stream_redirect(next, acc, callback, opts, attempts - 1, deadline)
          else
            {:error, reason} -> {:error, reason, acc}
          end
        else
          result =
            with {:cont, acc} <- callback.({:status, response.status}, acc),
                 {:cont, acc} <- callback.({:headers, headers}, acc) do
              consume(response.body, acc, callback, response.idle_timeout)
            end

          case result do
            {:halt, acc} ->
              Fetch.RequestCompletion.abort_and_await(completion, 1_000)
              {:ok, acc}

            {:error, _reason, _acc} = error ->
              Fetch.RequestCompletion.abort_and_await(completion, 1_000)
              error

            other ->
              other
          end
        end

      {:error, reason} ->
        {:error, reason, acc}
    end
  end

  defp read_body(response, completion) do
    case consume(
           response.body,
           [],
           fn
             {:data, chunk}, acc -> {:cont, [chunk | acc]}
             {:trailers, _}, acc -> {:cont, acc}
           end,
           response.idle_timeout
         ) do
      {:ok, chunks} ->
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

      {:error, reason, _} ->
        Fetch.RequestCompletion.abort_and_await(completion, 1_000)
        {:error, reason}
    end
  end

  defp consume(body, acc, callback, _timeout) when is_binary(body) do
    case callback.({:data, body}, acc) do
      {:cont, acc} -> {:ok, acc}
      {:halt, acc} -> {:halt, acc}
    end
  end

  defp consume(stream, acc, callback, timeout) when is_pid(stream) do
    monitor = Process.monitor(stream)
    send(stream, {:read_chunk, self(), :ack})

    try do
      consume_stream(stream, monitor, acc, callback, timeout)
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  defp consume_stream(stream, monitor, acc, callback, timeout) do
    receive do
      {:stream_chunk, ^stream, chunk, ack} ->
        case callback.({:data, chunk}, acc) do
          {:cont, acc} ->
            send(stream, {:stream_chunk_ack, ack})
            consume_stream(stream, monitor, acc, callback, timeout)

          {:halt, acc} ->
            {:halt, acc}
        end

      {:stream_chunk, ^stream, chunk} ->
        case callback.({:data, chunk}, acc) do
          {:cont, acc} -> consume_stream(stream, monitor, acc, callback, timeout)
          {:halt, acc} -> {:halt, acc}
        end

      {:stream_trailers, ^stream, headers} ->
        case callback.({:trailers, header_list(headers)}, acc) do
          {:cont, acc} -> consume_stream(stream, monitor, acc, callback, timeout)
          {:halt, acc} -> {:halt, acc}
        end

      {:stream_end, ^stream} ->
        {:ok, acc}

      {:stream_error, ^stream, reason} ->
        {:error, reason, acc}

      {:DOWN, ^monitor, :process, ^stream, reason} ->
        {:error, {:stream_down, reason}, acc}
    after
      timeout -> {:error, :timeout, acc}
    end
  end

  defp fetch(request, opts, deadline) do
    with :ok <- check_origin(request, Keyword.get(opts, :allowed_origin)),
         {:ok, obligation} <- allocation() do
      options =
        opts
        |> Keyword.take(@fetch_options)
        |> Keyword.merge(
          method: request.method,
          headers: request.headers,
          body: request.body,
          redirect: :manual,
          stream_response: true,
          timeout: bound(Keyword.get(opts, :request_timeout, 15_000), deadline),
          connect_timeout: bound(Keyword.get(opts, :connect_timeout, 10_000), deadline)
        )

      options =
        if Keyword.get(options, :http_version, :http1) == :http1,
          do:
            options
            |> Keyword.put(:response_stream_idle_timeout, Keyword.get(opts, :receive_timeout, 15_000))
            |> Keyword.put_new(:read_idle_timeout, idle_limit(Keyword.get(opts, :receive_timeout, 15_000))),
          else: options

      promise = Fetch.fetch(request.url, options)
      completion = Fetch.Promise.completion(promise)
      :ok = publish(obligation, completion)

      case await_response(promise, completion, Keyword.get(opts, :receive_timeout, 15_000)) do
        %Fetch.Response{} = response ->
          {:ok,
           %{
             status: response.status,
             headers: header_list(response.headers),
             body: response.body,
             trailers: header_list(response.trailers),
             idle_timeout: Keyword.get(opts, :receive_timeout, 15_000)
           }, completion}

        {:error, reason} ->
          {:error, reason}
      end
    end
  rescue
    _exception in [ArgumentError] -> {:error, {:invalid_http_options, %{reason: :invalid_fetch_configuration}}}
  end

  defp await_response(promise, completion, timeout) do
    Fetch.Promise.await(promise, timeout)
  catch
    :exit, {:timeout, _call} ->
      Fetch.RequestCompletion.abort_and_await(completion, 1_000)
      {:error, :timeout}
  end

  defp idle_limit(:infinity), do: nil
  defp idle_limit(timeout), do: timeout

  defp allocation do
    case Process.get(:mcp_http_lifecycle) do
      {lifecycle, job} -> with {:ok, id} <- Lifecycle.allocation(lifecycle, job), do: {:ok, {lifecycle, id}}
      nil -> {:ok, nil}
    end
  end

  defp publish(nil, _), do: :ok
  defp publish({lifecycle, id}, handle), do: Lifecycle.completion(lifecycle, id, handle)

  defp normalize(response, body),
    do: %{status: response.status, headers: response.headers, body: body, trailers: response.trailers}

  defp header_list(%Fetch.Headers{} = headers), do: Fetch.Headers.to_list(headers)
  defp header_list(headers) when is_list(headers), do: headers

  defp deadline(opts) do
    case Keyword.get(opts, :request_timeout, 15_000) do
      :infinity -> :infinity
      timeout -> System.monotonic_time(:millisecond) + timeout
    end
  end

  defp bound(value, :infinity), do: value
  defp bound(:infinity, deadline), do: max(deadline - System.monotonic_time(:millisecond), 1)
  defp bound(value, deadline), do: min(value, bound(:infinity, deadline))

  def check_origin(_url, nil), do: :ok
  def check_origin(%{url: url}, allowed), do: check_origin(url, allowed)

  def check_origin(url, allowed) do
    with {:ok, origin} <- origin(url),
         {:ok, ^origin} <- origin(allowed),
         do: :ok,
         else: (_ -> {:error, :cross_origin_redirect})
  end

  defp origin(url) when is_binary(url) or is_struct(url, URI) do
    with {:ok, %URI{scheme: scheme, host: host, port: port, userinfo: nil}} <- URI.new(url),
         true <- scheme in ["http", "https"],
         true <- is_binary(host) and host != "",
         true <- is_integer(port) and port in 1..65_535 do
      {:ok, {scheme, String.downcase(host), port}}
    else
      _ -> :error
    end
  end

  defp origin(_), do: :error

  defp redirect(_request, _headers, _opts, 0), do: {:error, :max_redirects}

  defp redirect(request, headers, opts, _attempts) do
    location = Enum.find_value(headers, fn {key, value} -> if String.downcase(key) == "location", do: value end)

    with true <- is_binary(location) and location != "",
         {:ok, uri} <- URI.new(location),
         uri = URI.merge(request.url, uri),
         {:ok, _} <- origin(uri),
         :ok <- check_origin(uri, Keyword.get(opts, :allowed_origin)) do
      {:ok, %{request | url: uri}}
    else
      {:error, :cross_origin_redirect} = error -> error
      _ -> {:error, :invalid_redirect}
    end
  end
end

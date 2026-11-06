defmodule Backplane.Audio.HTTP do
  @moduledoc "Passive, bounded HTTP/1 transport for one MiniMax audio request."

  alias Backplane.Audio.Error

  @read_bytes 16_384
  @write_bytes 32_768

  def post(origin, path, headers, body, deadline, max_bytes, receiver, initial)
      when is_binary(origin) and is_binary(path) and
             (is_function(receiver, 2) or is_function(receiver, 3)) do
    uri = URI.parse(origin)

    with :ok <- valid_origin(uri) do
      timeout = remaining(deadline)

      if timeout > 0 do
        target = URI.merge(uri, path)
        target_url = URI.to_string(target)

        case prepare_request(headers, body) do
          {:ok, fetch_headers, fetch_body, duplex} ->
            fetch_opts =
              [
                method: "POST",
                headers: fetch_headers,
                body: fetch_body,
                timeout: timeout,
                connect_timeout: min(timeout, 10_000),
                http_version: :http1,
                stream_response: true
              ]
              |> maybe_put_duplex(duplex)

            promise = HTTP.fetch(target_url, fetch_opts)

            case HTTP.Promise.await(promise, timeout) do
              %HTTP.Response{} = response ->
                process_response(response, max_bytes, receiver, initial, deadline)

              {:error, :timeout} ->
                {:error, timeout_error(), initial}

              {:error, {:timeout, _}} ->
                {:error, timeout_error(), initial}

              {:error, %HTTP.RequestError{reason: reason}}
              when reason in [:timeout, :idle_timeout, :read_idle_timeout] ->
                {:error, timeout_error(), initial}

              {:error, %HTTP.RequestError{reason: reason}}
              when reason in [:connect_failed, :closed, :econnrefused] ->
                {:error, error(502, "Provider connection failed", "audio_provider_unavailable"),
                 initial}

              {:error, _reason} ->
                {:error, error(502, "Provider connection failed", "audio_provider_unavailable"),
                 initial}
            end

          {:error, %Error{} = err} ->
            {:error, err, initial}
        end
      else
        {:error, timeout_error(), initial}
      end
    else
      {:error, error} -> {:error, error, initial}
    end
  end

  defp valid_origin(%URI{scheme: scheme, host: host, userinfo: nil, query: nil, fragment: nil})
       when scheme in ["https", "http"] and is_binary(host) and host != "",
       do: :ok

  defp valid_origin(_),
    do: {:error, error(502, "Invalid provider origin", "audio_provider_config")}

  defp prepare_request(headers, body) when is_binary(body) do
    fetch_headers = [
      {"content-length", Integer.to_string(byte_size(body))},
      {"accept-encoding", "identity"} | headers
    ]

    {:ok, fetch_headers, body, nil}
  end

  defp prepare_request(headers, {:enumerable, size, body}) do
    fetch_headers = [
      {"content-length", Integer.to_string(size)},
      {"accept-encoding", "identity"} | headers
    ]

    case HTTP.Stream.from_enumerable(body) do
      {:ok, stream} -> {:ok, fetch_headers, stream, "half"}
      {:error, _} -> {:error, error(503, "Audio input unavailable", "audio_input_unavailable")}
    end
  rescue
    _ -> {:error, error(503, "Audio input unavailable", "audio_input_unavailable")}
  end

  defp prepare_request(headers, {:file, prefix, path, suffix}) do
    with {:ok, %{size: size}} <- File.stat(path) do
      total_size = IO.iodata_length(prefix) + size + IO.iodata_length(suffix)

      fetch_headers = [
        {"content-length", Integer.to_string(total_size)},
        {"accept-encoding", "identity"} | headers
      ]

      enumerable =
        Stream.concat([
          [IO.iodata_to_binary(prefix)],
          File.stream!(path, [], @write_bytes),
          [IO.iodata_to_binary(suffix)]
        ])

      case HTTP.Stream.from_enumerable(enumerable) do
        {:ok, stream} -> {:ok, fetch_headers, stream, "half"}
        {:error, _} -> {:error, error(503, "Audio input unavailable", "audio_input_unavailable")}
      end
    else
      _ -> {:error, error(503, "Audio input unavailable", "audio_input_unavailable")}
    end
  rescue
    _ -> {:error, error(503, "Audio input unavailable", "audio_input_unavailable")}
  end

  defp process_response(response, max_bytes, receiver, initial, deadline) do
    headers_list =
      case response.headers do
        %HTTP.Headers{headers: h} ->
          Enum.map(h, fn {k, v} -> {String.downcase(to_string(k)), to_string(v)} end)

        headers when is_list(headers) ->
          Enum.map(headers, fn {k, v} -> {String.downcase(to_string(k)), to_string(v)} end)

        _ ->
          []
      end

    stream =
      cond do
        is_pid(response.body) -> response.body
        is_pid(response.stream) -> response.stream
        true -> nil
      end

    if stream do
      monitor = Process.monitor(stream)
      send(stream, {:read_chunk, self(), :ack})

      stream_ctx = %{
        stream: stream,
        monitor: monitor,
        status: response.status,
        headers: headers_list,
        max: max_bytes,
        receiver: receiver,
        deadline: deadline
      }

      consume_stream(stream_ctx, initial, 0)
    else
      body_bytes = response.body || ""

      if byte_size(body_bytes) > max_bytes do
        {:error, error(502, "Provider response too large", "audio_provider_too_large"), initial}
      else
        if response.status in 200..299 do
          resp_meta = %{status: response.status, headers: headers_list}

          case deliver_data(body_bytes, receiver, resp_meta, initial) do
            {:ok, acc} -> {:ok, response.status, headers_list, acc}
            {:error, %Error{} = reason, acc} -> {:error, reason, acc}
          end
        else
          status = if response.status == 429, do: 429, else: 502

          {:error, error(status, "Provider rejected audio request", "audio_provider_error"),
           initial}
        end
      end
    end
  end

  defp consume_stream(ctx, acc, bytes) do
    timeout = remaining(ctx.deadline)

    if timeout <= 0 do
      Process.demonitor(ctx.monitor, [:flush])
      HTTP.Stream.stop(ctx.stream, :timeout)
      {:error, timeout_error(), acc}
    else
      stream = ctx.stream

      receive do
        {:stream_chunk, ^stream, chunk, ack_ref} ->
          send(stream, {:stream_chunk_ack, ack_ref})
          handle_stream_chunk(ctx, acc, bytes, chunk)

        {:stream_chunk, ^stream, chunk} ->
          handle_stream_chunk(ctx, acc, bytes, chunk)

        {:stream_end, ^stream} ->
          Process.demonitor(ctx.monitor, [:flush])

          if ctx.status in 200..299 do
            {:ok, ctx.status, ctx.headers, acc}
          else
            err_status = if ctx.status == 429, do: 429, else: 502

            {:error,
             error(err_status, "Provider rejected audio request", "audio_provider_error"), acc}
          end

        {:stream_error, ^stream, _reason} ->
          Process.demonitor(ctx.monitor, [:flush])
          {:error, error(502, "Provider stream ended early", "audio_provider_incomplete"), acc}

        {:DOWN, monitor, :process, ^stream, _reason} when monitor == ctx.monitor ->
          {:error, error(502, "Provider stream ended early", "audio_provider_incomplete"), acc}
      after
        timeout ->
          Process.demonitor(ctx.monitor, [:flush])
          HTTP.Stream.stop(ctx.stream, :timeout)
          {:error, timeout_error(), acc}
      end
    end
  end

  defp handle_stream_chunk(ctx, acc, bytes, chunk) do
    new_bytes = bytes + byte_size(chunk)

    cond do
      new_bytes > ctx.max ->
        Process.demonitor(ctx.monitor, [:flush])
        HTTP.Stream.stop(ctx.stream, :too_large)
        {:error, error(502, "Provider response too large", "audio_provider_too_large"), acc}

      ctx.status not in 200..299 ->
        consume_stream(ctx, acc, new_bytes)

      true ->
        response = %{status: ctx.status, headers: ctx.headers}

        case deliver_data(chunk, ctx.receiver, response, acc) do
          {:ok, next_acc} ->
            consume_stream(ctx, next_acc, new_bytes)

          {:error, %Error{} = reason, next_acc} ->
            Process.demonitor(ctx.monitor, [:flush])
            HTTP.Stream.stop(ctx.stream, :cancelled)
            {:error, reason, next_acc}
        end
    end
  end

  defp deliver_data(<<>>, _receiver, _response, acc), do: {:ok, acc}

  defp deliver_data(data, receiver, _response, acc)
       when byte_size(data) <= @read_bytes and is_function(receiver, 2),
       do: receiver.(data, acc)

  defp deliver_data(data, receiver, response, acc) when byte_size(data) <= @read_bytes,
    do: receiver.(data, response, acc)

  defp deliver_data(data, receiver, response, acc) do
    <<part::binary-size(@read_bytes), rest::binary>> = data

    with {:ok, acc} <- deliver_data(part, receiver, response, acc),
         do: deliver_data(rest, receiver, response, acc)
  end

  defp maybe_put_duplex(opts, nil), do: opts
  defp maybe_put_duplex(opts, duplex), do: Keyword.put(opts, :duplex, duplex)
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
  defp timeout_error, do: error(504, "Audio provider timed out", "audio_timeout")
  defp error(status, message, code), do: Error.new(status, message, nil, code, "api_error")
end

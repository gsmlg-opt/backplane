defmodule Backplane.Audio.HTTP do
  @moduledoc "Passive, bounded HTTP/1 transport for one MiniMax audio request."

  alias Backplane.Audio.Error

  @read_bytes 16_384
  @write_bytes 32_768

  def post(origin, path, headers, body, deadline, max_bytes, receiver, initial)
      when is_binary(origin) and is_binary(path) and
             (is_function(receiver, 2) or is_function(receiver, 3)) do
    uri = URI.parse(origin)

    with :ok <- valid_origin(uri),
         {:ok, conn} <- connect(uri, deadline) do
      try do
        request(conn, uri, path, headers, body, %{
          deadline: deadline,
          max_bytes: max_bytes,
          receiver: receiver,
          initial: initial
        })
      after
        Mint.HTTP.close(conn)
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

  defp connect(uri, deadline) do
    timeout = remaining(deadline)

    if timeout > 0 do
      case Mint.HTTP.connect(
             String.to_existing_atom(uri.scheme),
             uri.host,
             uri.port || default_port(uri),
             protocols: [:http1],
             mode: :passive,
             transport_opts: [
               timeout: min(timeout, 10_000),
               send_timeout: min(timeout, 10_000),
               recbuf: @read_bytes
             ]
           ) do
        {:ok, conn} ->
          {:ok, conn}

        {:error, _} ->
          {:error, error(502, "Provider connection failed", "audio_provider_unavailable")}
      end
    else
      {:error, timeout_error()}
    end
  end

  defp request(conn, uri, path, headers, body, %{
         deadline: deadline,
         max_bytes: max_bytes,
         receiver: receiver,
         initial: initial
       }) do
    target = URI.merge(uri, path)
    target_path = (target.path || "/") <> if(target.query, do: "?" <> target.query, else: "")
    length = body_length(body)

    headers = [
      {"content-length", Integer.to_string(length)},
      {"accept-encoding", "identity"} | headers
    ]

    case Mint.HTTP.request(conn, "POST", target_path, headers, :stream) do
      {:ok, conn, ref} ->
        case send_body(conn, ref, body, deadline) do
          {:ok, conn} ->
            receive_response(conn, ref, deadline, max_bytes, receiver, %{
              status: nil,
              headers: [],
              bytes: 0,
              acc: initial
            })

          {:error, error} ->
            {:error, error, initial}
        end

      {:error, _, _} ->
        {:error, error(502, "Provider request failed", "audio_provider_unavailable"), initial}
    end
  end

  defp body_length(body) when is_binary(body), do: byte_size(body)

  defp body_length({:enumerable, size, _body}), do: size

  defp body_length({:file, prefix, path, suffix}) do
    {:ok, %{size: size}} = File.stat(path)
    IO.iodata_length(prefix) + size + IO.iodata_length(suffix)
  end

  defp send_body(conn, ref, body, deadline) when is_binary(body) do
    with {:ok, conn} <- send_bytes(conn, ref, body, deadline),
         {:ok, conn} <- Mint.HTTP.stream_request_body(conn, ref, :eof) do
      {:ok, conn}
    else
      _ -> {:error, error(502, "Provider upload failed", "audio_provider_unavailable")}
    end
  end

  defp send_body(conn, ref, {:enumerable, size, body}, deadline) do
    result =
      Enum.reduce_while(body, {:ok, conn, 0}, fn part, {:ok, conn, sent} ->
        bytes = IO.iodata_to_binary(part)
        next = sent + byte_size(bytes)

        if next > size do
          {:halt, {:error, error(502, "Multipart length mismatch", "audio_upload_invalid")}}
        else
          case send_bytes(conn, ref, bytes, deadline) do
            {:ok, conn} -> {:cont, {:ok, conn, next}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end
      end)

    case result do
      {:ok, conn, ^size} ->
        case Mint.HTTP.stream_request_body(conn, ref, :eof) do
          {:ok, conn} -> {:ok, conn}
          _ -> {:error, error(502, "Provider upload failed", "audio_provider_unavailable")}
        end

      {:ok, _conn, _} ->
        {:error, error(502, "Multipart length mismatch", "audio_upload_invalid")}

      error ->
        error
    end
  rescue
    _ -> {:error, error(503, "Audio input unavailable", "audio_input_unavailable")}
  end

  defp send_body(conn, ref, {:file, prefix, path, suffix}, deadline) do
    with {:ok, conn} <- send_bytes(conn, ref, IO.iodata_to_binary(prefix), deadline),
         {:ok, io} <- File.open(path, [:read, :binary, :raw]) do
      result =
        try do
          send_file(conn, ref, io, deadline)
        after
          File.close(io)
        end

      with {:ok, conn} <- result,
           {:ok, conn} <- send_bytes(conn, ref, IO.iodata_to_binary(suffix), deadline),
           {:ok, conn} <- Mint.HTTP.stream_request_body(conn, ref, :eof) do
        {:ok, conn}
      else
        _ -> {:error, error(502, "Provider upload failed", "audio_provider_unavailable")}
      end
    else
      _ -> {:error, error(503, "Audio input unavailable", "audio_input_unavailable")}
    end
  end

  defp send_file(conn, ref, io, deadline) do
    case IO.binread(io, @write_bytes) do
      :eof ->
        {:ok, conn}

      data when is_binary(data) ->
        with {:ok, conn} <- send_bytes(conn, ref, data, deadline),
             do: send_file(conn, ref, io, deadline)

      _ ->
        {:error, error(503, "Audio input unavailable", "audio_input_unavailable")}
    end
  end

  defp send_bytes(conn, _ref, <<>>, _deadline), do: {:ok, conn}

  defp send_bytes(conn, ref, bytes, deadline) when byte_size(bytes) <= @write_bytes do
    if remaining(deadline) > 0 do
      case Mint.HTTP.stream_request_body(conn, ref, bytes) do
        {:ok, conn} -> {:ok, conn}
        _ -> {:error, error(502, "Provider upload failed", "audio_provider_unavailable")}
      end
    else
      {:error, timeout_error()}
    end
  end

  defp send_bytes(conn, ref, bytes, deadline) do
    <<part::binary-size(@write_bytes), rest::binary>> = bytes

    with {:ok, conn} <- send_bytes(conn, ref, part, deadline),
         do: send_bytes(conn, ref, rest, deadline)
  end

  defp receive_response(conn, ref, deadline, max_bytes, receiver, state) do
    timeout = remaining(deadline)

    if timeout <= 0 do
      {:error, timeout_error(), state.acc}
    else
      case Mint.HTTP.recv(conn, 0, timeout) do
        {:ok, conn, events} ->
          case handle_events(events, ref, max_bytes, receiver, state) do
            {:continue, next} -> receive_response(conn, ref, deadline, max_bytes, receiver, next)
            result -> result
          end

        {:error, _conn, reason, events} ->
          case handle_events(events, ref, max_bytes, receiver, state) do
            {:continue, next} ->
              failure =
                if match?(%Mint.TransportError{reason: :timeout}, reason),
                  do: timeout_error(),
                  else: error(502, "Provider stream ended early", "audio_provider_incomplete")

              {:error, failure, next.acc}

            result ->
              result
          end
      end
    end
  end

  defp handle_events([], _ref, _max, _receiver, state), do: {:continue, state}

  defp handle_events([{:status, ref, code} | rest], ref, max, receiver, state),
    do: handle_events(rest, ref, max, receiver, %{state | status: code})

  defp handle_events([{:headers, ref, headers} | rest], ref, max, receiver, state),
    do: handle_events(rest, ref, max, receiver, %{state | headers: headers})

  defp handle_events([{:data, ref, data} | rest], ref, max, receiver, state) do
    bytes = state.bytes + byte_size(data)

    cond do
      bytes > max ->
        {:error, error(502, "Provider response too large", "audio_provider_too_large"), state.acc}

      state.status not in 200..299 ->
        handle_events(rest, ref, max, receiver, %{state | bytes: bytes})

      true ->
        response = %{status: state.status, headers: state.headers}

        case deliver_data(data, receiver, response, state.acc) do
          {:ok, acc} -> handle_events(rest, ref, max, receiver, %{state | bytes: bytes, acc: acc})
          {:error, %Error{} = reason, acc} -> {:error, reason, acc}
        end
    end
  end

  defp handle_events([{:done, ref} | _], ref, _max, _receiver, state) do
    if state.status in 200..299 do
      {:ok, state.status, state.headers, state.acc}
    else
      status = if state.status == 429, do: 429, else: 502

      {:error, error(status, "Provider rejected audio request", "audio_provider_error"),
       state.acc}
    end
  end

  defp handle_events([_ | rest], ref, max, receiver, state),
    do: handle_events(rest, ref, max, receiver, state)

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

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
  defp default_port(%URI{scheme: "https"}), do: 443
  defp default_port(_), do: 80
  defp timeout_error, do: error(504, "Audio provider timed out", "audio_timeout")
  defp error(status, message, code), do: Error.new(status, message, nil, code, "api_error")
end

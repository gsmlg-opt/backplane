defmodule Relayixir.Proxy.HttpClient do
  @moduledoc """
  Mint-based outbound HTTP client for upstream connections.
  """

  require Logger

  @doc """
  Opens a Mint HTTP connection to the upstream.
  """
  @spec connect(Relayixir.Proxy.Upstream.t()) :: {:ok, Mint.HTTP.t()} | {:error, term()}
  def connect(%Relayixir.Proxy.Upstream{} = upstream) do
    scheme = upstream.scheme || :http
    transport_opts = [timeout: upstream.connect_timeout]

    Mint.HTTP.connect(scheme, upstream.host, upstream.port,
      protocols: [:http1],
      transport_opts: transport_opts
    )
  end

  @doc """
  Sends an HTTP request on the Mint connection.
  """
  @spec send_request(
          Mint.HTTP.t(),
          String.t(),
          String.t(),
          [{String.t(), String.t()}],
          binary() | nil | :stream
        ) ::
          {:ok, Mint.HTTP.t(), Mint.Types.request_ref()} | {:error, Mint.HTTP.t(), term()}
  def send_request(conn, method, path, headers, body \\ nil) do
    Mint.HTTP.request(conn, method, path, headers, body)
  end

  @doc """
  Receives the full response from Mint by looping on messages.

  Returns `{:ok, conn, parts}` where parts is a list of
  `{:status, status}`, `{:headers, headers}`, `{:data, chunk}`, and `:done`.

  Returns `{:error, reason}` on timeout or transport error.
  """
  @spec recv_response(Mint.HTTP.t(), non_neg_integer(), non_neg_integer() | nil) ::
          {:ok, Mint.HTTP.t(), list()} | {:error, term()}
  def recv_response(conn, timeout, first_byte_timeout \\ nil) do
    deadline = System.monotonic_time(:millisecond) + timeout

    first_byte_deadline =
      if first_byte_timeout,
        do: System.monotonic_time(:millisecond) + first_byte_timeout,
        else: nil

    recv_loop(conn, deadline, first_byte_deadline, [])
  end

  @doc """
  Receives upstream response until both status and headers are available.

  Returns `{:ok, conn, status, headers, data_chunks, :done}` when the full response
  arrived in the same batch as the headers (common for small responses), or
  `{:ok, conn, status, headers, pending_chunks, :more}` when body chunks are still
  in flight and the caller must call `recv_body/3` or `recv_body_streaming/4`.

  Returns `{:error, reason}` on timeout or transport error.
  """
  @spec recv_until_headers(Mint.HTTP.t(), non_neg_integer(), non_neg_integer() | nil) ::
          {:ok, Mint.HTTP.t(), non_neg_integer(), list(), [binary()], :done | :more}
          | {:error, term()}
  def recv_until_headers(conn, timeout, first_byte_timeout \\ nil) do
    deadline = System.monotonic_time(:millisecond) + timeout

    first_byte_deadline =
      if first_byte_timeout,
        do: System.monotonic_time(:millisecond) + first_byte_timeout,
        else: nil

    recv_headers_loop(conn, deadline, first_byte_deadline, nil, nil, [])
  end

  @doc """
  Streams response body chunks to a callback after headers have been received.

  Calls `on_chunk.(binary())` for each data chunk. Returns `{:ok, conn}` when the
  response is complete, `{:stop, conn}` if `on_chunk` returns `:stop`,
  or `{:error, reason}` on timeout or transport error.
  """
  @spec recv_body_streaming(
          Mint.HTTP.t(),
          non_neg_integer(),
          [binary()],
          (binary() -> :ok | :stop)
        ) ::
          {:ok, Mint.HTTP.t()} | {:stop, Mint.HTTP.t()} | {:error, term()}
  def recv_body_streaming(conn, timeout, pending_chunks, on_chunk) do
    result =
      Enum.reduce_while(pending_chunks, :ok, fn chunk, :ok ->
        case on_chunk.(chunk) do
          :ok -> {:cont, :ok}
          :stop -> {:halt, :stop}
        end
      end)

    case result do
      :stop ->
        {:stop, conn}

      :ok ->
        deadline = System.monotonic_time(:millisecond) + timeout
        recv_body_loop(conn, deadline, on_chunk)
    end
  end

  @doc """
  Streams one chunk (or `:eof`) of a request body on an open streaming request.

  Call after `send_request/5` with `body: :stream`.
  Returns `{:ok, conn}` or `{:error, conn, reason}`.
  """
  @spec stream_body_chunk(Mint.HTTP.t(), Mint.Types.request_ref(), binary() | :eof) ::
          {:ok, Mint.HTTP.t()} | {:error, Mint.HTTP.t(), term()}
  def stream_body_chunk(conn, request_ref, chunk) do
    Mint.HTTP.stream_request_body(conn, request_ref, chunk)
  end

  @doc """
  Closes the Mint connection.
  """
  @spec close(Mint.HTTP.t()) :: {:ok, Mint.HTTP.t()}
  def close(conn) do
    Mint.HTTP.close(conn)
  end

  @doc """
  Collects remaining body chunks into a list after headers have been received.

  `pending_chunks` holds any data already received during the headers phase.
  Returns `{:ok, conn, [binary()]}` or `{:error, reason}`.
  """
  @spec recv_body(Mint.HTTP.t(), non_neg_integer(), [binary()], non_neg_integer() | nil) ::
          {:ok, Mint.HTTP.t(), [binary()]} | {:error, term()}
  def recv_body(conn, timeout, pending_chunks \\ [], max_size \\ nil) do
    deadline = System.monotonic_time(:millisecond) + timeout
    initial_acc = Enum.reverse(pending_chunks)
    initial_size = initial_acc |> Enum.map(&byte_size/1) |> Enum.sum()
    recv_body_collect(conn, deadline, initial_acc, initial_size, max_size)
  end

  defp recv_body_collect(conn, deadline, acc, acc_size, max_size) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      Mint.HTTP.close(conn)
      {:error, :upstream_timeout}
    else
      receive do
        message ->
          case Mint.HTTP.stream(conn, message) do
            :unknown ->
              recv_body_collect(conn, deadline, acc, acc_size, max_size)

            {:ok, conn, responses} ->
              case collect_body_batch_sized(responses, acc, 0) do
                {:done, chunks, _batch_size} ->
                  {:ok, conn, Enum.reverse(chunks)}

                {:continue, new_acc, batch_size} ->
                  new_size = acc_size + batch_size

                  if max_size != nil && new_size > max_size do
                    Mint.HTTP.close(conn)
                    {:error, :response_too_large}
                  else
                    recv_body_collect(conn, deadline, new_acc, new_size, max_size)
                  end
              end

            {:error, conn, _reason, _} ->
              Mint.HTTP.close(conn)
              {:error, :upstream_invalid_response}
          end
      after
        remaining ->
          Mint.HTTP.close(conn)
          {:error, :upstream_timeout}
      end
    end
  end

  defp collect_body_batch_sized([], acc, size), do: {:continue, acc, size}

  defp collect_body_batch_sized([{:data, _ref, d} | rest], acc, size) do
    collect_body_batch_sized(rest, [d | acc], size + byte_size(d))
  end

  defp collect_body_batch_sized([{:done, _ref} | _], acc, size), do: {:done, acc, size}

  defp collect_body_batch_sized([_ | rest], acc, size),
    do: collect_body_batch_sized(rest, acc, size)

  defp recv_headers_loop(conn, deadline, fbd, status, headers, pending) do
    remaining = deadline - System.monotonic_time(:millisecond)

    fb_remaining =
      if fbd && status == nil,
        do: fbd - System.monotonic_time(:millisecond),
        else: nil

    effective = if fb_remaining, do: min(remaining, fb_remaining), else: remaining

    if effective <= 0 do
      Mint.HTTP.close(conn)
      {:error, :upstream_timeout}
    else
      receive do
        message ->
          case Mint.HTTP.stream(conn, message) do
            :unknown ->
              recv_headers_loop(conn, deadline, fbd, status, headers, pending)

            {:ok, conn, responses} ->
              {new_status, new_headers, new_pending, done?} =
                collect_header_batch(responses, status, headers, pending)

              cond do
                done? ->
                  {:ok, conn, new_status || 200, new_headers || [], Enum.reverse(new_pending),
                   :done}

                new_status != nil && new_headers != nil ->
                  {:ok, conn, new_status, new_headers, Enum.reverse(new_pending), :more}

                true ->
                  recv_headers_loop(conn, deadline, fbd, new_status, new_headers, new_pending)
              end

            {:error, conn, reason, _} ->
              Mint.HTTP.close(conn)
              Logger.error("Mint stream error: #{inspect(reason)}")
              {:error, :upstream_invalid_response}
          end
      after
        effective ->
          Mint.HTTP.close(conn)
          {:error, :upstream_timeout}
      end
    end
  end

  defp collect_header_batch([], status, headers, pending), do: {status, headers, pending, false}

  defp collect_header_batch([{:status, _ref, s} | rest], _, headers, pending) do
    collect_header_batch(rest, s, headers, pending)
  end

  defp collect_header_batch([{:headers, _ref, h} | rest], status, _, pending) do
    collect_header_batch(rest, status, h, pending)
  end

  defp collect_header_batch([{:data, _ref, d} | rest], status, headers, pending) do
    collect_header_batch(rest, status, headers, [d | pending])
  end

  defp collect_header_batch([{:done, _ref} | rest], status, headers, pending) do
    {new_status, new_headers, new_pending, _} =
      collect_header_batch(rest, status, headers, pending)

    {new_status, new_headers, new_pending, true}
  end

  defp collect_header_batch([_ | rest], status, headers, pending) do
    collect_header_batch(rest, status, headers, pending)
  end

  defp recv_body_loop(conn, deadline, on_chunk) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      Mint.HTTP.close(conn)
      {:error, :upstream_timeout}
    else
      receive do
        message ->
          case Mint.HTTP.stream(conn, message) do
            :unknown ->
              recv_body_loop(conn, deadline, on_chunk)

            {:ok, conn, responses} ->
              case dispatch_body_batch(responses, on_chunk) do
                :done -> {:ok, conn}
                :stop -> {:stop, conn}
                :continue -> recv_body_loop(conn, deadline, on_chunk)
              end

            {:error, conn, reason, _} ->
              Mint.HTTP.close(conn)
              Logger.error("Mint stream error: #{inspect(reason)}")
              {:error, :upstream_invalid_response}
          end
      after
        remaining ->
          Mint.HTTP.close(conn)
          {:error, :upstream_timeout}
      end
    end
  end

  defp dispatch_body_batch([], _on_chunk), do: :continue

  defp dispatch_body_batch([{:data, _ref, data} | rest], on_chunk) do
    case on_chunk.(data) do
      :ok -> dispatch_body_batch(rest, on_chunk)
      :stop -> :stop
    end
  end

  defp dispatch_body_batch([{:done, _ref} | _], _on_chunk), do: :done
  defp dispatch_body_batch([_ | rest], on_chunk), do: dispatch_body_batch(rest, on_chunk)

  defp recv_loop(conn, deadline, first_byte_deadline, acc) do
    remaining = deadline - System.monotonic_time(:millisecond)

    first_byte_remaining =
      if first_byte_deadline && acc == [] do
        first_byte_deadline - System.monotonic_time(:millisecond)
      else
        nil
      end

    effective_remaining =
      case first_byte_remaining do
        nil -> remaining
        fbr -> min(remaining, fbr)
      end

    if effective_remaining <= 0 do
      Mint.HTTP.close(conn)
      {:error, :upstream_timeout}
    else
      receive do
        message ->
          case Mint.HTTP.stream(conn, message) do
            :unknown ->
              recv_loop(conn, deadline, first_byte_deadline, acc)

            {:ok, conn, responses} ->
              {new_acc, done?} = process_responses(responses, acc)

              if done? do
                {:ok, conn, Enum.reverse(new_acc)}
              else
                recv_loop(conn, deadline, first_byte_deadline, new_acc)
              end

            {:error, conn, reason, _responses} ->
              Mint.HTTP.close(conn)
              Logger.error("Mint stream error: #{inspect(reason)}")
              {:error, :upstream_invalid_response}
          end
      after
        effective_remaining ->
          Mint.HTTP.close(conn)
          {:error, :upstream_timeout}
      end
    end
  end

  defp process_responses(responses, acc) do
    Enum.reduce(responses, {acc, false}, fn
      {:status, _ref, status}, {parts, _done} ->
        {[{:status, status} | parts], false}

      {:headers, _ref, headers}, {parts, _done} ->
        {[{:headers, headers} | parts], false}

      {:data, _ref, data}, {parts, _done} ->
        {[{:data, data} | parts], false}

      {:done, _ref}, {parts, _done} ->
        {[:done | parts], true}

      {:error, _ref, reason}, {parts, _done} ->
        {[{:error, reason} | parts], true}
    end)
  end
end

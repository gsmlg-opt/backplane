defmodule Backplane.Proxy.SSEClient do
  @moduledoc """
  Persistent SSE GET connection manager.

  Opens a streaming GET to an SSE endpoint and sends parsed events
  to a parent process as `{:sse_event, ref, event}` messages.
  Sends `{:sse_closed, ref, reason}` when the connection ends.

  Returns `{:ok, ref, pid}` so the caller can store the pid externally
  and pass it to `close/2` from any process.
  """

  alias Backplane.HTTPClient.Error
  alias Backplane.Proxy.SSEParser

  # 10 MB buffer cap — matches stdio transport limit in Upstream
  @max_buffer_size 10_000_000

  @spec connect(String.t(), [{String.t(), String.t()}], pid()) ::
          {:ok, reference(), pid()} | {:error, term()}
  def connect(url, headers, parent) do
    ref = make_ref()

    pid =
      spawn(fn ->
        run_stream(url, headers, ref, parent)
      end)

    {:ok, ref, pid}
  end

  @spec close(reference(), pid() | nil) :: :ok
  def close(_ref, nil), do: :ok

  def close(_ref, pid) do
    Process.exit(pid, :shutdown)
    :ok
  end

  defp run_stream(url, headers, ref, parent) do
    all_headers = [{"accept", "text/event-stream"} | headers]

    result =
      try do
        url
        |> HTTP.fetch(
          method: "GET",
          headers: all_headers,
          stream_response: true,
          timeout: :infinity,
          response_stream_idle_timeout: :infinity
        )
        |> HTTP.Promise.await(:infinity)
      rescue
        e -> {:error, Exception.message(e)}
      catch
        :exit, reason -> {:error, reason}
      end

    case result do
      %HTTP.Response{} = response ->
        start_body(response, ref, parent)

      {:error, reason} when is_binary(reason) ->
        send(parent, {:sse_closed, ref, reason})

      {:error, reason} ->
        send(parent, {:sse_closed, ref, Error.exception(reason: reason)})
    end
  end

  defp start_body(response, ref, parent) do
    case HTTP.Response.stream_pid(response) do
      pid when is_pid(pid) ->
        monitor = Process.monitor(pid)
        send(pid, {:read_chunk, self(), :ack})
        stream_loop({pid, monitor}, ref, parent, "")

      nil ->
        handle_chunk(:buffered, ref, parent, "", response.body || "")
    end
  end

  defp stream_loop(:buffered, ref, parent, _buffer), do: send(parent, {:sse_closed, ref, :normal})

  defp stream_loop({pid, monitor} = stream, ref, parent, buffer) do
    receive do
      {:stream_chunk, ^pid, chunk, ack_ref} ->
        send(pid, {:stream_chunk_ack, ack_ref})
        handle_chunk(stream, ref, parent, buffer, chunk)

      {:stream_chunk, ^pid, chunk} ->
        handle_chunk(stream, ref, parent, buffer, chunk)

      {:stream_trailers, ^pid, _trailers} ->
        stream_loop(stream, ref, parent, buffer)

      {:stream_end, ^pid} ->
        Process.demonitor(monitor, [:flush])
        send(parent, {:sse_closed, ref, :normal})

      {:stream_error, ^pid, reason} ->
        Process.demonitor(monitor, [:flush])
        send(parent, {:sse_closed, ref, reason})

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        send(parent, {:sse_closed, ref, {:stream_down, reason}})
    end
  end

  defp handle_chunk(stream, ref, parent, buffer, chunk) do
    {events, rest} = SSEParser.parse(chunk, buffer)

    if byte_size(rest) > @max_buffer_size do
      stop_stream(stream)
      send(parent, {:sse_closed, ref, :buffer_overflow})
    else
      for event <- events do
        send(parent, {:sse_event, ref, event})
      end

      stream_loop(stream, ref, parent, rest)
    end
  end

  defp stop_stream({pid, monitor}) do
    Process.demonitor(monitor, [:flush])
    HTTP.Stream.stop(pid, :cancelled)
  end

  defp stop_stream(:buffered), do: :ok
end

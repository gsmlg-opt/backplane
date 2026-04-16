defmodule Backplane.Proxy.SSEClient do
  @moduledoc """
  Persistent SSE GET connection manager.

  Opens a streaming GET to an SSE endpoint and sends parsed events
  to a parent process as `{:sse_event, ref, event}` messages.
  Sends `{:sse_closed, ref, reason}` when the connection ends.

  Returns `{:ok, ref, pid}` so the caller can store the pid externally
  and pass it to `close/2` from any process.
  """

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
        Req.request(
          url: url,
          method: :get,
          headers: all_headers,
          into: :self,
          receive_timeout: :infinity,
          decode_body: false,
          retry: false
        )
      rescue
        e -> {:error, Exception.message(e)}
      end

    case result do
      {:ok, resp} ->
        stream_loop(resp.body, ref, parent, "")

      {:error, reason} ->
        send(parent, {:sse_closed, ref, reason})
    end
  end

  defp stream_loop(%Req.Response.Async{} = async, ref, parent, buffer) do
    async_ref = async.ref

    receive do
      {^async_ref, _} = message ->
        case async.stream_fun.(async.ref, message) do
          {:ok, [data: chunk]} ->
            handle_chunk(async, ref, parent, buffer, chunk)

          {:ok, [:done]} ->
            send(parent, {:sse_closed, ref, :normal})

          {:ok, [trailers: _trailers]} ->
            stream_loop(async, ref, parent, buffer)

          {:error, reason} ->
            send(parent, {:sse_closed, ref, reason})
        end
    end
  end

  defp handle_chunk(async, ref, parent, buffer, chunk) do
    {events, rest} = SSEParser.parse(chunk, buffer)

    if byte_size(rest) > @max_buffer_size do
      send(parent, {:sse_closed, ref, :buffer_overflow})
    else
      for event <- events do
        send(parent, {:sse_event, ref, event})
      end

      stream_loop(async, ref, parent, rest)
    end
  end
end

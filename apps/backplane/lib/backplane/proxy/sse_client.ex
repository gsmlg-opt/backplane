defmodule Backplane.Proxy.SSEClient do
  @moduledoc """
  Persistent SSE GET connection manager.

  Opens a streaming GET to an SSE endpoint and sends parsed events
  to a parent process as `{:sse_event, ref, event}` messages.
  Sends `{:sse_closed, ref, reason}` when the connection ends.
  """

  alias Backplane.Proxy.SSEParser

  @spec connect(String.t(), [{String.t(), String.t()}], pid()) ::
          {:ok, reference()} | {:error, term()}
  def connect(url, headers, parent) do
    ref = make_ref()

    pid =
      spawn_link(fn ->
        run_stream(url, headers, ref, parent)
      end)

    # Store for close/1
    Process.put({:sse_client, ref}, pid)
    {:ok, ref}
  end

  @spec close(reference()) :: :ok
  def close(ref) do
    case Process.get({:sse_client, ref}) do
      nil ->
        :ok

      pid ->
        Process.unlink(pid)
        Process.exit(pid, :shutdown)
        Process.delete({:sse_client, ref})
        :ok
    end
  end

  defp run_stream(url, headers, ref, parent) do
    all_headers = [{"accept", "text/event-stream"} | headers]

    case Req.request(
           url: url,
           method: :get,
           headers: all_headers,
           into: :self,
           receive_timeout: :infinity,
           decode_body: false
         ) do
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
            {events, rest} = SSEParser.parse(chunk, buffer)

            for event <- events do
              send(parent, {:sse_event, ref, event})
            end

            stream_loop(async, ref, parent, rest)

          {:ok, [:done]} ->
            send(parent, {:sse_closed, ref, :normal})

          {:ok, [trailers: _trailers]} ->
            stream_loop(async, ref, parent, buffer)

          {:error, reason} ->
            send(parent, {:sse_closed, ref, reason})
        end
    end
  end
end

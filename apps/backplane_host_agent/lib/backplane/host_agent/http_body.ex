defmodule Backplane.HostAgent.HTTPBody do
  @moduledoc """
  Acknowledged consumption of an `HTTP.fetch/2` response body.

  The host-agent release does not include `backplane_system`, so host-agent
  requests call `HTTP.fetch/2` directly and read streamed bodies here. Each
  chunk is acknowledged only after `fun` returns, which keeps reads paced by the
  consumer.
  """

  @doc """
  Reduces the response body with `fun` until it ends, `fun` halts, the stream
  fails, or `deadline` (monotonic milliseconds or `:infinity`) passes.
  """
  @spec reduce(HTTP.Response.t(), integer() | :infinity, acc, (binary(), acc -> step)) ::
          {:ok, acc} | {:halt, acc} | {:error, term(), acc}
        when acc: term(), step: {:cont, acc} | {:halt, acc}
  def reduce(%HTTP.Response{} = response, deadline, acc, fun) when is_function(fun, 2) do
    case HTTP.Response.stream_pid(response) do
      pid when is_pid(pid) ->
        monitor = Process.monitor(pid)
        send(pid, {:read_chunk, self(), :ack})

        try do
          loop(pid, monitor, deadline, acc, fun)
        after
          Process.demonitor(monitor, [:flush])
        end

      nil ->
        buffered(response.body || "", acc, fun)
    end
  end

  defp buffered("", acc, _fun), do: {:ok, acc}

  defp buffered(body, acc, fun) do
    case fun.(body, acc) do
      {:cont, acc} -> {:ok, acc}
      {:halt, acc} -> {:halt, acc}
    end
  end

  defp loop(pid, monitor, deadline, acc, fun) do
    receive do
      {:stream_chunk, ^pid, chunk, ack_ref} ->
        result = fun.(chunk, acc)
        send(pid, {:stream_chunk_ack, ack_ref})
        continue(result, pid, monitor, deadline, fun)

      {:stream_chunk, ^pid, chunk} ->
        continue(fun.(chunk, acc), pid, monitor, deadline, fun)

      {:stream_trailers, ^pid, _trailers} ->
        loop(pid, monitor, deadline, acc, fun)

      {:stream_end, ^pid} ->
        {:ok, acc}

      {:stream_error, ^pid, reason} ->
        {:error, reason, acc}

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:error, {:stream_down, reason}, acc}
    after
      remaining(deadline) ->
        HTTP.Stream.stop(pid, :timeout)
        {:error, :timeout, acc}
    end
  end

  defp continue({:cont, acc}, pid, monitor, deadline, fun),
    do: loop(pid, monitor, deadline, acc, fun)

  defp continue({:halt, acc}, pid, _monitor, _deadline, _fun) do
    HTTP.Stream.stop(pid, :cancelled)
    {:halt, acc}
  end

  defp remaining(:infinity), do: :infinity
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
end

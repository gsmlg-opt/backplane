defmodule Backplane.Audio.Downstream do
  @moduledoc "Bounded disconnect observation and delivery for the pinned Bandit audio transports."
  alias Backplane.Audio.Error
  alias ThousandIsland.Socket

  @pipeline_limit 65_536

  def start(
        %{
          adapter:
            {Bandit.Adapter, %{transport: %Bandit.HTTP1.Socket{read_state: :read} = transport}}
        },
        deadline
      ) do
    socket = transport.socket

    with true <- IO.iodata_length(transport.buffer) <= @pipeline_limit,
         {:ok, previous} <- Socket.getopts(socket, [:send_timeout, :send_timeout_close]),
         :ok <-
           Socket.setopts(socket,
             active: :once,
             send_timeout: max(deadline - System.monotonic_time(:millisecond), 1),
             send_timeout_close: true
           ) do
      {:ok, %{socket: socket, raw: socket.socket, previous: previous}}
    else
      _ -> {:error, cancelled()}
    end
  end

  # HTTP/2 streams have their own process ownership; never change connection options.
  def start(%{adapter: {Bandit.Adapter, %{transport: %Bandit.HTTP2.Stream{}}}}, _deadline),
    do: {:ok, %{kind: :http2, raw: nil, owner: self()}}

  def start(_, _), do: {:ok, nil}

  def append(conn, bytes) do
    {module, adapter} = conn.adapter
    buffer = IO.iodata_to_binary(adapter.transport.buffer)

    if byte_size(buffer) + byte_size(bytes) <= @pipeline_limit do
      transport = %{adapter.transport | buffer: buffer <> bytes}
      {:ok, %{conn | adapter: {module, %{adapter | transport: transport}}}}
    else
      {:error,
       Error.new(413, "Audio pipelined input exceeded limit", nil, "audio_pipeline_too_large")}
    end
  end

  def rearm(%{socket: socket}), do: Socket.setopts(socket, active: :once)

  def deliver(nil, _deadline, fun), do: fun.()

  def deliver(%{kind: :http2, owner: owner}, deadline, fun) do
    guard =
      spawn(fn ->
        ref = Process.monitor(owner)

        receive do
          :done -> :ok
          {:DOWN, ^ref, :process, ^owner, _} -> :ok
        after
          max(deadline - System.monotonic_time(:millisecond), 0) -> Process.exit(owner, :kill)
        end
      end)

    try do
      fun.()
    after
      send(guard, :done)
    end
  end

  def deliver(state, deadline, fun) do
    owner = self()
    remaining = max(deadline - System.monotonic_time(:millisecond), 1)
    Socket.setopts(state.socket, send_timeout: remaining, send_timeout_close: true)

    guard =
      spawn(fn ->
        ref = Process.monitor(owner)

        receive do
          :done -> :ok
          {:DOWN, ^ref, :process, ^owner, _} -> :ok
        after
          remaining -> Socket.close(state.socket)
        end
      end)

    try do
      fun.()
    after
      send(guard, :done)
    end
  end

  def restore(conn, nil), do: {:ok, conn}
  def restore(conn, %{kind: :http2}), do: {:ok, conn}

  def restore(conn, state) do
    stop(state)
    drain(conn, state.raw)
  end

  def stop(nil), do: :ok
  def stop(%{kind: :http2}), do: :ok

  def stop(state) do
    Socket.setopts(state.socket, [active: false] ++ state.previous)
    :ok
  end

  defp drain(conn, raw) do
    receive do
      {tag, ^raw, bytes} when tag in [:tcp, :ssl] ->
        with {:ok, conn} <- append(conn, bytes), do: drain(conn, raw)

      {tag, ^raw} when tag in [:tcp_closed, :ssl_closed] ->
        {:error, cancelled()}

      {tag, ^raw, _} when tag in [:tcp_error, :ssl_error] ->
        {:error, cancelled()}
    after
      0 -> {:ok, conn}
    end
  end

  def cancelled, do: Error.new(499, "Client disconnected", nil, "audio_cancelled")
end

defmodule Backplane.Audio.Downstream do
  @moduledoc "Bounded disconnect observation and delivery through Gaoxy's public Plug API."
  alias Backplane.Audio.Error

  def start(%{adapter: {Gaoxy.PlugAdapter, _}}, deadline) do
    if deadline > System.monotonic_time(:millisecond),
      do: {:ok, %{kind: :gaoxy, owner: self(), deadline: deadline}},
      else: {:error, timeout_error()}
  end

  def start(_, _), do: {:ok, nil}

  def poll(conn, nil), do: {:ok, conn}

  def poll(conn, %{kind: :gaoxy, deadline: deadline} = downstream) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error, timeout_error(), conn}
    else
      case Gaoxy.HTTP.poll_connection(conn, 0) do
        {:pending, next_conn} ->
          {:ok, next_conn}

        {:more, next_conn} ->
          poll(next_conn, downstream)

        {:error, :buffer_limit, next_conn} ->
          {:error,
           Error.new(
             413,
             "Audio pipelined input exceeded limit",
             nil,
             "audio_pipeline_too_large"
           ), next_conn}

        {:error, _reason, next_conn} ->
          {:error, cancelled(), next_conn}
      end
    end
  end

  def deliver(nil, _deadline, fun), do: fun.()

  def deliver(%{kind: :gaoxy, owner: owner}, deadline, fun) do
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

  def restore(conn, downstream) do
    case poll(conn, downstream) do
      {:ok, conn} -> {:ok, conn}
      {:error, %Error{code: "audio_timeout"}, next_conn} -> {:ok, next_conn}
      {:error, error, _conn} -> {:error, error}
    end
  end

  def abort(%{adapter: {Gaoxy.PlugAdapter, _}} = conn), do: Gaoxy.HTTP.abort(conn)
  def abort(_conn), do: :ok

  def stop(_downstream), do: :ok

  def cancelled, do: Error.new(499, "Client disconnected", nil, "audio_cancelled")

  defp timeout_error,
    do: Error.new(504, "Audio request timed out", nil, "audio_timeout", "api_error")
end

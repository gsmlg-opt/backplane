defmodule Backplane.SkillProtocol.LifecycleHTTPServer do
  @moduledoc false

  def start(owner, mode) do
    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        active: false,
        ip: {127, 0, 0, 1},
        packet: :raw,
        reuseaddr: true
      ])

    {:ok, {_address, port}} = :inet.sockname(listener)
    pid = spawn(fn -> serve(listener, owner, mode) end)
    %{pid: pid, monitor: Process.monitor(pid), url: "http://127.0.0.1:#{port}"}
  end

  defp serve(listener, owner, mode) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        :gen_tcp.close(listener)
        {:ok, _request} = receive_headers(socket, "")
        send(owner, {:http_request_started, self()})
        respond(socket, owner, mode)

      {:error, reason} ->
        send(owner, {:http_server_error, reason})
    end
  end

  defp receive_headers(socket, bytes) do
    if String.contains?(bytes, "\r\n\r\n") do
      {:ok, bytes}
    else
      case :gen_tcp.recv(socket, 0) do
        {:ok, chunk} -> receive_headers(socket, bytes <> chunk)
        error -> error
      end
    end
  end

  defp respond(socket, owner, :stall), do: observe_close(socket, owner)

  defp respond(socket, owner, {:chunks, interval_ms}) do
    :ok =
      :gen_tcp.send(
        socket,
        "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ntransfer-encoding: chunked\r\nconnection: close\r\n\r\n"
      )

    send_chunks(socket, owner, interval_ms, 0)
  end

  defp send_chunks(socket, owner, interval_ms, count) do
    Process.sleep(interval_ms)

    case :gen_tcp.send(socket, "1\r\nx\r\n") do
      :ok ->
        send(owner, {:http_chunk_sent, count + 1})
        send_chunks(socket, owner, interval_ms, count + 1)

      {:error, reason} ->
        send(owner, {:http_request_closed, self(), reason})
    end
  end

  defp observe_close(socket, owner) do
    reason =
      case :gen_tcp.recv(socket, 0) do
        {:error, reason} -> reason
        {:ok, _bytes} -> :unexpected_request_bytes
      end

    send(owner, {:http_request_closed, self(), reason})
  end
end

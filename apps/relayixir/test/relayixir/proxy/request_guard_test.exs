defmodule Relayixir.Proxy.RequestGuardTest do
  use ExUnit.Case

  alias Relayixir.Proxy.{HttpClient, Upstream}

  test "abnormal guard shutdown cancels an active request while its caller remains alive" do
    owner = self()

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true])

    {:ok, {_address, port}} = :inet.sockname(listener)

    peer =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)

        try do
          request = read_head(socket, "")
          send(owner, {:request_started, request})
          send(owner, {:after_guard_shutdown, :gen_tcp.recv(socket, 0, 2_000)})
          :ok
        after
          :gen_tcp.close(socket)
        end
      end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      if Process.alive?(peer.pid), do: Process.exit(peer.pid, :kill)
    end)

    upstream = %Upstream{
      scheme: :http,
      host: "127.0.0.1",
      port: port,
      pool_size: 2,
      request_timeout: 5_000
    }

    {:ok, handle} = HttpClient.connect(upstream)
    {:ok, handle, _ref} = HttpClient.send_request(handle, "GET", "/waiting", [], "")
    assert_receive {:request_started, "GET /waiting HTTP/1.1\r\n" <> _headers}, 2_000

    guard_monitor = Process.monitor(handle.guard)
    assert :ok = GenServer.stop(handle.guard, :shutdown)
    assert_receive {:DOWN, ^guard_monitor, :process, _, :shutdown}
    assert Process.alive?(owner)
    assert_receive {:after_guard_shutdown, {:error, :closed}}, 3_000
    assert :ok = Task.await(peer, 2_000)
    assert {:ok, _handle} = HttpClient.close(handle)
  end

  test "preconnect failure terminates its upload while the caller remains alive" do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true])

    {:ok, {_address, port}} = :inet.sockname(listener)
    # Force a preconnect failure, so an upload reader can never register.
    :ok = :gen_tcp.close(listener)
    observer = self()

    {caller, caller_monitor} =
      spawn_monitor(fn ->
        upstream = %Upstream{
          scheme: :http,
          host: "127.0.0.1",
          port: port,
          connect_timeout: 200,
          request_timeout: 200,
          pool_size: 2
        }

        {:ok, handle} = HttpClient.connect(upstream)
        {:ok, handle, _ref} = HttpClient.send_request(handle, "POST", "/upload", [], :stream)
        upload_monitor = Process.monitor(handle.upload)

        assert {:error, %HTTP.RequestError{reason: :econnrefused}} =
                 HTTP.Promise.await(handle.promise, 1_000)

        assert_receive {:DOWN, ^upload_monitor, :process, _, :normal}, 1_000
        send(observer, {:upload_handle, handle})

        receive do
          :exit_normally -> :ok
        after
          2_000 -> flunk("caller exit was not released")
        end
      end)

    on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)
    assert_receive {:upload_handle, handle}, 1_000
    assert Process.alive?(caller)
    refute Process.alive?(handle.upload)
    refute HTTP.AbortController.aborted?(handle.controller)
    send(caller, :exit_normally)
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}, 1_000
    assert Process.alive?(handle.guard)
    assert Process.alive?(handle.controller)
    assert_aborted(handle.controller)
  end

  defp assert_aborted(controller, attempts \\ 100)
  defp assert_aborted(controller, 0), do: assert(HTTP.AbortController.aborted?(controller))

  defp assert_aborted(controller, attempts) do
    if HTTP.AbortController.aborted?(controller) do
      :ok
    else
      receive do
      after
        1 -> assert_aborted(controller, attempts - 1)
      end
    end
  end

  defp read_head(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      acc
    else
      {:ok, bytes} = :gen_tcp.recv(socket, 0, 2_000)
      read_head(socket, acc <> bytes)
    end
  end
end

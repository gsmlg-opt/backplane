defmodule Relayixir.Proxy.ConnPoolTest do
  use ExUnit.Case, async: true

  alias Relayixir.Proxy.{HttpPlug, Upstream}

  test "retains a consumed connection across independent request processes" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)

    peer =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 2_000)

        for path <- ["/one", "/two"] do
          headers = receive_headers(socket, "")
          assert String.starts_with?(headers, "GET #{path} HTTP/1.1\r\n")
          :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK")
        end

        :gen_tcp.close(socket)
      end)

    upstream = %Upstream{scheme: :http, host: "127.0.0.1", port: port, pool_size: 2}

    for path <- ["/one", "/two"] do
      result =
        Task.async(fn -> HttpPlug.call(Plug.Test.conn(:get, path), upstream, body: "") end)
        |> Task.await()

      assert result.status == 200
      assert result.resp_body == "OK"
    end

    Task.await(peer)
  end

  test "opens fresh connections when pooling is disabled" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)

    peer =
      Task.async(fn ->
        for path <- ["/one", "/two"] do
          {:ok, socket} = :gen_tcp.accept(listener, 2_000)
          headers = receive_headers(socket, "")
          assert String.starts_with?(headers, "GET #{path} HTTP/1.1\r\n")
          :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK")
          assert {:error, :closed} = :gen_tcp.recv(socket, 0, 2_000)
          :gen_tcp.close(socket)
        end
      end)

    upstream = %Upstream{scheme: :http, host: "127.0.0.1", port: port}

    for path <- ["/one", "/two"] do
      result = HttpPlug.call(Plug.Test.conn(:get, path), upstream, body: "")
      assert result.resp_body == "OK"
    end

    Task.await(peer)
  end

  defp receive_headers(socket, pending) do
    if String.contains?(pending, "\r\n\r\n") do
      pending
    else
      {:ok, data} = :gen_tcp.recv(socket, 0, 2_000)
      receive_headers(socket, pending <> data)
    end
  end
end

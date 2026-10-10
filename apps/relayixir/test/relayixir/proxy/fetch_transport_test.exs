defmodule Relayixir.Proxy.FetchTransportTest do
  use ExUnit.Case, async: true

  alias Relayixir.Proxy.{HttpPlug, Upstream}

  defmodule HeaderMapper do
    def init(status, headers, owner) do
      send(owner, {:mapper_headers, status, headers})
      {:ok, owner}
    end

    def feed(owner, chunk) do
      send(owner, {:mapper_chunk, chunk})
      {:ok, owner, [chunk]}
    end

    def finish(owner, reason) do
      send(owner, {:mapper_finished, reason})
      {:ok, owner, []}
    end
  end

  defmodule RejectingHeaderMapper do
    def init(_status, _headers, _owner), do: {:error, :rejected_headers}
  end

  defmodule ClosedChunkAdapter do
    @behaviour Plug.Conn.Adapter

    defdelegate send_resp(state, status, headers, body), to: Plug.Adapters.Test.Conn

    defdelegate send_file(state, status, headers, path, offset, length),
      to: Plug.Adapters.Test.Conn

    defdelegate send_chunked(state, status, headers), to: Plug.Adapters.Test.Conn
    defdelegate read_req_body(state, opts), to: Plug.Adapters.Test.Conn
    defdelegate inform(state, status, headers), to: Plug.Adapters.Test.Conn
    defdelegate upgrade(state, protocol, opts), to: Plug.Adapters.Test.Conn
    defdelegate push(state, path, headers), to: Plug.Adapters.Test.Conn
    defdelegate get_peer_data(state), to: Plug.Adapters.Test.Conn
    defdelegate get_sock_data(state), to: Plug.Adapters.Test.Conn
    defdelegate get_ssl_data(state), to: Plug.Adapters.Test.Conn
    defdelegate get_http_protocol(state), to: Plug.Adapters.Test.Conn

    def chunk(_state, _body), do: {:error, :closed}
  end

  defmodule GatedUploadAdapter do
    @behaviour Plug.Conn.Adapter

    defdelegate send_resp(state, status, headers, body), to: Plug.Adapters.Test.Conn

    defdelegate send_file(state, status, headers, path, offset, length),
      to: Plug.Adapters.Test.Conn

    defdelegate send_chunked(state, status, headers), to: Plug.Adapters.Test.Conn
    defdelegate chunk(state, body), to: Plug.Adapters.Test.Conn
    defdelegate inform(state, status, headers), to: Plug.Adapters.Test.Conn
    defdelegate upgrade(state, protocol, opts), to: Plug.Adapters.Test.Conn
    defdelegate push(state, path, headers), to: Plug.Adapters.Test.Conn
    defdelegate get_peer_data(state), to: Plug.Adapters.Test.Conn
    defdelegate get_sock_data(state), to: Plug.Adapters.Test.Conn
    defdelegate get_ssl_data(state), to: Plug.Adapters.Test.Conn
    defdelegate get_http_protocol(state), to: Plug.Adapters.Test.Conn

    def read_req_body(%{req_body: "firstlast"} = state, _opts) do
      {:more, "first", %{state | req_body: "last"}}
    end

    def read_req_body(%{req_body: "last"} = state, _opts) do
      receive do
        :continue_upload -> {:ok, "last", %{state | req_body: ""}}
      after
        5_000 -> {:error, :timeout}
      end
    end
  end

  test "preserves gzip entity bytes and encoding headers in a fixed-length response" do
    compressed = :zlib.gzip("data: compressed upstream response\n\n")

    {port, _server} =
      start_origin(fn socket ->
        read_request(socket)

        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\n",
            "Content-Length: #{byte_size(compressed)}\r\n\r\n",
            compressed
          ])
      end)

    result = HttpPlug.call(Plug.Test.conn(:get, "/gzip"), upstream(port), body: "")

    assert result.status == 200
    assert result.resp_body == compressed
    assert Plug.Conn.get_resp_header(result, "content-encoding") == ["gzip"]

    assert Plug.Conn.get_resp_header(result, "content-length") == [
             Integer.to_string(byte_size(compressed))
           ]
  end

  test "preserves gzip bytes in a chunked response" do
    compressed = :zlib.gzip("streamed compressed response")

    {port, _server} =
      start_origin(fn socket ->
        read_request(socket)

        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nTransfer-Encoding: chunked\r\n\r\n",
            Integer.to_string(byte_size(compressed), 16),
            "\r\n",
            compressed,
            "\r\n0\r\n\r\n"
          ])
      end)

    result = HttpPlug.call(Plug.Test.conn(:get, "/gzip"), upstream(port), body: "")

    assert result.status == 200
    assert result.resp_body == compressed
    assert Plug.Conn.get_resp_header(result, "content-encoding") == ["gzip"]
  end

  test "forwards redirect status, location, and body without following it" do
    {port, _server} =
      start_origin(fn socket ->
        read_request(socket)

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 307 Temporary Redirect\r\nLocation: http://127.0.0.1:1/target\r\n" <>
              "Content-Length: 8\r\n\r\nredirect"
          )
      end)

    result = HttpPlug.call(Plug.Test.conn(:post, "/redirect"), upstream(port), body: "entity")

    assert result.status == 307
    assert result.resp_body == "redirect"
    assert Plug.Conn.get_resp_header(result, "location") == ["http://127.0.0.1:1/target"]
  end

  test "initializes a fixed-length stream mapper before the upstream sends its body" do
    owner = self()

    {port, server} =
      start_origin(fn socket ->
        read_request(socket)
        :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\n")

        receive do
          :send_body -> :ok
        after
          5_000 -> flunk("mapper did not observe response headers before the body")
        end

        :ok = :gen_tcp.send(socket, "first")

        receive do
          :finish_body -> :ok
        after
          5_000 -> flunk("mapper buffered the fixed-length body")
        end

        :ok = :gen_tcp.send(socket, "last!")
      end)

    task =
      Task.async(fn ->
        HttpPlug.call(Plug.Test.conn(:get, "/delayed"), upstream(port),
          body: "",
          response_stream_mapper: {HeaderMapper, owner}
        )
      end)

    assert_receive {:mapper_headers, 200, headers}, 2_000
    assert {"content-length", "10"} in headers
    send(server, :send_body)
    assert_receive {:mapper_chunk, "first"}, 2_000
    send(server, :finish_body)

    result = Task.await(task, 5_000)
    assert result.resp_body == "firstlast!"
    assert Plug.Conn.get_resp_header(result, "content-length") == []
    assert_received {:mapper_finished, :eof}
  end

  test "downstream disconnect closes an unfinished upstream response" do
    owner = self()

    {port, _server} =
      start_origin(fn socket ->
        read_request(socket)

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nfirst\r\n"
          )

        send(owner, {:upstream_after_disconnect, :gen_tcp.recv(socket, 0, 2_000)})
      end)

    conn = Plug.Test.conn(:get, "/unfinished")
    {_adapter, adapter_state} = conn.adapter
    conn = %{conn | adapter: {ClosedChunkAdapter, adapter_state}}

    result = HttpPlug.call(conn, upstream(port), body: "")

    assert result.private[:relayixir_downstream_disconnected] == true
    assert_receive {:upstream_after_disconnect, {:error, :closed}}, 3_000
  end

  test "first-byte timeout cancels the upstream connection" do
    owner = self()

    {port, _server} =
      start_origin(fn socket ->
        read_request(socket)
        send(owner, {:upstream_after_timeout, :gen_tcp.recv(socket, 0, 2_000)})
      end)

    result =
      HttpPlug.call(
        Plug.Test.conn(:get, "/silent"),
        %{upstream(port) | first_byte_timeout: 100, request_timeout: 1_000},
        body: ""
      )

    assert result.status == 504
    assert result.private[:relayixir_proxy_error] == :upstream_timeout
    assert_receive {:upstream_after_timeout, {:error, :closed}}, 3_000
  end

  test "response size rejection closes an unfinished fixed-length body" do
    owner = self()

    {port, _server} =
      start_origin(fn socket ->
        read_request(socket)

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\nContent-Length: 1000\r\n\r\nbody exceeds the limit"
          )

        send(owner, {:upstream_after_size_limit, :gen_tcp.recv(socket, 0, 2_000)})
      end)

    result =
      HttpPlug.call(
        Plug.Test.conn(:get, "/oversized"),
        %{upstream(port) | max_response_body_size: 10},
        body: ""
      )

    assert result.status == 502
    assert result.private[:relayixir_proxy_error] == :response_too_large
    assert_receive {:upstream_after_size_limit, {:error, :closed}}, 3_000
  end

  test "caller death closes a pooled request still waiting for response headers" do
    owner = self()

    {port, _server} =
      start_origin(fn socket ->
        read_request(socket)
        send(owner, :pooled_request_received)
        send(owner, {:upstream_after_caller_death, :gen_tcp.recv(socket, 0, 2_000)})
      end)

    {caller, monitor} =
      spawn_monitor(fn ->
        HttpPlug.call(
          Plug.Test.conn(:get, "/waiting"),
          %{upstream(port) | pool_size: 2, first_byte_timeout: 5_000},
          body: ""
        )
      end)

    on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)

    assert_receive :pooled_request_received, 2_000
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^caller, :killed}
    assert_receive {:upstream_after_caller_death, {:error, :closed}}, 3_000
  end

  test "mapper initialization rejection cancels a pooled fixed-length body before consumption" do
    owner = self()

    {port, _server} =
      start_origin(fn socket ->
        read_request(socket)
        :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\nContent-Length: 1000\r\n\r\n")
        send(owner, {:upstream_after_header_rejection, :gen_tcp.recv(socket, 0, 2_000)})
      end)

    result =
      HttpPlug.call(Plug.Test.conn(:get, "/rejected"), %{upstream(port) | pool_size: 2},
        body: "",
        response_stream_mapper: {RejectingHeaderMapper, nil}
      )

    assert result.status == 502
    assert result.private[:relayixir_proxy_error] == {:response_stream_mapper, :rejected_headers}
    assert_receive {:upstream_after_header_rejection, {:error, :closed}}, 3_000
  end

  test "reuses the same upstream socket for fully consumed pooled responses" do
    owner = self()

    {port, _server} =
      start_origin(fn socket ->
        {first_headers, ""} = read_request(socket)
        send(owner, {:first_request, first_headers})
        :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\none")

        {second_headers, ""} = read_request(socket)
        send(owner, {:second_request_same_socket, second_headers})
        :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\ntwo")
      end)

    upstream = %{upstream(port) | pool_size: 2}
    first = HttpPlug.call(Plug.Test.conn(:get, "/one"), upstream, body: "")
    assert first.resp_body == "one"

    second = HttpPlug.call(Plug.Test.conn(:get, "/two"), upstream, body: "")
    assert second.resp_body == "two"
    assert_received {:first_request, "GET /one HTTP/1.1" <> _}
    assert_received {:second_request_same_socket, "GET /two HTTP/1.1" <> _}
  end

  test "preserves request entities for GET and DELETE" do
    for method <- [:get, :delete] do
      owner = self()

      {port, _server} =
        start_origin(fn socket ->
          {_headers, body} = read_request(socket)
          send(owner, {:request_entity, method, body})
          :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK")
        end)

      result = HttpPlug.call(Plug.Test.conn(method, "/entity"), upstream(port), body: "entity")

      assert result.status == 200
      assert_receive {:request_entity, ^method, "entity"}
    end
  end

  test "forwards the first upload chunk before reading the rest of the request" do
    owner = self()

    {port, _server} =
      start_origin(fn socket ->
        {headers, pending} = read_until(socket, "", "\r\n\r\n")
        assert headers =~ ~r/\r\ntransfer-encoding:\s*chunked/i
        {"5", pending} = read_until(socket, pending, "\r\n")
        {"first\r\n", pending} = read_bytes(socket, pending, 7)
        send(owner, :upstream_first_upload_chunk)
        assert read_chunked_body(socket, pending, []) == "last"

        :ok =
          :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\nfirstlast")
      end)

    task =
      Task.async(fn ->
        conn = Plug.Test.conn(:post, "/upload", "firstlast")
        {_adapter, adapter_state} = conn.adapter
        conn = %{conn | adapter: {GatedUploadAdapter, adapter_state}}
        HttpPlug.call(conn, upstream(port))
      end)

    assert_receive :upstream_first_upload_chunk, 2_000
    send(task.pid, :continue_upload)
    assert Task.await(task, 5_000).resp_body == "firstlast"
  end

  defp upstream(port) do
    %Upstream{
      scheme: :http,
      host: "127.0.0.1",
      port: port,
      host_forward_mode: :rewrite_to_upstream,
      request_timeout: 5_000,
      first_byte_timeout: 3_000
    }
  end

  defp start_origin(handler) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(listener)

    server =
      start_supervised!(%{
        id: make_ref(),
        start:
          {Task, :start_link,
           [
             fn ->
               {:ok, socket} = :gen_tcp.accept(listener, 5_000)

               try do
                 handler.(socket)
               after
                 :gen_tcp.close(socket)
               end
             end
           ]},
        restart: :temporary
      })

    on_exit(fn -> :gen_tcp.close(listener) end)
    {port, server}
  end

  defp read_request(socket) do
    {headers, pending} = read_until(socket, "", "\r\n\r\n")

    case Regex.run(~r/\r\ncontent-length:\s*(\d+)/i, headers) do
      [_, length] ->
        {body, _rest} = read_bytes(socket, pending, String.to_integer(length))
        {headers, body}

      nil ->
        if Regex.match?(~r/\r\ntransfer-encoding:\s*chunked/i, headers) do
          {headers, read_chunked_body(socket, pending, [])}
        else
          {headers, ""}
        end
    end
  end

  defp read_chunked_body(socket, pending, chunks) do
    {size_line, pending} = read_until(socket, pending, "\r\n")
    size = String.to_integer(size_line, 16)

    if size == 0 do
      {_terminator, _pending} = read_bytes(socket, pending, 2)
      chunks |> Enum.reverse() |> IO.iodata_to_binary()
    else
      {chunk, pending} = read_bytes(socket, pending, size)
      {"\r\n", pending} = read_bytes(socket, pending, 2)
      read_chunked_body(socket, pending, [chunk | chunks])
    end
  end

  defp read_until(socket, pending, separator) do
    case :binary.split(pending, separator) do
      [head, rest] -> {head, rest}
      [_] -> read_until(socket, pending <> recv(socket), separator)
    end
  end

  defp read_bytes(socket, pending, size) when byte_size(pending) < size do
    read_bytes(socket, pending <> recv(socket), size)
  end

  defp read_bytes(_socket, pending, size) do
    <<body::binary-size(size), rest::binary>> = pending
    {body, rest}
  end

  defp recv(socket) do
    {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
    data
  end
end

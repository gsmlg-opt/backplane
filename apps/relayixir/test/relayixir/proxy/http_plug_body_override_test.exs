defmodule Relayixir.Proxy.HttpPlugBodyOverrideTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn, only: [put_req_header: 3]

  alias Relayixir.Proxy.{HttpPlug, Upstream}

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

  defmodule StatefulMapper do
    def init(status, headers, owner) do
      send(owner, {:mapper_init, status, headers})
      {:ok, owner}
    end

    def feed(owner, chunk) do
      send(owner, {:mapper_feed, chunk})
      {:ok, owner, [String.upcase(chunk)]}
    end

    def finish(owner, reason) do
      send(owner, {:mapper_finish, reason})
      {:ok, owner, ["<done>"]}
    end
  end

  defmodule FailingFinishMapper do
    def init(_status, _headers, _arg), do: {:ok, nil}
    def feed(state, chunk), do: {:ok, state, [chunk]}
    def finish(state, :eof), do: {:error, :truncated, state, ["<stream-error>"]}
    def finish(state, _reason), do: {:ok, state, []}
  end

  defmodule InitFailureMapper do
    def init(_status, _headers, _arg), do: {:error, :cannot_initialize}
  end

  defmodule CloseFinalChunkAdapter do
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

    def chunk(_state, "<done>"), do: {:error, :closed}
    defdelegate chunk(state, body), to: Plug.Adapters.Test.Conn
  end

  setup do
    {:ok, server_pid} = Bandit.start_link(plug: Relayixir.TestUpstream, port: 0)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server_pid)

    on_exit(fn ->
      try do
        ThousandIsland.stop(server_pid)
      catch
        :exit, _ -> :ok
      end
    end)

    %{port: port}
  end

  defp build_upstream(port) do
    %Upstream{
      scheme: :http,
      host: "127.0.0.1",
      port: port,
      host_forward_mode: :rewrite_to_upstream
    }
  end

  describe "body: opt" do
    test "sends provided body to upstream instead of reading from conn", %{port: port} do
      upstream = build_upstream(port)
      override_body = "override body"

      conn =
        conn(:post, "/echo", "original body")
        |> put_req_header("content-type", "text/plain")

      result = HttpPlug.call(conn, upstream, body: override_body)
      assert result.status == 200
      assert result.resp_body == "override body"
    end

    test "without body opt, reads body from conn as before (backward compat)", %{port: port} do
      upstream = build_upstream(port)

      conn =
        conn(:post, "/echo", "from conn")
        |> put_req_header("content-type", "text/plain")

      result = HttpPlug.call(conn, upstream)
      assert result.status == 200
      assert result.resp_body == "from conn"
    end
  end

  describe "on_response_chunk: opt" do
    test "callback invoked for each chunk in streaming response", %{port: port} do
      upstream = build_upstream(port)
      chunks_agent = start_supervised!({Agent, fn -> [] end})

      callback = fn chunk ->
        Agent.update(chunks_agent, &[chunk | &1])
      end

      conn = conn(:get, "/chunked")

      result = HttpPlug.call(conn, upstream, on_response_chunk: callback)
      assert result.status == 200

      collected = Agent.get(chunks_agent, &Enum.reverse/1)
      assert length(collected) > 0
      assert Enum.join(collected) =~ "chunk1"
    end

    test "callback NOT invoked for content-length responses", %{port: port} do
      upstream = build_upstream(port)
      chunks_agent = start_supervised!({Agent, fn -> [] end})

      callback = fn chunk ->
        Agent.update(chunks_agent, &[chunk | &1])
      end

      conn = conn(:get, "/with-content-length")
      result = HttpPlug.call(conn, upstream, on_response_chunk: callback)
      assert result.status == 200

      collected = Agent.get(chunks_agent, & &1)
      assert collected == []
    end

    test "without callback, streaming works as before (backward compat)", %{port: port} do
      upstream = build_upstream(port)
      conn = conn(:get, "/chunked")
      result = HttpPlug.call(conn, upstream)
      assert result.status == 200
    end

    test "observer exceptions do not truncate a native stream", %{port: port} do
      upstream = build_upstream(port)
      conn = conn(:get, "/chunked")

      result =
        HttpPlug.call(conn, upstream, on_response_chunk: fn _chunk -> raise "observer failed" end)

      assert result.status == 200
      assert result.resp_body == "chunk1chunk2"
    end

    test "marks and reports downstream disconnects while closing the upstream stream", %{
      port: port
    } do
      parent = self()
      handler_id = "relayixir-downstream-disconnect-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:relayixir, :http, :downstream, :disconnect],
        fn _event, _measurements, _metadata, _config ->
          send(parent, :downstream_disconnected)
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      upstream = build_upstream(port)
      conn = conn(:get, "/delayed-chunked")
      {_adapter, adapter_state} = conn.adapter
      conn = %{conn | adapter: {ClosedChunkAdapter, adapter_state}}

      result = HttpPlug.call(conn, upstream)

      assert result.private[:relayixir_downstream_disconnected] == true
      assert_receive :downstream_disconnected, 1_000
    end
  end

  describe "map_response_body: opt" do
    test "maps content-length response bodies without forwarding stale content-length", %{
      port: port
    } do
      upstream = build_upstream(port)
      conn = conn(:get, "/with-content-length")

      result = HttpPlug.call(conn, upstream, map_response_body: fn _body -> "mapped" end)

      assert result.status == 200
      assert result.resp_body == "mapped"
      assert Plug.Conn.get_resp_header(result, "content-length") == []
    end

    test "collects and maps chunked response bodies", %{port: port} do
      upstream = build_upstream(port)
      conn = conn(:get, "/chunked")

      result =
        HttpPlug.call(conn, upstream, map_response_body: fn body -> "mapped: #{body}" end)

      assert result.status == 200
      assert result.resp_body == "mapped: chunk1chunk2"
    end

    test "passes status and headers to a status-aware body mapper", %{port: port} do
      upstream = build_upstream(port)
      conn = conn(:get, "/with-content-length")

      result =
        HttpPlug.call(conn, upstream,
          map_response_body: fn status, headers, body ->
            "#{status}:#{length(headers)}:#{body}"
          end
        )

      assert result.resp_body =~ "200:"
      assert result.resp_body =~ ":Hello, World!"
    end

    test "a status-aware mapper can replace status and mark translation failure", %{port: port} do
      result =
        HttpPlug.call(conn(:get, "/with-content-length"), build_upstream(port),
          map_response_body: fn _status, headers, _body ->
            {:error, :invalid_translation, 502, headers, "mapped error"}
          end
        )

      assert result.status == 502
      assert result.resp_body == "mapped error"
      assert result.private[:relayixir_proxy_error] == :invalid_translation
    end
  end

  describe "response_stream_mapper: opt" do
    test "streams content-length responses through stateful feed and EOF without buffering", %{
      port: port
    } do
      upstream = build_upstream(port)
      conn = conn(:get, "/with-content-length")

      result =
        HttpPlug.call(conn, upstream, response_stream_mapper: {StatefulMapper, self()})

      assert result.status == 200
      assert result.resp_body == "HELLO, WORLD!<done>"
      assert Plug.Conn.get_resp_header(result, "content-length") == []
      assert_received {:mapper_init, 200, _headers}
      assert_received {:mapper_feed, "Hello, World!"}
      assert_received {:mapper_finish, :eof}
    end

    test "keeps mapper state across chunked response frames", %{port: port} do
      upstream = build_upstream(port)
      conn = conn(:get, "/chunked")

      result =
        HttpPlug.call(conn, upstream, response_stream_mapper: {StatefulMapper, self()})

      assert result.resp_body == "CHUNK1CHUNK2<done>"
      assert_received {:mapper_feed, "chunk1"}
      assert_received {:mapper_feed, "chunk2"}
      assert_received {:mapper_finish, :eof}
    end

    test "emits mapper EOF errors and marks the proxy result as failed", %{port: port} do
      upstream = build_upstream(port)

      result =
        HttpPlug.call(conn(:get, "/chunked"), upstream,
          response_stream_mapper: {FailingFinishMapper, nil}
        )

      assert result.resp_body == "chunk1chunk2<stream-error>"

      assert result.private[:relayixir_proxy_error] ==
               {:response_stream_mapper, :truncated}
    end

    test "marks a disconnect while sending final mapper chunks", %{port: port} do
      conn = conn(:get, "/chunked")
      {_adapter, adapter_state} = conn.adapter
      conn = %{conn | adapter: {CloseFinalChunkAdapter, adapter_state}}

      result =
        HttpPlug.call(conn, build_upstream(port),
          response_stream_mapper: {StatefulMapper, self()}
        )

      assert result.private[:relayixir_downstream_disconnected] == true
      refute result.private[:relayixir_proxy_error]
      assert_received {:mapper_finish, :eof}
    end

    test "reports mapper initialization failure before sending a response", %{port: port} do
      result =
        HttpPlug.call(conn(:get, "/chunked"), build_upstream(port),
          response_stream_mapper: {InitFailureMapper, nil}
        )

      assert result.status == 502

      assert result.private[:relayixir_proxy_error] ==
               {:response_stream_mapper, :cannot_initialize}
    end
  end

  describe "on_response_body: opt" do
    test "observes a collected response without changing native bytes", %{port: port} do
      upstream = build_upstream(port)
      parent = self()
      conn = conn(:get, "/with-content-length")

      result = HttpPlug.call(conn, upstream, on_response_body: &send(parent, {:body, &1}))

      assert result.status == 200
      assert result.resp_body == "Hello, World!"
      assert_receive {:body, "Hello, World!"}
    end

    test "observer exceptions do not fail a collected native response", %{port: port} do
      upstream = build_upstream(port)
      conn = conn(:get, "/with-content-length")

      result =
        HttpPlug.call(conn, upstream, on_response_body: fn _body -> raise "observer failed" end)

      assert result.status == 200
      assert result.resp_body == "Hello, World!"
    end
  end

  describe "combined opts" do
    test "body: + on_response_chunk: work together", %{port: port} do
      upstream = build_upstream(port)
      chunks_agent = start_supervised!({Agent, fn -> [] end})

      callback = fn chunk -> Agent.update(chunks_agent, &[chunk | &1]) end
      override_body = "combined body"

      conn =
        conn(:post, "/echo", "ignored")
        |> put_req_header("content-type", "text/plain")

      result = HttpPlug.call(conn, upstream, body: override_body, on_response_chunk: callback)
      assert result.status == 200
      # /echo returns content-length, so callback should NOT be invoked
      collected = Agent.get(chunks_agent, & &1)
      assert collected == []
      # But the override body should have been sent
      assert result.resp_body == "combined body"
    end
  end
end

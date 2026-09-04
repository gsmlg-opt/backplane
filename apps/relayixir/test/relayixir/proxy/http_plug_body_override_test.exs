defmodule Relayixir.Proxy.HttpPlugBodyOverrideTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn, only: [put_req_header: 3]

  alias Relayixir.Proxy.{HttpPlug, Upstream}

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
      conn = %{conn | adapter: {Relayixir.ClosedChunkAdapter, adapter_state}}

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

defmodule Relayixir.ClosedChunkAdapter do
  @behaviour Plug.Conn.Adapter

  defdelegate send_resp(state, status, headers, body), to: Plug.Adapters.Test.Conn
  defdelegate send_file(state, status, headers, path, offset, length), to: Plug.Adapters.Test.Conn
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

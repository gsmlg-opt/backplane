defmodule Backplane.McpProtocol.Transport.SecurityTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Backplane.McpProtocol.Protocol.Registry
  alias Backplane.McpProtocol.Test.HTTPServer
  alias Backplane.McpProtocol.Test.SyncHelpers
  alias Backplane.McpProtocol.Transport.RequestContext
  alias Backplane.McpProtocol.Transport.SSE
  alias Backplane.McpProtocol.Transport.STDIO
  alias Backplane.McpProtocol.Transport.StreamableHTTP
  alias Backplane.McpProtocol.Transport.StreamableHTTP.Stream

  @moduletag capture_log: true

  setup do
    start_supervised!(StubClient)
    :ok = StubClient.subscribe()
    :ok
  end

  test "missing executable termination reports redact bound environment" do
    Process.flag(:trap_exit, true)
    previous_level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous_level) end)
    secret = "stdio-bound-secret-78"
    command = "backplane-missing-executable-78"

    log =
      capture_log([level: :error], fn ->
        assert {:ok, pid} =
                 STDIO.start_link(
                   client: StubClient,
                   command: command,
                   env: %{"API_KEY" => secret},
                   name: nil
                 )

        assert_receive {:EXIT, ^pid, {:error, reason}}, 1_000
        assert reason == "Command not found: #{command}"
      end)

    assert log =~ command
    assert log =~ "redacted"
    refute log =~ secret
  end

  test "stdio diagnostic redaction preserves real subprocess credentials" do
    secret = "stdio-live-secret-78"

    {:ok, pid} =
      STDIO.start_link(
        client: StubClient,
        command: "sh",
        args: ["-c", ~s(printf '%s\\n' "$API_KEY"; cat)],
        env: %{"API_KEY" => secret},
        name: nil
      )

    on_exit(fn -> stop(pid) end)

    assert_receive {:stub_client_response, output}, 1_000
    assert output =~ secret
    assert :sys.get_state(pid).env == %{"API_KEY" => secret}
    status = inspect(:sys.get_status(pid), limit: :infinity)
    assert status =~ "redacted"
    assert status =~ "command"
    refute status =~ secret
  end

  test "SSE rejects a foreign advertised endpoint before initialization or POST" do
    Process.flag(:trap_exit, true)
    server = HTTPServer.open()
    other = HTTPServer.open()
    url = "http://localhost:#{server.port}"
    endpoint(server, "http://localhost:#{other.port}/messages")

    {:ok, pid} =
      SSE.start_link(
        client: StubClient,
        name: nil,
        server: [base_url: url],
        headers: %{"authorization" => "sse-secret-78"},
        http_options: [allowed_origin: url],
        transport_opts: [max_reconnections: 0]
      )

    assert_receive {:EXIT, ^pid, :cross_origin_endpoint}, 1_000
    refute :initialize in StubClient.get_signals()
  end

  test "SSE rejects a scheme-relative foreign endpoint under a nonroot base path" do
    Process.flag(:trap_exit, true)
    server = HTTPServer.open()
    other = HTTPServer.open()
    url = "http://localhost:#{server.port}"

    HTTPServer.expect_once(server, "GET", "/base/sse", fn conn ->
      conn =
        conn
        |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
        |> Plug.Conn.send_chunked(200)

      {:ok, conn} =
        Plug.Conn.chunk(conn, "event: endpoint\ndata: //localhost:#{other.port}/messages\n\n")

      conn
    end)

    {:ok, pid} =
      SSE.start_link(
        client: StubClient,
        name: nil,
        server: [base_url: url, base_path: "/base"],
        headers: %{"authorization" => "sse-secret-78"},
        http_options: [allowed_origin: url],
        transport_opts: [max_reconnections: 0]
      )

    assert_receive {:EXIT, ^pid, :cross_origin_endpoint}, 1_000
    refute :initialize in StubClient.get_signals()
  end

  test "SSE accepts same-origin endpoints and redacts status without changing sent headers" do
    server = HTTPServer.open()
    url = "http://localhost:#{server.port}"
    secret = "sse-live-secret-78"
    endpoint(server, "/messages")

    HTTPServer.expect_once(server, "POST", "/messages", fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == [secret]
      Plug.Conn.resp(conn, 202, "")
    end)

    {:ok, pid} =
      SSE.start_link(
        client: StubClient,
        name: nil,
        server: [base_url: url],
        headers: %{"authorization" => secret},
        http_options: [allowed_origin: url],
        transport_opts: [max_reconnections: 0]
      )

    on_exit(fn -> stop(pid) end)
    SyncHelpers.await_state(pid, & &1.message_url)
    assert :sys.get_state(pid).headers == %{"authorization" => secret}
    status = inspect(:sys.get_status(pid), limit: :infinity)
    assert status =~ "headers: :redacted"
    refute status =~ secret
    assert :ok = SSE.send_message(pid, "payload", [])
  end

  test "StreamableHTTP status redacts configured and dynamic headers while delivering both" do
    server = HTTPServer.open()
    url = "http://localhost:#{server.port}"
    secret = "http-live-secret-78"
    dynamic = "dynamic-secret-78"
    provider = fn -> {:ok, %{"x-dynamic-key" => dynamic}} end

    HTTPServer.expect_once(server, "POST", "/mcp", fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == [secret]
      assert Plug.Conn.get_req_header(conn, "x-dynamic-key") == [dynamic]
      Plug.Conn.resp(conn, 202, "")
    end)

    {:ok, pid} =
      StreamableHTTP.start_link(
        client: StubClient,
        name: nil,
        base_url: url,
        headers: %{"authorization" => secret},
        headers_provider: provider,
        http_options: [allowed_origin: url]
      )

    on_exit(fn -> stop(pid) end)
    assert :sys.get_state(pid).headers_provider == provider
    status = inspect(:sys.get_status(pid), limit: :infinity)
    assert status =~ "headers: :redacted"
    assert status =~ "headers_provider: :redacted"
    refute status =~ secret
    refute status =~ dynamic

    assert :ok =
             StreamableHTTP.send_message(pid, ~s({"jsonrpc":"2.0","method":"ping","id":1}), [])
  end

  test "modern subscription status redacts its captured request and preserves credential delivery" do
    server = HTTPServer.open()
    url = "http://localhost:#{server.port}"
    secret = "stream-live-secret-78"
    test_pid = self()

    HTTPServer.expect_once(server, "POST", "/mcp", fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == [secret]

      conn =
        conn
        |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
        |> Plug.Conn.send_chunked(200)

      send(test_pid, {:stream_open, self()})

      receive do
        :finish -> conn
      end
    end)

    {:ok, profile} = Registry.profile("2026-07-28")

    context = %RequestContext{
      profile: profile,
      era: :modern,
      lifecycle: :per_request,
      protocol_version: "2026-07-28",
      method: "subscriptions/listen",
      params: %{},
      parameter_headers: %{}
    }

    {:ok, stream} =
      Stream.start(%{
        owner: self(),
        transport: self(),
        subscription_id: "secure-stream",
        mcp_url: URI.parse(url <> "/mcp"),
        headers: %{},
        headers_provider: fn -> {:ok, %{"authorization" => secret}} end,
        http_options: [allowed_origin: url],
        encoded_request:
          ~s({"jsonrpc":"2.0","id":"secure-stream","method":"subscriptions/listen","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}),
        request_context: context
      })

    assert_receive {:stream_open, connection}, 1_000

    on_exit(fn ->
      send(connection, :finish)
      Stream.close(stream)
    end)

    assert is_function(:sys.get_state(stream).request.headers_provider, 0)
    status = inspect(:sys.get_status(stream), limit: :infinity)
    assert status =~ "request: :redacted"
    refute status =~ secret
    assert :ok = Stream.close(stream)
    send(connection, :finish)
  end

  defp endpoint(server, message_url) do
    HTTPServer.expect_once(server, "GET", "/sse", fn conn ->
      conn =
        conn
        |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
        |> Plug.Conn.send_chunked(200)

      {:ok, conn} = Plug.Conn.chunk(conn, "event: endpoint\ndata: #{message_url}\n\n")
      conn
    end)
  end

  defp stop(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal)
  catch
    :exit, {:noproc, _} -> :ok
  end
end

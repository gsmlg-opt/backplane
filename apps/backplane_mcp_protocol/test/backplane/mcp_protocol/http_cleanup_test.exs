defmodule Backplane.McpProtocol.HTTPCleanupTest do
  use ExUnit.Case, async: false

  alias Backplane.McpProtocol.HTTP
  alias Backplane.McpProtocol.Test.HTTPServer
  alias Backplane.McpProtocol.Transport.SSE
  alias Backplane.McpProtocol.Transport.StreamableHTTP
  alias Elixir.HTTP.RequestCompletion

  setup_all do
    {:ok, _} = Application.ensure_all_started(:backplane_mcp_protocol)
    :ok
  end

  test "private HTTP requests use neutral maps" do
    assert %{method: :get, url: %URI{}, headers: [_ | _], body: nil} =
             HTTP.build(:get, "http://localhost/mcp")
  end

  test "close remains responsive during blocked headers and retains actual request cleanup" do
    server = HTTPServer.open()
    owner = self()

    HTTPServer.expect_once(server, fn conn ->
      send(owner, :headers_blocked)
      receive do: (:release -> Plug.Conn.resp(conn, 200, "{}"))
    end)

    {:ok, transport} = StreamableHTTP.start_link(name: nil, client: self(), url: "http://localhost:#{server.port}/mcp")
    sender = Task.async(fn -> StreamableHTTP.send_message(transport, "{}", timeout: 10_000) end)
    assert_receive :headers_blocked, 2_000
    assert {:ok, %{phase: :active}} = StreamableHTTP.cleanup_status(transport)
    assert {:ok, report} = StreamableHTTP.close(transport, timeout: 2_000, activation_id: "fixture")
    assert report.version == 1
    assert report.phase == :closed
    assert report.outcome == :confirmed
    assert Enum.any?(report.resources, &(&1.scope == :http_request and &1.outcome == :confirmed))
    assert {:ok, ^report} = StreamableHTTP.cleanup_status(transport)
    assert {:ok, ^report} = StreamableHTTP.close(transport, timeout: 100)
    assert {:error, :closing} = StreamableHTTP.send_message(transport, "{}", timeout: 100)
    Task.await(sender)
    GenServer.stop(transport)
  end

  test "all redirect request barriers are retained and another client remains usable" do
    server = HTTPServer.open()
    owner = self()
    url = "http://localhost:#{server.port}"

    HTTPServer.expect_once(server, "POST", "/old", fn conn ->
      conn |> Plug.Conn.put_resp_header("location", "/blocked") |> Plug.Conn.resp(307, "")
    end)

    HTTPServer.expect_once(server, "POST", "/blocked", fn conn ->
      send(owner, :redirect_blocked)
      receive do: (:release -> Plug.Conn.resp(conn, 200, "{}"))
    end)

    {:ok, transport} = StreamableHTTP.start_link(name: nil, client: self(), url: url <> "/old")
    sender = Task.async(fn -> StreamableHTTP.send_message(transport, "{}", timeout: 10_000) end)
    assert_receive :redirect_blocked, 2_000
    assert {:ok, report} = StreamableHTTP.close(transport, timeout: 2_000)
    assert report.outcome == :confirmed
    assert Enum.count(report.resources, &(&1.scope == :http_request)) == 2
    HTTPServer.expect_once(server, "GET", "/healthy", &Plug.Conn.resp(&1, 200, "healthy"))
    assert {:ok, %{body: "healthy"}} = HTTP.request(HTTP.build(:get, url <> "/healthy"))
    Task.await(sender)
    GenServer.stop(transport)
  end

  test "legacy SSE closes its streaming request using its completion barrier" do
    server = HTTPServer.open()
    owner = self()

    HTTPServer.expect_once(server, "GET", "/sse", fn conn ->
      conn = conn |> Plug.Conn.put_resp_header("content-type", "text/event-stream") |> Plug.Conn.send_chunked(200)
      {:ok, conn} = Plug.Conn.chunk(conn, "event: endpoint\ndata: /messages\n\n")
      send(owner, :legacy_stream_open)
      receive do: (:release -> conn)
    end)

    {:ok, transport} =
      SSE.start_link(name: nil, client: self(), server: %{base_url: "http://localhost:#{server.port}", sse_path: "/sse"})

    assert_receive :legacy_stream_open, 2_000
    assert {:ok, report} = SSE.close(transport, timeout: 2_000)
    assert report.transport == :sse
    assert report.outcome == :confirmed
    assert Enum.any?(report.resources, &(&1.scope == :http_request and &1.outcome == :confirmed))
    assert {:ok, ^report} = SSE.cleanup_status(transport)
    GenServer.stop(transport)
  end

  test "transport close retains the modern subscription request barrier" do
    server = HTTPServer.open()
    owner = self()

    HTTPServer.expect_once(server, fn conn ->
      conn = conn |> Plug.Conn.put_resp_header("content-type", "text/event-stream") |> Plug.Conn.send_chunked(200)
      send(owner, :modern_stream_open)
      receive do: (:release -> conn)
    end)

    {:ok, transport} = StreamableHTTP.start_link(name: nil, client: self(), url: "http://localhost:#{server.port}/mcp")
    version = "2026-07-28"

    params = %{
      "notifications" => %{},
      "_meta" => %{
        "io.modelcontextprotocol/protocolVersion" => version,
        "io.modelcontextprotocol/clientCapabilities" => %{}
      }
    }

    {:ok, profile} = Backplane.McpProtocol.Protocol.Registry.profile(version)

    context = %Backplane.McpProtocol.Transport.RequestContext{
      profile: profile,
      era: :modern,
      lifecycle: :per_request,
      protocol_version: version,
      method: "subscriptions/listen",
      params: params,
      parameter_headers: %{}
    }

    encoded =
      JSON.encode!(%{"jsonrpc" => "2.0", "method" => "subscriptions/listen", "id" => "subscription", "params" => params})

    assert {:ok, stream} =
             StreamableHTTP.open_stream(transport, encoded,
               owner: self(),
               subscription_id: "subscription",
               request_context: context
             )

    assert_receive :modern_stream_open, 2_000
    assert {:ok, report} = StreamableHTTP.close(transport, timeout: 2_000)
    assert report.outcome == :confirmed
    assert Enum.any?(report.resources, &(&1.scope == :http_request and &1.outcome == :confirmed))
    refute Process.alive?(stream)
    GenServer.stop(transport)
  end

  test "lost allocation handoff never becomes confirmed cleanup" do
    alias Backplane.McpProtocol.HTTP.Lifecycle

    owner = self()
    {:ok, lifecycle} = Lifecycle.start_link(:streamable_http, "lost-allocation")

    {:ok, _worker} =
      Lifecycle.start(lifecycle, fn ->
        {^lifecycle, job} = Process.get(:mcp_http_lifecycle)
        {:ok, _} = Lifecycle.allocation(lifecycle, job)
        send(owner, :allocated_without_receipt)
        receive do: (:never -> :ok)
      end)

    assert_receive :allocated_without_receipt
    assert {:ok, report} = Lifecycle.close(lifecycle, timeout: 500)
    assert report.outcome == :unconfirmed
    assert Enum.any?(report.resources, &(&1.scope == :http_request and &1.error == {:error, :missing_completion_handle}))
    GenServer.stop(lifecycle)
  end

  test "unsupported completion evidence stays uncertain" do
    alias Backplane.McpProtocol.HTTP.Lifecycle

    owner = self()
    {:ok, lifecycle} = Lifecycle.start_link(:sse)

    {:ok, _worker} =
      Lifecycle.start(lifecycle, fn ->
        {^lifecycle, job} = Process.get(:mcp_http_lifecycle)
        {:ok, id} = Lifecycle.allocation(lifecycle, job)
        :ok = Lifecycle.completion(lifecycle, id, %RequestCompletion{unsupported: :tls_backend})
        send(owner, :unsupported_registered)
      end)

    assert_receive :unsupported_registered
    assert {:ok, report} = Lifecycle.close(lifecycle, timeout: 500)
    assert report.outcome == :unconfirmed
    assert Enum.any?(report.resources, &(&1.error == {:error, {:unsupported_completion, :tls_backend}}))
    GenServer.stop(lifecycle)
  end

  test "one close budget bounds all waits and status remains responsive" do
    alias Backplane.McpProtocol.HTTP.Lifecycle

    owner = self()
    {:ok, lifecycle} = Lifecycle.start_link(:sse)
    trackers = for _ <- 1..2, do: spawn(fn -> receive do: (:finish -> :ok) end)
    on_exit(fn -> Enum.each(trackers, &Process.exit(&1, :kill)) end)

    {:ok, _worker} =
      Lifecycle.start(lifecycle, fn ->
        {^lifecycle, job} = Process.get(:mcp_http_lifecycle)

        for tracker <- trackers do
          latch = :atomics.new(1, [])
          :atomics.put(latch, 1, 1)
          {:ok, id} = Lifecycle.allocation(lifecycle, job)
          Lifecycle.completion(lifecycle, id, %RequestCompletion{tracker: tracker, latch: latch})
        end

        send(owner, :barriers_registered)
      end)

    assert_receive :barriers_registered
    closer = Task.async(fn -> Lifecycle.close(lifecycle, timeout: 100) end)
    assert_eventually_closing(lifecycle)
    assert {:ok, %{phase: :closing, outcome: :pending}} = Lifecycle.status(lifecycle)
    assert {:ok, %{phase: :closed, outcome: :unconfirmed}} = Task.await(closer, 500)
    GenServer.stop(lifecycle)
  end

  test "receive timeout also bounds waiting for headers on an infinite request" do
    server = HTTPServer.open()

    HTTPServer.expect_once(server, fn conn ->
      receive do: (:release -> Plug.Conn.resp(conn, 200, "{}"))
    end)

    request = HTTP.build(:get, "http://localhost:#{server.port}/blocked")
    assert {:error, reason} = HTTP.request(request, request_timeout: :infinity, receive_timeout: 100)
    assert reason in [:timeout, :read_idle_timeout]
  end

  test "HTTP close options preserve the construction activation and resource identities" do
    alias Backplane.McpProtocol.HTTP.Lifecycle

    {:ok, lifecycle} = Lifecycle.start_link(:sse, "original-generation")
    {:ok, _worker} = Lifecycle.start(lifecycle, fn -> :ok end, :consumer)
    assert {:ok, before} = Lifecycle.status(lifecycle)
    assert {:ok, report} = Lifecycle.close(lifecycle, timeout: 500, activation_id: "another-generation")
    assert report.activation_id == before.activation_id
    assert Enum.all?(report.resources, fn resource -> elem(resource.id, 0) == before.activation_id end)
    assert {:ok, ^report} = Lifecycle.close(lifecycle, timeout: 100, activation_id: "third-generation")
    GenServer.stop(lifecycle)
  end

  test "legacy SSE POST clips Fetch budgets to the remaining finite operation deadline" do
    server = HTTPServer.open()
    owner = self()

    HTTPServer.expect_once(server, "GET", "/sse", fn conn ->
      conn = conn |> Plug.Conn.put_resp_header("content-type", "text/event-stream") |> Plug.Conn.send_chunked(200)
      {:ok, conn} = Plug.Conn.chunk(conn, "event: endpoint\ndata: /messages\n\n")
      receive do: (:release -> conn)
    end)

    HTTPServer.expect_once(server, "POST", "/messages", fn conn ->
      send(owner, :slow_post_started)
      receive do: (:release -> Plug.Conn.resp(conn, 200, "{}"))
    end)

    {:ok, transport} =
      SSE.start_link(
        name: nil,
        client: self(),
        server: %{base_url: "http://localhost:#{server.port}", sse_path: "/sse"},
        http_options: [request_timeout: :infinity, receive_timeout: :infinity, connect_timeout: 10_000]
      )

    on_exit(fn -> if Process.alive?(transport), do: GenServer.stop(transport) end)
    assert_receive {:"$gen_cast", :initialize}, 2_000
    lifecycle = :sys.get_state(transport).lifecycle
    :erlang.trace_pattern({HTTP, :follow_redirect, 2}, true, [:local])
    :erlang.trace(lifecycle, true, [:call, :set_on_spawn])
    on_exit(fn -> :erlang.trace_pattern({HTTP, :follow_redirect, 2}, false, [:local]) end)

    sender =
      Task.async(fn ->
        try do
          SSE.send_message(transport, "{}", timeout: 150)
        catch
          :exit, reason -> {:call_timeout, reason}
        end
      end)

    assert_receive {:trace, _worker, :call, {HTTP, :follow_redirect, [_, options]}}, 1_000

    for key <- [:request_timeout, :receive_timeout, :connect_timeout] do
      assert is_integer(options[key]) and options[key] > 0 and options[key] <= 150
    end

    assert_receive :slow_post_started, 1_000
    Task.await(sender, 1_000)
    assert_post_finished(transport)
    assert {:ok, %{outcome: :confirmed}} = SSE.close(transport, timeout: 1_000)
    GenServer.stop(transport)
  end

  defp assert_post_finished(transport, attempts \\ 100)
  defp assert_post_finished(_transport, 0), do: flunk("POST remained allocated after its operation deadline")

  defp assert_post_finished(transport, attempts) do
    if map_size(:sys.get_state(transport).pending) == 0 do
      :ok
    else
      Process.sleep(5)
      assert_post_finished(transport, attempts - 1)
    end
  end

  test "unsupported legacy HTTP options reject without copying option values" do
    assert {:error, {:invalid_http_options, %{unsupported: [:pool_timeout]}}} =
             HTTP.validate_options(pool_timeout: "secret")

    assert {:error, {:invalid_http_options, %{option: :connect_timeout}}} =
             HTTP.validate_options(connect_timeout: :infinity)
  end

  defp assert_eventually_closing(lifecycle, attempts \\ 50)

  defp assert_eventually_closing(lifecycle, attempts) when attempts > 0 do
    case Backplane.McpProtocol.HTTP.Lifecycle.status(lifecycle) do
      {:ok, %{phase: :closing}} ->
        :ok

      _ ->
        Process.sleep(1)
        assert_eventually_closing(lifecycle, attempts - 1)
    end
  end

  defp assert_eventually_closing(_lifecycle, 0), do: flunk("cleanup did not start")
end

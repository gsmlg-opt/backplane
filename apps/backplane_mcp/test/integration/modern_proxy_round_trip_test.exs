defmodule Backplane.Integration.ModernProxyRoundTripTest do
  use Backplane.ConnCase, async: false

  alias Backplane.Proxy.{Pool, Upstream}
  alias Backplane.Registry.ToolRegistry
  alias Backplane.Test.ModernUpstreamServer
  alias Backplane.Transport.{McpPlug, Session}

  @modern_version "2026-07-28"

  test "proxies structured values through a real modern upstream without sessions" do
    prefix = "modern-round-trip-#{System.unique_integer([:positive, :monotonic])}"
    tool_name = "#{prefix}::echo"

    assert ToolRegistry.lookup(tool_name) == nil
    assert Registry.lookup(Backplane.Proxy.ProcessRegistry, {prefix, :client}) == []

    start_supervised!({ModernUpstreamServer, transport: {:streamable_http, start: true}})

    bandit =
      start_supervised!(
        {Bandit, plug: {ModernUpstreamServer.Plug, observer: self()}, port: 0, ip: {127, 0, 0, 1}}
      )

    assert {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(bandit)

    config = %{
      name: prefix,
      prefix: prefix,
      transport: "http",
      protocol_version: @modern_version,
      url: "http://127.0.0.1:#{port}/mcp",
      headers: %{},
      auth_scheme: "none",
      timeout: 2_000
    }

    assert {:ok, upstream} = Pool.start_upstream(config)
    on_exit(fn -> stop_upstream(upstream, prefix, tool_name) end)

    assert eventually(fn -> ready_with_echo?(upstream, tool_name) end)

    assert %{
             status: :connected,
             protocol_preference: @modern_version,
             negotiated_version: @modern_version,
             era: :modern,
             negotiation_status: :ready
           } = Upstream.status(upstream)

    assert {:ok, upstream_result} =
             Upstream.forward(upstream, "echo", %{"value" => false}, 2_000)

    assert upstream_result["resultType"] == "complete"
    assert {:ok, %{"value" => false}} = Map.fetch(upstream_result, "structuredContent")

    session_count = Session.count()
    conn = modern_tool_call(tool_name, %{"value" => nil})
    response = JSON.decode!(conn.resp_body)

    assert conn.status == 200
    assert Plug.Conn.get_resp_header(conn, "mcp-session-id") == []
    assert Plug.Conn.get_resp_header(conn, "x-mcp-protocol-version") == [@modern_version]
    assert response["result"]["resultType"] == "complete"

    assert {:ok, %{"value" => nil}} =
             Map.fetch(response["result"], "structuredContent")

    assert Session.count() == session_count

    requests = drain_upstream_requests([])
    methods = Enum.map(requests, & &1.method)

    assert Enum.count(methods, &(&1 == "server/discover")) == 1
    assert Enum.count(methods, &(&1 == "tools/list")) == 1
    assert Enum.count(methods, &(&1 == "tools/call")) == 2
    refute "initialize" in methods
    refute "ping" in methods
    assert Enum.all?(requests, &(&1.session_headers == []))

    assert :ok = Pool.stop_upstream(upstream)

    cleanup =
      eventually_value(
        fn -> cleanup_state(upstream, prefix, tool_name) end,
        &cleanup_complete?/1
      )

    assert %{
             upstream_alive?: false,
             tool: nil,
             client: [],
             transport: []
           } = cleanup
  end

  defp ready_with_echo?(upstream, tool_name) do
    case Upstream.status(upstream) do
      %{status: :connected, negotiation_status: :ready, era: :modern} ->
        not is_nil(ToolRegistry.lookup(tool_name))

      _not_ready ->
        false
    end
  catch
    :exit, _reason -> false
  end

  defp modern_tool_call(name, arguments) do
    message = %{
      "jsonrpc" => "2.0",
      "id" => "modern-round-trip",
      "method" => "tools/call",
      "params" => %{
        "name" => name,
        "arguments" => arguments,
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => @modern_version,
          "io.modelcontextprotocol/clientCapabilities" => %{},
          "io.modelcontextprotocol/clientInfo" => %{
            "name" => "backplane-modern-round-trip-test",
            "version" => "1.0.0"
          }
        }
      }
    }

    conn(:post, "/", JSON.encode!(message))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json")
    |> put_req_header("mcp-protocol-version", @modern_version)
    |> put_req_header("mcp-method", "tools/call")
    |> put_req_header("mcp-name", name)
    |> McpPlug.call(McpPlug.init([]))
  end

  defp eventually(fun, timeout_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_eventually(fun, deadline)
  end

  defp eventually_value(fun, predicate, timeout_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_eventually_value(fun, predicate, deadline)
  end

  defp do_eventually_value(fun, predicate, deadline) do
    value = fun.()

    if predicate.(value) or System.monotonic_time(:millisecond) >= deadline do
      value
    else
      Process.sleep(10)
      do_eventually_value(fun, predicate, deadline)
    end
  end

  defp do_eventually(fun, deadline) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline do
        false
      else
        Process.sleep(10)
        do_eventually(fun, deadline)
      end
    end
  end

  defp drain_upstream_requests(requests) do
    receive do
      {:modern_upstream_request, request} ->
        drain_upstream_requests([request | requests])
    after
      0 -> Enum.reverse(requests)
    end
  end

  defp stop_upstream(upstream, prefix, tool_name) do
    stop_result =
      try do
        if Process.alive?(upstream), do: Pool.stop_upstream(upstream), else: :ok
      rescue
        error -> {:raised, error}
      catch
        kind, reason -> {kind, reason}
      end

    cleanup =
      eventually_value(
        fn -> cleanup_state(upstream, prefix, tool_name) end,
        &cleanup_complete?/1
      )

    assert stop_result in [:ok, {:error, :not_found}],
           "Pool.stop_upstream failed during cleanup: #{inspect(stop_result)}"

    assert cleanup_complete?(cleanup), "upstream cleanup incomplete: #{inspect(cleanup)}"
  end

  defp cleanup_state(upstream, prefix, tool_name) do
    %{
      upstream_alive?: Process.alive?(upstream),
      tool: ToolRegistry.lookup(tool_name),
      client: Registry.lookup(Backplane.Proxy.ProcessRegistry, {prefix, :client}),
      transport: Registry.lookup(Backplane.Proxy.ProcessRegistry, {prefix, :transport})
    }
  end

  defp cleanup_complete?(%{
         upstream_alive?: false,
         tool: nil,
         client: [],
         transport: []
       }),
       do: true

  defp cleanup_complete?(_state), do: false
end

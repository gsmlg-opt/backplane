defmodule Backplane.McpProtocol.Client.DualEraIntegrationTest do
  use ExUnit.Case, async: false

  alias Backplane.McpProtocol.Client
  alias Backplane.McpProtocol.MCP.Error
  alias Backplane.McpProtocol.MCP.Response
  alias Backplane.McpProtocol.Server.Modern.Subscriptions
  alias Backplane.McpProtocol.Server.Registry

  @modern_version "2026-07-28"

  setup do
    start_supervised!({ModernMockServer, transport: {:streamable_http, start: true}})
    start_supervised!({LegacyMockServer, transport: {:streamable_http, start: true}})

    modern_http = ModernMockServer.mount_http(self())
    legacy_http = LegacyMockServer.mount_http(self())

    %{modern_http: modern_http, legacy_http: legacy_http}
  end

  test "auto negotiates modern Streamable HTTP and projects cached tool headers", context do
    client = start_http_client(:dual_era_modern_http_client, context.modern_http.url, :auto)

    assert :ok = Client.await_ready(client)
    assert %{era: :modern, protocol_version: @modern_version} = Client.get_protocol_info(client)

    assert {:ok, %Response{result: %{"tools" => tools}}} = Client.list_tools(client)
    assert Enum.any?(tools, &(&1["name"] == "echo"))

    assert {:ok, %Response{result: result}} =
             Client.call_tool(client, "echo", %{"region" => "west", "value" => "hello"})

    assert result["resultType"] == "complete"
    assert result["structuredContent"] == %{"region" => "west", "value" => "hello"}

    assert_receive {:modern_mock_request, "tools/call", headers}
    assert headers["mcp-protocol-version"] == @modern_version
    assert headers["mcp-method"] == "tools/call"
    assert headers["mcp-name"] == "echo"
    assert headers["mcp-param-region"] == "west"
  end

  test "modern HTTP resolves MRTR input and keeps an ordinary request concurrent", context do
    client = start_http_client(:dual_era_mrtr_client, context.modern_http.url, @modern_version)
    assert :ok = Client.await_ready(client)

    assert :ok =
             Client.register_sampling_callback(client, fn _params ->
               {:ok,
                %{
                  "role" => "assistant",
                  "content" => %{"type" => "text", "text" => "resolved"},
                  "model" => "dual-era-test"
                }}
             end)

    pending = Task.async(fn -> Client.call_tool(client, "mrtr", %{}, timeout: 2_000) end)
    assert_receive {:modern_mock_mrtr_waiting, request_state}

    assert {:ok, %Response{result: %{"structuredContent" => %{"value" => "parallel"}}}} =
             Client.call_tool(client, "echo", %{"value" => "parallel"})

    assert {:ok,
            %Response{
              result: %{
                "resultType" => "complete",
                "structuredContent" => %{
                  "resolved" => true,
                  "requestState" => ^request_state,
                  "sampledText" => "resolved"
                }
              }
            }} = Task.await(pending, 2_000)
  end

  test "modern HTTP supports concurrent subscriptions without session lifecycle", context do
    client = start_http_client(:dual_era_subscription_client, context.modern_http.url, @modern_version)
    assert :ok = Client.await_ready(client)

    subscriber = self()

    parent = self()

    spawn(fn ->
      result =
        Client.listen_subscriptions(client, ["notifications/tools/list_changed"],
          subscriber: subscriber,
          timeout: 2_000
        )

      send(parent, {:subscription_opened, result})
    end)

    ModernMockServer.await_subscription!()

    assert {:ok, %Response{result: %{"structuredContent" => %{"value" => "parallel"}}}} =
             Client.call_tool(client, "echo", %{"value" => "parallel"})

    assert :ok =
             Subscriptions.publish(
               Registry.subscriptions_name(ModernMockServer),
               %{
                 "jsonrpc" => "2.0",
                 "method" => "notifications/tools/list_changed",
                 "params" => %{"revision" => 1}
               }
             )

    assert_receive {:subscription_opened, {:ok, subscription}}, 2_000

    assert_receive {:mcp_subscription, ^subscription, %{"method" => "notifications/tools/list_changed"}}

    assert :ok = Subscriptions.close(Registry.subscriptions_name(ModernMockServer))
    assert_receive {:mcp_subscription_closed, ^subscription, :complete}, 2_000
    assert :ok = Client.close_subscription(client, subscription)
  end

  test "auto falls back to legacy Streamable HTTP while a modern pin refuses it", context do
    auto = start_http_client(:dual_era_legacy_http_client, context.legacy_http.url, :auto)

    assert :ok = Client.await_ready(auto)
    assert %{era: :legacy, protocol_version: version} = Client.get_protocol_info(auto)
    assert version != @modern_version
    assert {:ok, %Response{result: %{"tools" => tools}}} = Client.list_tools(auto)
    assert Enum.any?(tools, &(&1["name"] == "legacy_echo"))
    assert_receive :legacy_mock_discovery_refused
    assert_receive :legacy_mock_initialized

    pinned =
      start_http_client(:dual_era_pinned_refusal_client, context.legacy_http.url, @modern_version)

    assert {:error, %Error{}} = Client.await_ready(pinned)
    assert_receive :legacy_mock_discovery_refused
    refute_receive :legacy_mock_initialized, 100
  end

  test "modern and auto-to-legacy stdio complete negotiation and calls" do
    modern = start_stdio_client(:dual_era_modern_stdio_client, ModernMockServer, @modern_version)
    assert :ok = Client.await_ready(modern, timeout: 15_000)
    assert %{era: :modern, protocol_version: @modern_version} = Client.get_protocol_info(modern)
    assert {:ok, %Response{result: %{"tools" => modern_tools}}} = Client.list_tools(modern)
    assert Enum.any?(modern_tools, &(&1["name"] == "echo"))

    assert {:ok, %Response{result: %{"structuredContent" => %{"value" => "modern-stdio"}}}} =
             Client.call_tool(modern, "echo", %{"value" => "modern-stdio"})

    modern_transport = Process.whereis(Module.concat(:dual_era_modern_stdio_client, Transport))
    modern_transport_ref = Process.monitor(modern_transport)

    {:os_pid, modern_server_os_pid} =
      modern_transport
      |> :sys.get_state()
      |> Map.fetch!(:port)
      |> Port.info(:os_pid)

    assert :ok = stop_supervised(:dual_era_modern_stdio_client)
    assert_receive {:DOWN, ^modern_transport_ref, :process, ^modern_transport, _reason}, 1_000
    assert_os_process_exits(modern_server_os_pid)

    legacy = start_stdio_client(:dual_era_legacy_stdio_client, LegacyMockServer, :auto)
    assert :ok = Client.await_ready(legacy, timeout: 15_000)
    assert %{era: :legacy} = Client.get_protocol_info(legacy)
    assert {:ok, %Response{result: %{"tools" => legacy_tools}}} = Client.list_tools(legacy)
    assert Enum.any?(legacy_tools, &(&1["name"] == "legacy_echo"))

    assert {:ok, %Response{result: %{"structuredContent" => %{"value" => "legacy-stdio"}}}} =
             Client.call_tool(legacy, "legacy_echo", %{"value" => "legacy-stdio"})

    legacy_transport = Process.whereis(Module.concat(:dual_era_legacy_stdio_client, Transport))
    legacy_transport_ref = Process.monitor(legacy_transport)

    {:os_pid, legacy_server_os_pid} =
      legacy_transport
      |> :sys.get_state()
      |> Map.fetch!(:port)
      |> Port.info(:os_pid)

    assert :ok = stop_supervised(:dual_era_legacy_stdio_client)
    assert_receive {:DOWN, ^legacy_transport_ref, :process, ^legacy_transport, _reason}, 1_000
    assert_os_process_exits(legacy_server_os_pid)
  end

  test "modern HTTP never acquires a session and GET/DELETE are refused", context do
    client = start_http_client(:dual_era_post_only_client, context.modern_http.url, @modern_version)
    assert :ok = Client.await_ready(client)

    transport = Process.whereis(Module.concat(:dual_era_post_only_client, Transport))
    assert %{session_id: nil, sse_task: nil} = :sys.get_state(transport)

    for method <- [:get, :delete] do
      assert {:ok, %{status: 405, headers: headers}} =
               ModernMockServer.request(context.modern_http.url, method,
                 headers: [{"mcp-protocol-version", @modern_version}]
               )

      refute Enum.any?(headers, fn {name, _value} ->
               String.downcase(name) == "mcp-session-id"
             end)
    end
  end

  defp start_http_client(name, url, protocol_version) do
    transport_name = Module.concat(name, Transport)

    start_supervised!(
      {Client,
       name: name,
       transport_name: transport_name,
       transport: {:streamable_http, base_url: url},
       client_info: %{"name" => "dual-era-integration", "version" => "1.0.0"},
       capabilities: %{"sampling" => %{}},
       protocol_version: protocol_version,
       timeout: 5_000}
    )

    name
  end

  defp start_stdio_client(name, server, protocol_version) do
    transport_name = Module.concat(name, Transport)

    start_supervised!(
      {Client,
       name: name,
       transport_name: transport_name,
       transport: server.stdio_transport(),
       client_info: %{"name" => "dual-era-integration", "version" => "1.0.0"},
       capabilities: %{},
       protocol_version: protocol_version,
       timeout: 15_000}
    )

    name
  end

  defp assert_os_process_exits(os_pid, attempts \\ 200)

  defp assert_os_process_exits(os_pid, 0) do
    flunk("stdio server OS process #{os_pid} remained alive after its client stopped")
  end

  defp assert_os_process_exits(os_pid, attempts) do
    if os_process_alive?(os_pid) do
      Process.sleep(10)
      assert_os_process_exits(os_pid, attempts - 1)
    else
      :ok
    end
  end

  defp os_process_alive?(os_pid) do
    case System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true) do
      {_output, 0} -> true
      {_output, _status} -> false
    end
  end
end

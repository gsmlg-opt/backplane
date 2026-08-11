defmodule ModernStdioTask5Server do
  @moduledoc false

  use Backplane.McpProtocol.Server,
    name: "modern-stdio-task-5",
    version: "1.0.0",
    capabilities: [
      {:tools, list_changed?: true},
      {:prompts, list_changed?: true},
      {:resources, list_changed?: true, subscribe?: true}
    ],
    protocol_versions: ["2026-07-28", "2025-11-25"]

  @impl true
  def init(_client_info, frame), do: {:ok, frame}

  @impl true
  def handle_request(request, frame) do
    if delay = get_in(request, ["params", "_delayMs"]), do: Process.sleep(delay)
    {:reply, %{"requestId" => request["id"]}, frame}
  end
end

defmodule Backplane.McpProtocol.Server.Transport.ModernSTDIOTest do
  use ExUnit.Case, async: false

  alias Backplane.McpProtocol.Server.Modern.Subscriptions
  alias Backplane.McpProtocol.Server.Registry
  alias Backplane.McpProtocol.Server.Session
  alias Backplane.McpProtocol.Server.Supervisor, as: ServerSupervisor
  alias Backplane.McpProtocol.Server.Transport.STDIO
  alias Backplane.McpProtocol.Telemetry

  @version "2026-07-28"
  @subscription_id_key "io.modelcontextprotocol/subscriptionId"

  setup tags do
    task_supervisor = Registry.task_supervisor_name(ModernStdioTask5Server)
    session_supervisor = Registry.session_supervisor_name(ModernStdioTask5Server)
    subscriptions = Registry.subscriptions_name(ModernStdioTask5Server)

    start_supervised!({Task.Supervisor, name: task_supervisor})
    start_supervised!({DynamicSupervisor, name: session_supervisor, strategy: :one_for_one})
    start_supervised!({Subscriptions, name: subscriptions})

    io_device = start_supervised!({TestIODevice, []})

    transport =
      start_supervised!(
        {STDIO,
         server: ModernStdioTask5Server,
         io_device: io_device,
         task_supervisor: task_supervisor,
         session_supervisor: session_supervisor,
         subscriptions: subscriptions,
         request_timeout: Map.get(tags, :request_timeout, 30_000)}
      )

    %{
      transport: transport,
      io_device: io_device,
      task_supervisor: task_supervisor,
      session_supervisor: session_supervisor,
      subscriptions: subscriptions
    }
  end

  test "starts with an unknown era and no legacy session", context do
    state = :sys.get_state(context.transport)
    assert state.detected_era == :unknown
    assert state.legacy_session == nil
    assert DynamicSupervisor.count_children(context.session_supervisor).active == 0
  end

  test "server supervision uses lazy legacy ownership and starts the modern hub before stdio" do
    on_exit(fn ->
      :persistent_term.erase({ServerSupervisor, ModernStdioTask5Server, :session_config})
      :persistent_term.erase({ServerSupervisor, ModernStdioTask5Server, :session_supervisor_mod})
      :persistent_term.erase({ServerSupervisor, ModernStdioTask5Server, :authorization_config})
    end)

    assert {:ok, {_flags, child_specs}} =
             ServerSupervisor.init(module: ModernStdioTask5Server, transport: :stdio)

    child_ids = Enum.map(child_specs, & &1.id)

    refute Session in child_ids
    assert Registry.session_supervisor_name(ModernStdioTask5Server) in child_ids
    assert Subscriptions in child_ids

    assert Enum.find_index(child_ids, &(&1 == Subscriptions)) <
             Enum.find_index(child_ids, &(&1 == STDIO))
  end

  test "server discovery locks modern and never creates a legacy session", context do
    push(context, modern_request("server/discover", "discover", %{}))
    [response] = await_messages(context.io_device, 1)

    assert %{
             "id" => "discover",
             "result" => %{"resultType" => "complete", "supportedVersions" => [@version]}
           } = response

    state = :sys.get_state(context.transport)
    assert state.detected_era == :modern
    assert state.legacy_session == nil
    assert DynamicSupervisor.count_children(context.session_supervisor).active == 0
  end

  test "legacy initialize locks legacy and lazily starts then reuses the singleton session", context do
    assert DynamicSupervisor.count_children(context.session_supervisor).active == 0

    push(context, legacy_initialize("legacy-init"))
    [_response] = await_messages(context.io_device, 1)

    state = :sys.get_state(context.transport)
    assert state.detected_era == :legacy
    assert state.legacy_session == Registry.stdio_session_name(ModernStdioTask5Server)
    assert session_pid = Process.whereis(state.legacy_session)
    assert DynamicSupervisor.count_children(context.session_supervisor).active == 1

    push(context, legacy_initialize("legacy-init-again"))
    [_first, _second] = await_messages(context.io_device, 2)

    assert Process.whereis(state.legacy_session) == session_pid
    assert DynamicSupervisor.count_children(context.session_supervisor).active == 1
  end

  test "connection-era conflicts return invalid request errors without switching era", context do
    push(context, modern_request("server/discover", "modern-first", %{}))
    [_response] = await_messages(context.io_device, 1)
    push(context, legacy_initialize("legacy-conflict"))
    [_response, conflict] = await_messages(context.io_device, 2)

    assert %{"id" => "legacy-conflict", "error" => %{"code" => -32_600}} = conflict
    assert :sys.get_state(context.transport).detected_era == :modern
    assert :sys.get_state(context.transport).legacy_session == nil
  end

  test "a modern marker conflicts with a locked legacy connection", context do
    push(context, legacy_initialize("legacy-first"))
    [_response] = await_messages(context.io_device, 1)
    push(context, modern_request("server/discover", "modern-conflict", %{}))
    [_response, conflict] = await_messages(context.io_device, 2)

    assert %{"id" => "modern-conflict", "error" => %{"code" => -32_600}} = conflict
    assert :sys.get_state(context.transport).detected_era == :legacy
  end

  test "ordinary modern requests execute concurrently and the transport serializes complete lines", context do
    push(context, modern_request("server/discover", "lock", %{}))
    [_response] = await_messages(context.io_device, 1)

    push(context, modern_request("tools/list", "slow", %{"_delayMs" => 150}))
    push(context, modern_request("tools/list", "fast", %{}))

    [_lock, first, second] = await_messages(context.io_device, 3)
    assert %{"id" => "fast", "result" => %{"resultType" => "complete"}} = first
    assert %{"id" => "slow", "result" => %{"resultType" => "complete"}} = second

    raw = TestIODevice.contents(context.io_device)
    assert String.ends_with?(raw, "\n")
    refute raw =~ "\n\n"
  end

  test "notifications/cancelled suppresses an active modern request response", context do
    push(context, modern_request("server/discover", "lock", %{}))
    [_response] = await_messages(context.io_device, 1)
    push(context, modern_request("tools/list", "cancel-me", %{"_delayMs" => 500}))

    await_transport(context.transport, fn state -> Map.has_key?(state.active_requests, "cancel-me") end)
    push(context, cancelled("cancel-me"))
    await_transport(context.transport, fn state -> not Map.has_key?(state.active_requests, "cancel-me") end)
    assert Task.Supervisor.children(context.task_supervisor) == []

    push(context, modern_request("server/discover", "after-cancel", %{}))
    messages = await_messages(context.io_device, 2)

    assert Enum.any?(messages, &(&1["id"] == "after-cancel"))
    refute Enum.any?(messages, &(&1["id"] == "cancel-me"))

    Process.sleep(600)
    assert length(await_messages(context.io_device, 2)) == 2
  end

  @tag request_timeout: 50
  test "timed-out modern requests emit one error and no late response", context do
    push(context, modern_request("tools/list", "timeout", %{"_delayMs" => 200}))

    [response] = await_messages(context.io_device, 1)
    assert %{"id" => "timeout", "error" => %{"code" => -32_603}} = response
    assert Task.Supervisor.children(context.task_supervisor) == []

    Process.sleep(250)
    assert [^response] = await_messages(context.io_device, 1)
    assert map_size(:sys.get_state(context.transport).active_requests) == 0
  end

  test "multiplexes subscriptions, stamps each request id, and cancels only the selected stream", context do
    push(
      context,
      modern_request("subscriptions/listen", "listen-a", %{
        "notifications" => %{"toolsListChanged" => true}
      })
    )

    push(
      context,
      modern_request("subscriptions/listen", "listen-b", %{
        "notifications" => %{"toolsListChanged" => true}
      })
    )

    acknowledgements = await_messages(context.io_device, 2)

    assert Enum.all?(
             acknowledgements,
             &(&1["method"] == "notifications/subscriptions/acknowledged")
           )

    event = notification("notifications/tools/list_changed", %{"revision" => 1})
    assert :ok = Subscriptions.publish(context.subscriptions, event)
    messages = await_messages(context.io_device, 4)

    delivered_ids =
      messages
      |> Enum.drop(2)
      |> Enum.map(&get_in(&1, ["params", "_meta", @subscription_id_key]))
      |> Enum.sort()

    assert delivered_ids == ["listen-a", "listen-b"]

    push(context, cancelled("listen-a"))

    await_transport(context.transport, fn state ->
      map_size(state.subscription_requests) == 1 and
        Map.has_key?(state.subscription_requests, "listen-b")
    end)

    assert :ok =
             Subscriptions.publish(
               context.subscriptions,
               notification("notifications/tools/list_changed", %{"revision" => 2})
             )

    messages = await_messages(context.io_device, 5)
    last = List.last(messages)
    assert get_in(last, ["params", "_meta", @subscription_id_key]) == "listen-b"
  end

  test "malformed JSON emits a parse error with null id and does not lock the era", context do
    assert :ok = TestIODevice.push_line(context.io_device, "{not-json")
    [response] = await_messages(context.io_device, 1)

    assert %{"jsonrpc" => "2.0", "id" => nil, "error" => %{"code" => -32_700}} = response
    assert :sys.get_state(context.transport).detected_era == :unknown
  end

  test "EOF stops the transport and monitored hub cleanup removes its subscriptions", context do
    event = attach_telemetry(Telemetry.event_transport_disconnect())

    push(
      context,
      modern_request("subscriptions/listen", "listen-eof", %{
        "notifications" => %{"toolsListChanged" => true}
      })
    )

    [_ack] = await_messages(context.io_device, 1)
    await_subscription_count(context.subscriptions, 1)

    monitor = Process.monitor(context.transport)
    assert :ok = TestIODevice.push_line(context.io_device, :eof)
    assert_receive {:DOWN, ^monitor, :process, _, :normal}
    assert_receive {:telemetry, ^event, %{system_time: _}, %{transport: :stdio, reason: :eof}}
    refute_receive {:telemetry, ^event, _, _}, 50
    await_subscription_count(context.subscriptions, 0)
  end

  test "read errors stop the transport and emit one transport error event", context do
    event = attach_telemetry(Telemetry.event_transport_error())
    monitor = Process.monitor(context.transport)

    assert :ok = TestIODevice.push_line(context.io_device, {:error, :injected_read_error})

    assert_receive {:DOWN, ^monitor, :process, _, {:error, :injected_read_error}}

    assert_receive {:telemetry, ^event, %{system_time: _}, %{transport: :stdio, reason: :injected_read_error}}

    refute_receive {:telemetry, ^event, _, _}, 50
  end

  test "explicit shutdown preserves exactly one transport disconnect event", context do
    event = attach_telemetry(Telemetry.event_transport_disconnect())
    monitor = Process.monitor(context.transport)

    assert :ok = STDIO.shutdown(context.transport)
    assert_receive {:DOWN, ^monitor, :process, _, :normal}
    assert_receive {:telemetry, ^event, %{system_time: _}, %{transport: :stdio, reason: :shutdown}}
    refute_receive {:telemetry, ^event, _, _}, 50
  end

  defp push(context, message) do
    TestIODevice.push_line(context.io_device, JSON.encode!(message))
  end

  defp modern_request(method, id, params) do
    meta = %{
      "io.modelcontextprotocol/protocolVersion" => @version,
      "io.modelcontextprotocol/clientCapabilities" => %{}
    }

    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => Map.put(params, "_meta", meta)
    }
  end

  defp legacy_initialize(id) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2025-11-25",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "legacy-test", "version" => "1.0.0"}
      }
    }
  end

  defp cancelled(request_id) do
    notification("notifications/cancelled", %{"requestId" => request_id})
  end

  defp notification(method, params) do
    %{"jsonrpc" => "2.0", "method" => method, "params" => params}
  end

  defp attach_telemetry(event_suffix) do
    handler_id = {__MODULE__, make_ref()}
    event = [:backplane_mcp_protocol | event_suffix]

    :ok =
      :telemetry.attach(
        handler_id,
        event,
        fn event, measurements, metadata, test_pid ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    event
  end

  defp await_messages(io_device, count, timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_messages(io_device, count, deadline)
  end

  defp do_await_messages(io_device, count, deadline) do
    messages =
      io_device
      |> TestIODevice.contents()
      |> String.split("\n", trim: true)
      |> Enum.map(&JSON.decode!/1)

    cond do
      length(messages) >= count ->
        messages

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("timed out waiting for #{count} stdio messages, got: #{inspect(messages)}")

      true ->
        receive do
        after
          1 -> do_await_messages(io_device, count, deadline)
        end
    end
  end

  defp await_transport(transport, predicate, timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_transport(transport, predicate, deadline)
  end

  defp do_await_transport(transport, predicate, deadline) do
    state = :sys.get_state(transport)

    cond do
      predicate.(state) ->
        state

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("timed out waiting for transport state: #{inspect(state)}")

      true ->
        receive do
        after
          1 -> do_await_transport(transport, predicate, deadline)
        end
    end
  end

  defp await_subscription_count(hub, expected, timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_subscription_count(hub, expected, deadline)
  end

  defp do_await_subscription_count(hub, expected, deadline) do
    state = :sys.get_state(hub)

    cond do
      map_size(state.subscriptions) == expected ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("timed out waiting for #{expected} subscriptions: #{inspect(state)}")

      true ->
        receive do
        after
          1 -> do_await_subscription_count(hub, expected, deadline)
        end
    end
  end
end

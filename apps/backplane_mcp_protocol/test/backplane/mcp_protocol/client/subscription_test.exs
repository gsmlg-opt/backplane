defmodule Backplane.McpProtocol.Client.SubscriptionTest do
  use ExUnit.Case, async: false

  alias Backplane.McpProtocol.Client
  alias Backplane.McpProtocol.Client.Subscription
  alias Backplane.McpProtocol.MCP.Error
  alias Backplane.McpProtocol.Transport.STDIO

  @subscription_id_key "io.modelcontextprotocol/subscriptionId"

  defmodule CapturePort do
    @moduledoc false
    use GenServer

    def start_link(owner), do: GenServer.start_link(__MODULE__, owner)
    def init(owner), do: {:ok, owner}

    def handle_call({:send, encoded}, _from, owner) do
      case owner do
        {pid, label} -> send(pid, {:stdio_send, label, encoded})
        pid -> send(pid, {:stdio_send, encoded})
      end

      {:reply, :ok, owner}
    end

    def handle_cast(:close_port, owner), do: {:stop, :normal, owner}
  end

  defmodule AttachTransport do
    @moduledoc false
    use GenServer

    def start_link({owner, mode}), do: GenServer.start_link(__MODULE__, {owner, mode})
    def init({owner, mode}), do: {:ok, %{owner: owner, mode: mode}}

    def supported_protocol_versions, do: :all

    def transport_init(opts \\ []) do
      Backplane.McpProtocol.Transport.STDIO.transport_init(opts)
    end

    def parse(raw, state) do
      Backplane.McpProtocol.Transport.STDIO.parse(raw, state)
    end

    def send_message(pid, encoded, _opts) do
      GenServer.call(pid, {:send, encoded})
    end

    def open_stream(pid, encoded, opts) do
      GenServer.call(pid, {:open_stream, encoded, opts})
    end

    def close_stream(pid, stream, opts) do
      GenServer.call(pid, {:close_stream, stream, opts}, Keyword.get(opts, :timeout, 5_000))
    end

    def shutdown(pid), do: GenServer.cast(pid, :close_port)

    def handle_call({:send, encoded}, _from, state) do
      send(state.owner, {:fake_send, encoded})
      {:reply, :ok, state}
    end

    def handle_call({:open_stream, encoded, opts}, _from, state) do
      subscription = Keyword.fetch!(opts, :owner)
      stream = spawn(fn -> receive do: (:stop -> :ok) end)

      case state.mode do
        :attach_death ->
          monitor = Process.monitor(subscription)
          Process.exit(subscription, :kill)
          receive do: ({:DOWN, ^monitor, :process, ^subscription, :killed} -> :ok)

        :attach_timeout ->
          :sys.suspend(subscription)

        :preattach_terminals ->
          foreign_stream = spawn(fn -> receive do: (:stop -> :ok) end)
          send(subscription, {:mcp_stream_error, foreign_stream, :foreign_first})
          send(subscription, {:mcp_stream_error, stream, :first_own_terminal})
          send(subscription, {:mcp_stream_closed, stream, :later_own_terminal})
          _state = :sys.get_state(subscription)
          Process.exit(foreign_stream, :kill)
          Process.exit(stream, :kill)

        _mode ->
          :ok
      end

      send(state.owner, {:fake_open, state.mode, JSON.decode!(encoded), stream})
      {:reply, {:ok, stream}, state}
    end

    def handle_call({:close_stream, stream, opts}, _from, state) do
      send(state.owner, {:fake_close, state.mode, self(), stream, opts})
      if state.mode == :close_timeout, do: Process.sleep(200)
      if Process.alive?(stream), do: Process.exit(stream, :kill)
      {:reply, :ok, state}
    end

    def handle_cast(:close_port, state), do: {:stop, :normal, state}
  end

  test "gates delivery on a strict acknowledgement and multiplexes subscriptions by ID over stdio" do
    {:ok, transport} = start_supervised({CapturePort, self()})
    client = start_modern_stdio_client(transport)
    owner = self()

    first_task =
      Task.async(fn ->
        Client.listen_subscriptions(client, ["notifications/tools/list_changed"],
          subscriber: owner,
          timeout: 500
        )
      end)

    tools_request = receive_listen_request()

    second_task =
      Task.async(fn ->
        Client.listen_subscriptions(client, ["notifications/resources/list_changed"],
          subscriber: owner,
          timeout: 500
        )
      end)

    resources_request = receive_listen_request()
    refute tools_request["id"] == resources_request["id"]
    assert tools_request["params"]["notifications"] == %{"toolsListChanged" => true}
    assert resources_request["params"]["notifications"] == %{"resourcesListChanged" => true}

    send_notification(client, "notifications/tools/list_changed", tools_request["id"], %{
      "revision" => 1
    })

    refute_receive {:mcp_subscription, _, _}, 30

    send_ack(client, resources_request["id"], %{"resourcesListChanged" => true})

    send_ack(client, to_string(tools_request["id"]), %{"toolsListChanged" => true},
      subscription_id: 7
    )

    refute Task.yield(first_task, 20)

    send_ack(client, tools_request["id"], %{"toolsListChanged" => true})

    assert {:ok, %Subscription{acknowledged?: true} = first} = Task.await(first_task)
    assert {:ok, %Subscription{acknowledged?: true} = second} = Task.await(second_task)

    by_id = Map.new([first, second], &{&1.id, &1})
    tools = Map.fetch!(by_id, tools_request["id"])
    resources = Map.fetch!(by_id, resources_request["id"])

    send_notification(client, "notifications/resources/list_changed", resources.id, %{
      "revision" => 2
    })

    send_notification(client, "notifications/tools/list_changed", tools.id, %{"revision" => 3})

    assert_receive {:mcp_subscription, %Subscription{id: id}, %{"params" => %{"revision" => 2}}}
    assert id == resources.id

    assert_receive {:mcp_subscription, %Subscription{id: id}, %{"params" => %{"revision" => 3}}}
    assert id == tools.id

    assert Process.alive?(tools.pid)
    Process.sleep(550)
    assert Process.alive?(tools.pid)

    send_notification(client, "notifications/tools/list_changed", tools.id, %{"revision" => 4})
    assert_receive {:mcp_subscription, %Subscription{id: id}, %{"params" => %{"revision" => 4}}}
    assert id == tools.id

    forged = %{tools | pid: self()}
    assert :ok = Client.close_subscription(client, forged, timeout: 50)
    assert Process.alive?(tools.pid)
    refute_receive {:stdio_send, _forged_cancel}, 30

    assert :ok = Client.close_subscription(client, tools)
    assert_receive {:stdio_send, cancelled}

    assert %{
             "jsonrpc" => "2.0",
             "method" => "notifications/cancelled",
             "params" => %{"requestId" => request_id}
           } = JSON.decode!(cancelled)

    assert request_id == tools.id
    assert :ok = Client.close_subscription(client, tools)
    refute_receive {:stdio_send, _duplicate_cancel}, 30

    assert :ok = Client.close_subscription(client, resources)
    assert_receive {:stdio_send, _cancelled}
  end

  test "every terminal message before acknowledgement replies to the waiting listen caller" do
    {:ok, transport} = start_supervised({CapturePort, self()})
    client = start_modern_stdio_client(transport)

    complete_task = Task.async(fn -> Client.listen_subscriptions(client, [], timeout: 500) end)
    complete_request = receive_listen_request()

    GenServer.cast(
      client,
      {:response,
       JSON.encode!(%{
         "jsonrpc" => "2.0",
         "id" => complete_request["id"],
         "result" => %{
           "resultType" => "complete",
           "_meta" => %{@subscription_id_key => complete_request["id"]}
         }
       }) <> "\n"}
    )

    assert {:error, %Error{reason: :subscription_closed_before_ack}} = Task.await(complete_task)

    error_task = Task.async(fn -> Client.listen_subscriptions(client, [], timeout: 500) end)
    error_request = receive_listen_request()

    GenServer.cast(
      client,
      {:response,
       JSON.encode!(%{
         "jsonrpc" => "2.0",
         "id" => error_request["id"],
         "error" => %{"code" => -32_000, "message" => "listen rejected"}
       }) <> "\n"}
    )

    assert {:error, %Error{message: "listen rejected"}} = Task.await(error_task)

    cancelled_task = Task.async(fn -> Client.listen_subscriptions(client, [], timeout: 500) end)
    cancelled_request = receive_listen_request()
    send_cancelled(client, cancelled_request["id"], "server stopped")

    assert {:error, %Error{reason: :request_cancelled}} = Task.await(cancelled_task)

    closed_task = Task.async(fn -> Client.listen_subscriptions(client, [], timeout: 500) end)
    _closed_request = receive_listen_request()
    GenServer.stop(client, :normal)

    assert {:error, %Error{reason: :client_terminated}} = Task.await(closed_task)
  end

  test "modern cancellation closes only matching subscriptions and ignores ordinary and unknown IDs" do
    {:ok, transport} = start_supervised({CapturePort, self()})
    client = start_modern_stdio_client(transport)
    owner = self()

    first_task =
      Task.async(fn ->
        Client.listen_subscriptions(client, [], subscriber: owner, timeout: 500)
      end)

    first_request = receive_listen_request()
    send_ack(client, first_request["id"], %{})
    assert {:ok, first} = Task.await(first_task)

    second_task =
      Task.async(fn ->
        Client.listen_subscriptions(client, [], subscriber: owner, timeout: 500)
      end)

    second_request = receive_listen_request()
    send_ack(client, second_request["id"], %{})
    assert {:ok, second} = Task.await(second_task)

    ping_task = Task.async(fn -> Client.ping(client, timeout: 500) end)
    assert_receive {:stdio_send, encoded_ping}
    ping_request = JSON.decode!(encoded_ping)
    assert ping_request["method"] == "ping"

    first_pid = first.pid
    first_monitor = Process.monitor(first.pid)
    send_cancelled(client, first.id, "server stopped")

    assert_receive {:mcp_subscription_closed, %Subscription{id: id},
                    {:error, %Error{reason: :request_cancelled}}}

    assert id == first.id
    assert_receive {:DOWN, ^first_monitor, :process, ^first_pid, :normal}
    assert Process.alive?(second.pid)
    refute Task.yield(ping_task, 20)

    send_cancelled(client, "unknown-subscription", "ignore me")
    assert Process.alive?(second.pid)
    refute Task.yield(ping_task, 20)

    send_cancelled(client, ping_request["id"], "cancel the ordinary request")
    assert Process.alive?(second.pid)
    refute Task.yield(ping_task, 20)

    GenServer.cast(
      client,
      {:response,
       JSON.encode!(%{
         "jsonrpc" => "2.0",
         "id" => ping_request["id"],
         "result" => %{"resultType" => "complete"}
       }) <> "\n"}
    )

    assert :pong = Task.await(ping_task)
    assert :ok = Client.close_subscription(client, second)
    assert_receive {:stdio_send, _cancelled}
  end

  test "an unstamped modern list-changed notification follows the ordinary handler path" do
    {:ok, _applications} = Application.ensure_all_started(:telemetry)
    {:ok, transport} = start_supervised({CapturePort, self()})
    client = start_modern_stdio_client(transport)
    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:backplane_mcp_protocol, :client, :notification],
        fn _event, _measurements, metadata, owner ->
          send(owner, {:ordinary_client_notification, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    GenServer.cast(
      client,
      {:response,
       JSON.encode!(%{
         "jsonrpc" => "2.0",
         "method" => "notifications/tools/list_changed",
         "params" => %{}
       }) <> "\n"}
    )

    assert_receive {:ordinary_client_notification, %{method: "tools/list_changed"}}
  end

  test "controller closes when the exact registered transport dies and does not reattach to its replacement" do
    global_key = {__MODULE__, make_ref()}
    transport_name = {:global, global_key}
    {:ok, transport} = GenServer.start(CapturePort, self(), name: transport_name)
    client = start_modern_stdio_client(transport_name)

    task = Task.async(fn -> Client.listen_subscriptions(client, [], timeout: 500) end)
    _request = receive_listen_request()

    transport_monitor = Process.monitor(transport)
    Process.exit(transport, :kill)
    assert_receive {:DOWN, ^transport_monitor, :process, ^transport, :killed}

    {:ok, replacement} = GenServer.start(CapturePort, self(), name: transport_name)

    assert {:error, %Error{reason: :subscription_transport_down}} = Task.await(task)
    refute_receive {:stdio_send, _sent_to_replacement}, 30
    GenServer.stop(replacement)
  end

  test "close targets the originally monitored transport rather than a registered replacement" do
    global_key = {__MODULE__, make_ref()}
    transport_name = {:global, global_key}
    {:ok, original} = GenServer.start(CapturePort, {self(), :original}, name: transport_name)
    client = start_modern_stdio_client(transport_name)

    task = Task.async(fn -> Client.listen_subscriptions(client, [], timeout: 500) end)
    assert_receive {:stdio_send, :original, encoded}
    request = JSON.decode!(encoded)
    send_ack(client, request["id"], %{})
    assert {:ok, subscription} = Task.await(task)

    :global.unregister_name(global_key)

    {:ok, replacement} =
      GenServer.start(CapturePort, {self(), :replacement}, name: transport_name)

    assert :ok = Client.close_subscription(client, subscription, timeout: 100)
    assert_receive {:stdio_send, :original, cancelled}
    assert JSON.decode!(cancelled)["params"]["requestId"] == subscription.id
    refute_receive {:stdio_send, :replacement, _cancelled}, 30

    GenServer.stop(original)
    GenServer.stop(replacement)
  end

  test "attach death and timeout close the newly opened stream without crashing the client" do
    for {mode, reason} <- [
          attach_death: :subscription_attach_failed,
          attach_timeout: :subscription_attach_timeout
        ] do
      {:ok, transport} =
        start_supervised({AttachTransport, {self(), mode}}, id: {AttachTransport, mode})

      client = start_modern_client(AttachTransport, transport)

      started_at = System.monotonic_time(:millisecond)
      task = Task.async(fn -> Client.listen_subscriptions(client, [], timeout: 50) end)
      assert_receive {:fake_open, ^mode, request, stream}
      assert request["method"] == "subscriptions/listen"

      assert {:error, %Error{reason: ^reason}} = Task.await(task)
      assert_receive {:fake_close, ^mode, ^transport, ^stream, close_opts}
      assert close_opts[:subscription_id] == request["id"]
      refute Process.alive?(stream)
      assert Process.alive?(client)
      assert System.monotonic_time(:millisecond) - started_at < 500
    end
  end

  test "pre-attach terminals preserve source and first-terminal ordering" do
    {:ok, transport} = start_supervised({AttachTransport, {self(), :preattach_terminals}})
    client = start_modern_client(AttachTransport, transport)

    task = Task.async(fn -> Client.listen_subscriptions(client, [], timeout: 500) end)
    assert_receive {:fake_open, :preattach_terminals, _request, stream}

    assert {:error,
            %Error{
              reason: :subscription_stream_failed,
              data: %{reason: :first_own_terminal}
            }} = Task.await(task)

    refute Process.alive?(stream)
    assert Process.alive?(client)
  end

  test "bounded close preserves timeout errors and validates public timeouts before calls" do
    {:ok, transport} = start_supervised({AttachTransport, {self(), :close_timeout}})
    client = start_modern_client(AttachTransport, transport)
    owner = self()

    assert {:error, %Error{reason: :invalid_params}} =
             Client.listen_subscriptions(client, [], timeout: :infinity)

    refute_receive {:fake_open, _, _, _}

    task =
      Task.async(fn ->
        Client.listen_subscriptions(client, [], subscriber: owner, timeout: 500)
      end)

    assert_receive {:fake_open, :close_timeout, request, _stream}
    send_ack(client, request["id"], %{})
    assert {:ok, subscription} = Task.await(task)

    assert {:error, %Error{reason: :invalid_params}} =
             Client.close_subscription(client, subscription, timeout: 0)

    assert Process.alive?(subscription.pid)

    assert {:error, %Error{reason: :subscription_close_timeout}} =
             Client.close_subscription(client, subscription, timeout: 50)

    assert_receive {:fake_close, :close_timeout, ^transport, _stream, close_opts}
    assert close_opts[:timeout] == 50
    assert Process.alive?(client)
  end

  test "an acknowledged subscription reports Client death exactly once to its live subscriber" do
    {:ok, transport} = start_supervised({CapturePort, self()})
    client = start_modern_stdio_client(transport)
    owner = self()

    task =
      Task.async(fn ->
        Client.listen_subscriptions(client, [], subscriber: owner, timeout: 500)
      end)

    request = receive_listen_request()
    send_ack(client, request["id"], %{})
    assert {:ok, subscription} = Task.await(task)

    subscription_monitor = Process.monitor(subscription.pid)
    Process.exit(client, :kill)

    assert_receive {:mcp_subscription_closed, %Subscription{id: id},
                    {:error, %Error{reason: :client_terminated}}}

    assert id == subscription.id
    assert_receive {:DOWN, ^subscription_monitor, :process, _, :normal}
    refute_receive {:mcp_subscription_closed, %Subscription{id: ^id}, _reason}, 30
  end

  test "an attached HTTP-style stream death is surfaced to the subscriber" do
    {:ok, transport} = start_supervised({AttachTransport, {self(), :normal}})
    client = start_modern_client(AttachTransport, transport)
    owner = self()

    task =
      Task.async(fn ->
        Client.listen_subscriptions(client, [], subscriber: owner, timeout: 500)
      end)

    assert_receive {:fake_open, :normal, request, stream}
    send_ack(client, request["id"], %{})
    assert {:ok, subscription} = Task.await(task)

    Process.exit(stream, :kill)

    assert_receive {:mcp_subscription_closed, %Subscription{id: id},
                    {:error, %Error{reason: :subscription_stream_down}}}

    assert id == subscription.id
  end

  test "a foreign subscription stamp cannot swallow an ordinary response" do
    {:ok, transport} = start_supervised({CapturePort, self()})
    client = start_modern_stdio_client(transport)
    owner = self()

    listen_task =
      Task.async(fn ->
        Client.listen_subscriptions(client, [], subscriber: owner, timeout: 500)
      end)

    request = receive_listen_request()
    send_ack(client, request["id"], %{})
    assert {:ok, subscription} = Task.await(listen_task)

    ping_task = Task.async(fn -> Client.ping(client, timeout: 500) end)
    assert_receive {:stdio_send, encoded_ping}
    ping = JSON.decode!(encoded_ping)

    GenServer.cast(
      client,
      {:response,
       JSON.encode!(%{
         "jsonrpc" => "2.0",
         "id" => ping["id"],
         "result" => %{
           "resultType" => "complete",
           "_meta" => %{@subscription_id_key => subscription.id}
         }
       }) <> "\n"}
    )

    assert :pong = Task.await(ping_task)
    assert Process.alive?(subscription.pid)
    assert :ok = Client.close_subscription(client, subscription)
    assert_receive {:stdio_send, _cancelled}
  end

  test "accepts an empty filter and consumes a matching graceful final response without replying twice" do
    {:ok, transport} = start_supervised({CapturePort, self()})
    client = start_modern_stdio_client(transport)
    owner = self()

    task =
      Task.async(fn ->
        Client.listen_subscriptions(client, [], subscriber: owner, timeout: 500)
      end)

    request = receive_listen_request()
    assert request["params"]["notifications"] == %{}
    send_ack(client, request["id"], %{})

    assert {:ok, %Subscription{} = subscription} = Task.await(task)
    monitor = Process.monitor(subscription.pid)

    GenServer.cast(
      client,
      {:response,
       JSON.encode!(%{
         "jsonrpc" => "2.0",
         "id" => subscription.id,
         "result" => %{
           "resultType" => "complete",
           "_meta" => %{@subscription_id_key => subscription.id}
         }
       }) <> "\n"}
    )

    assert_receive {:mcp_subscription_closed, %Subscription{id: id}, :complete}
    assert id == subscription.id
    assert_receive {:DOWN, ^monitor, :process, _, :normal}
    assert Process.alive?(client)

    assert :ok = Client.close_subscription(client, subscription)
    refute_receive {:stdio_send, _cancel_after_server_close}, 30
  end

  test "rejects legacy resource subscription RPCs on a modern peer before allocating an ID or sending wire data" do
    {:ok, transport} = start_supervised({CapturePort, self()})
    client = start_modern_stdio_client(transport)

    assert {:error, %Error{reason: :unsupported_operation}} =
             Client.subscribe_resource(client, "file:///modern")

    assert {:error, %Error{reason: :unsupported_operation}} =
             Client.unsubscribe_resource(client, "file:///modern")

    refute_receive {:stdio_send, _}

    :sys.replace_state(client, fn state ->
      %{
        state
        | era: :legacy,
          protocol_version: "2025-11-25",
          negotiated_version: "2025-11-25",
          server_capabilities: %{"resources" => %{"subscribe" => true}}
      }
    end)

    assert {:error, %Error{reason: :unsupported_operation}} =
             Client.listen_subscriptions(client, [], timeout: 100)
  end

  defp start_modern_stdio_client(transport) do
    start_modern_client(STDIO, transport)
  end

  defp start_modern_client(layer, transport) do
    init_opts = %{
      name: nil,
      transport: [layer: layer, name: transport],
      client_info: %{"name" => "SubscriptionTest", "version" => "1.0.0"},
      capabilities: %{},
      protocol_version: "2026-07-28",
      timeout: 1_000
    }

    start =
      if layer == AttachTransport do
        {GenServer, :start_link, [Client, init_opts]}
      else
        {Client, :start_link_server, [Map.to_list(init_opts)]}
      end

    client =
      start_supervised!(%{
        id: {Client, layer, System.unique_integer([:positive])},
        start: start,
        restart: :temporary
      })

    :sys.replace_state(client, fn state ->
      %{
        state
        | era: :modern,
          protocol_version: "2026-07-28",
          negotiated_version: "2026-07-28",
          negotiation_status: :ready,
          server_capabilities: %{}
      }
    end)

    client
  end

  defp receive_listen_request do
    assert_receive {:stdio_send, encoded}
    request = JSON.decode!(encoded)
    assert request["jsonrpc"] == "2.0"
    assert request["method"] == "subscriptions/listen"
    request
  end

  defp send_ack(client, subscription_id, notifications, opts \\ []) do
    stamped_id = Keyword.get(opts, :subscription_id, subscription_id)

    send_notification(
      client,
      "notifications/subscriptions/acknowledged",
      stamped_id,
      %{"notifications" => notifications}
    )
  end

  defp send_notification(client, method, subscription_id, params) do
    params = Map.put(params, "_meta", %{@subscription_id_key => subscription_id})

    GenServer.cast(
      client,
      {:response,
       JSON.encode!(%{"jsonrpc" => "2.0", "method" => method, "params" => params}) <> "\n"}
    )
  end

  defp send_cancelled(client, request_id, reason) do
    GenServer.cast(
      client,
      {:response,
       JSON.encode!(%{
         "jsonrpc" => "2.0",
         "method" => "notifications/cancelled",
         "params" => %{"requestId" => request_id, "reason" => reason}
       }) <> "\n"}
    )
  end
end

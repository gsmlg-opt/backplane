defmodule Backplane.HostAgent.WorkerTest do
  use ExUnit.Case, async: false

  alias Backplane.HostAgent.{Config, Manifest, Worker}

  defmodule FakeChannel do
    def push(_channel, event, payload) do
      owner = Process.get(:test_owner) || :persistent_term.get({__MODULE__, :owner}, self())
      send(owner, {:push, event, payload})

      case Process.get({__MODULE__, event}) do
        nil -> {:ok, %{"ok" => true}}
        reply -> reply
      end
    end
  end

  defmodule ExitingChannel do
    def push(_channel, event, payload) do
      owner = Process.get(:test_owner) || :persistent_term.get({__MODULE__, :owner}, self())
      send(owner, {:push, event, payload})
      exit(:shutdown)
    end
  end

  defmodule RaisingChannel do
    def push(_channel, _event, _payload) do
      raise KeyError,
        key: :missing,
        term: %{headers: %{authorization: "nested-exception-fixture-token"}}
    end
  end

  defmodule FakeInstaller do
    def install(skill, config) do
      send(self(), {:install, skill, config})
      Process.get(__MODULE__, {:ok, ["agents"]})
    end

    def remove(skill, config) do
      send(self(), {:remove, skill, config})
      Process.get({__MODULE__, :remove}, {:ok, ["agents"]})
    end
  end

  defmodule FakeRuntimeConfig do
    def load_default do
      {:ok,
       %{
         host_id: "host-1",
         hub_url: "http://localhost:4220",
         machine_name: "t430",
         manifest_path: "/tmp/manifest.json",
         token: "host-token"
       }}
    end
  end

  defmodule StructRuntimeConfig do
    def load_default do
      {:ok, config} = FakeRuntimeConfig.load_default()

      {:ok,
       struct!(
         Config,
         Map.put(config, :memory, %{
           enabled: false,
           host_sync_v2: %{enabled: true, development_plaintext: true, sync_interval_ms: 1_000}
         })
       )}
    end
  end

  defmodule FastRuntimeConfig do
    def load_default do
      {:ok,
       %{
         host_id: "host-1",
         hub_url: "http://localhost:4220",
         interval_ms: 10,
         machine_name: "t430",
         manifest_path: "/tmp/manifest.json",
         token: "host-token"
       }}
    end
  end

  defmodule ReconnectRuntimeConfig do
    def load_default do
      {:ok,
       %{
         host_id: "host-1",
         hub_url: "http://localhost:4220",
         interval_ms: 60_000,
         machine_name: "t430",
         manifest_path: "/tmp/manifest.json",
         memory: %{enabled: true},
         token: "host-token"
       }}
    end
  end

  defmodule OfflineRuntimeConfig do
    def load_default do
      {:ok,
       %{
         host_id: "host-authoritative",
         hub_url: "http://localhost:4220",
         interval_ms: 60_000,
         machine_name: "t430",
         manifest_path: "/tmp/manifest.json",
         memory: %{enabled: false},
         capture: %{enabled: true, host_id: "spoofed", db_path: "/tmp/capture.db"},
         telemetry: %{enabled: false},
         http_bind: "127.0.0.1",
         http_port: 4222,
         token: "host-token"
       }}
    end
  end

  defmodule FakeConnector do
    def connect(config) do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:connect, config})

      :persistent_term.get(
        {__MODULE__, :connection},
        {:ok,
         %{channel: self(), host_id: "host-1", host_name: "t430", socket: self(), memory: %{}}}
      )
    end
  end

  defmodule FailingConnector do
    def connect(config) do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:connect_failed, config})
      {:error, :hub_down}
    end
  end

  defmodule RejectingMemoryProxy do
    def set_config(_config), do: :ok
    def set_connection(_connection, _config), do: {:error, :fixture_install_failed}
  end

  defmodule FakeMemoryProxy do
    def set_config(config) do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:set_config, config})
      :ok
    end

    def set_channel(channel) do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:set_channel, channel})
      :ok
    end
  end

  defmodule FakeCaptureSupervisor do
    def start_link(config) do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:capture_start, config})
      {:ok, spawn_link(fn -> Process.sleep(:infinity) end)}
    end
  end

  defmodule FailingCaptureSupervisor do
    def start_link(config) do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:capture_start_failed, config})
      {:error, :spool_unavailable}
    end
  end

  defmodule FakeHttpServer do
    def child_spec(_config), do: nil
  end

  defmodule CountingHttpServer do
    def child_spec(config) do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:http_child_spec_called, config})
      nil
    end
  end

  defmodule LiveHttpServer do
    def child_spec(config) do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:http_child_spec_called, config})

      Task.child_spec(fn ->
        send(owner, {:http_child_started, self()})
        Process.sleep(:infinity)
      end)
    end
  end

  defmodule ConfigObservingHttpServer do
    def child_spec(config) do
      owner = :persistent_term.get({__MODULE__, :owner})

      send(owner, {
        :http_memory_config,
        Application.get_env(:backplane_host_agent, :memory_config),
        Application.get_env(:backplane_host_agent, :memory_store),
        Application.get_env(:backplane_host_agent, :memory_host_sync_v2)
      })

      Task.child_spec(fn ->
        send(owner, {:http_ready, self(), config.host_id})
        Process.sleep(:infinity)
      end)
    end
  end

  test "OTP status and crash diagnostics omit config and connection secrets" do
    secret = "status-fixture-sensitive-token"
    config = %Config{token: secret, memory: %{enabled: false}}

    {:ok, worker} =
      Worker.start_link(name: nil, connect?: false, config: config, sync_on_start?: false)

    Process.unlink(worker)
    on_exit(fn -> if Process.alive?(worker), do: GenServer.stop(worker) end)
    ref = Process.monitor(worker)
    refute inspect(:sys.get_status(worker)) =~ secret

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        send(worker, {:unsupported_message, config, %{authorization: secret}})
        assert_receive {:DOWN, ^ref, :process, ^worker, _reason}
      end)

    refute log =~ secret
    refute log =~ "connect_opts"
    refute log =~ "host_id"
    assert log =~ "FunctionClauseError"
  end

  test "callback failures retain exception type and locations without nested payloads" do
    {:ok, worker} =
      Worker.start_link(
        name: nil,
        connect?: false,
        config: %Config{token: "callback-config-fixture-token"},
        channel: self(),
        channel_module: RaisingChannel,
        sync_on_start?: false
      )

    Process.unlink(worker)
    on_exit(fn -> if Process.alive?(worker), do: GenServer.stop(worker) end)
    ref = Process.monitor(worker)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        send(worker, :sync)
        assert_receive {:DOWN, ^ref, :process, ^worker, {%KeyError{term: nil}, stacktrace}}
        assert {RaisingChannel, :push, 3, location} = hd(stacktrace)
        assert is_integer(location[:line])
        assert location[:file]

        assert Enum.all?(stacktrace, fn {_module, _function, arity, _location} ->
                 is_integer(arity)
               end)
      end)

    refute log =~ "nested-exception-fixture-token"
    refute log =~ "callback-config-fixture-token"
    refute log =~ "connect_opts"
    assert log =~ "KeyError"
    assert log =~ "RaisingChannel.push/3"
  end

  test "status returns last sync state" do
    {:ok, pid} = Worker.start_link(name: nil, connect?: false)

    assert %{last_sync: nil, last_error: nil} = GenServer.call(pid, :status)
  end

  test "loads config and connects when started by the release supervisor" do
    :persistent_term.put({FakeConnector, :owner}, self())
    :persistent_term.put({FakeMemoryProxy, :owner}, self())

    on_exit(fn ->
      :persistent_term.erase({FakeConnector, :owner})
      :persistent_term.erase({FakeMemoryProxy, :owner})
    end)

    {:ok, pid} =
      Worker.start_link(
        name: nil,
        config_module: FakeRuntimeConfig,
        connector_module: FakeConnector,
        http_server_module: FakeHttpServer,
        memory_proxy_module: FakeMemoryProxy,
        sync_on_start?: false
      )

    assert_receive {:connect, %{host_id: "host-1", machine_name: "t430", token: "host-token"}}
    assert_receive {:set_channel, ^pid}

    assert %{channel: ^pid, config: %{machine_name: "t430"}, last_error: nil} =
             GenServer.call(pid, :status)
  end

  test "reports local application and only successful worker memory negotiation" do
    :persistent_term.put({FakeConnector, :owner}, self())
    :persistent_term.put({FakeMemoryProxy, :owner}, self())

    :persistent_term.put(
      {FakeConnector, :connection},
      {:ok,
       %{
         channel: start_supervised!({Agent, fn -> nil end}, id: make_ref()),
         memory: %{
           "selected" => "host_memory.v1",
           "memory_partition" => %{
             "memory_space_id" => "30000000-0000-0000-0000-000000000013",
             "scope" => "private",
             "namespace" => "private"
           }
         }
       }}
    )

    on_exit(fn ->
      :persistent_term.erase({FakeConnector, :owner})
      :persistent_term.erase({FakeConnector, :connection})
      :persistent_term.erase({FakeMemoryProxy, :owner})
    end)

    {:ok, pid} =
      Worker.start_link(
        name: nil,
        config_module: FakeRuntimeConfig,
        connector_module: FakeConnector,
        http_server_module: FakeHttpServer,
        memory_proxy_module: FakeMemoryProxy,
        sync_on_start?: false
      )

    state = GenServer.call(pid, :status)
    assert {:ok, _, _} = DateTime.from_iso8601(state.local_settings_applied_at)

    assert %{"selected" => "host_memory.v1", "applied_at" => timestamp, "partitions" => [_]} =
             state.memory_negotiation_report

    assert {:ok, _, _} = DateTime.from_iso8601(timestamp)

    assert state.local_settings_applied_at ==
             GenServer.call(pid, :status).local_settings_applied_at

    GenServer.stop(pid)
  end

  defmodule ProtectedFallback do
    def pending_overlay(_, _) do
      send(self(), :protected_overlay_read)

      {:ok,
       %{
         "upserts" => [%{"id" => "pending", "content" => "protected pending"}],
         "delete_ids" => [],
         "pending_operations" => 1
       }}
    end

    def offline_read(_, _, _) do
      send(self(), :protected_mirror_read)
      {:ok, %{"results" => [%{"id" => "canonical", "content" => "protected mirror"}]}}
    end
  end

  test "worker preserves authentication rejection through transient retries until authenticated recovery" do
    alias Backplane.HostAgent.{MemoryFacade, MemoryProxy}
    MemoryProxy.set_channel(nil)
    :persistent_term.put({FakeConnector, :owner}, self())
    :persistent_term.put({FakeConnector, :connection}, {:error, :unauthorized})

    on_exit(fn ->
      MemoryProxy.set_channel(nil)
      :persistent_term.erase({FakeConnector, :owner})
      :persistent_term.erase({FakeConnector, :connection})
    end)

    pid =
      start_supervised!(
        {Worker,
         name: nil,
         config_module: FakeRuntimeConfig,
         connector_module: FakeConnector,
         http_server_module: FakeHttpServer,
         sync_on_start?: false}
      )

    assert %{last_error: :unauthorized} = GenServer.call(pid, :status)

    context = %{
      agent_id: "codex",
      remote_adapter: MemoryProxy,
      local_adapter: ProtectedFallback,
      edge_adapter: ProtectedFallback
    }

    assert {:error, :unauthorized} = MemoryFacade.call("recall", %{}, context)
    refute_received :protected_overlay_read
    refute_received :protected_mirror_read

    :persistent_term.put({FakeConnector, :connection}, {:error, :socket_timeout})
    send(pid, :connect_retry)
    assert %{last_error: :socket_timeout} = GenServer.call(pid, :status)
    assert {:error, :unauthorized} = MemoryFacade.call("recall", %{}, context)

    channel = start_supervised!({Agent, fn -> nil end})
    :persistent_term.put({FakeConnector, :connection}, {:ok, %{channel: channel, memory: %{}}})
    send(pid, :connect_retry)
    assert %{channel: ^channel, last_error: nil} = GenServer.call(pid, :status)
    assert MemoryProxy.channel() == channel
    Agent.stop(channel)
    # After a successful new authentication, a later outage may use the populated cache again.
    assert {:ok, %{"mode" => "offline"}} =
             MemoryFacade.call("recall", %{"query" => "memory"}, context)

    assert_received :protected_overlay_read
    assert_received :protected_mirror_read
  end

  test "survives startup connect failure and retries" do
    :persistent_term.put({FailingConnector, :owner}, self())

    on_exit(fn ->
      :persistent_term.erase({FailingConnector, :owner})
    end)

    {:ok, pid} =
      Worker.start_link(
        name: nil,
        config_module: FastRuntimeConfig,
        connector_module: FailingConnector,
        http_server_module: FakeHttpServer,
        sync_on_start?: false
      )

    assert_receive {:connect_failed, %{host_id: "host-1", interval_ms: 10}}
    assert Process.alive?(pid)

    assert %{channel: nil, last_error: :hub_down, connect_retry_ref: retry_ref} =
             GenServer.call(pid, :status)

    assert is_reference(retry_ref)
    assert_receive {:connect_failed, %{host_id: "host-1", interval_ms: 10}}, 100
  end

  test "explicit standalone config prepares HTTP before connecting and survives host-first retry" do
    owners = [FakeConnector, FakeMemoryProxy, FakeCaptureSupervisor, ConfigObservingHttpServer]
    Enum.each(owners, &:persistent_term.put({&1, :owner}, self()))
    :persistent_term.put({FakeConnector, :connection}, {:error, :hub_down})

    env_keys = [:memory_config, :memory_store, :memory_host_sync_v2]
    previous_env = Map.new(env_keys, &{&1, Application.fetch_env(:backplane_host_agent, &1)})

    {:ok, config} = OfflineRuntimeConfig.load_default()

    memory_config = %{
      enabled: true,
      bound_scope: "standalone_scope",
      store_name: :standalone_startup_store,
      host_sync_v2: %{enabled: true, development_plaintext: true}
    }

    config = struct!(Config, Map.put(config, :memory, memory_config))
    memory_supervisor = alive_pid()

    on_exit(fn ->
      Enum.each(owners, &:persistent_term.erase({&1, :owner}))
      :persistent_term.erase({FakeConnector, :connection})
      stop_pid(memory_supervisor)

      Enum.each(previous_env, fn
        {key, {:ok, value}} -> Application.put_env(:backplane_host_agent, key, value)
        {key, :error} -> Application.delete_env(:backplane_host_agent, key)
      end)
    end)

    {:ok, worker} =
      Worker.start_link(
        name: nil,
        connect?: true,
        config: config,
        config_module: FakeRuntimeConfig,
        connector_module: FakeConnector,
        capture_supervisor_module: FakeCaptureSupervisor,
        http_server_module: ConfigObservingHttpServer,
        memory_proxy_module: FakeMemoryProxy,
        memory_supervisor: memory_supervisor,
        sync_on_start?: false
      )

    assert_receive {:set_config, ^config}
    assert_receive {:capture_start, %{host_id: "host-authoritative"}}

    assert_receive {:http_memory_config, ^memory_config, :standalone_startup_store,
                    %{enabled: true, development_plaintext: true}}

    assert_receive {:http_ready, http_child, "host-authoritative"}
    assert_receive {:connect, ^config}

    assert %{
             channel: nil,
             config: ^config,
             owns_connection?: true,
             memory_supervisor: ^memory_supervisor,
             capture_supervisor: capture_supervisor,
             http_supervisor: http_supervisor,
             connect_retry_ref: retry_ref,
             last_error: :hub_down
           } = GenServer.call(worker, :status)

    assert is_reference(retry_ref)
    assert Process.alive?(http_child)

    :persistent_term.put(
      {FakeConnector, :connection},
      {:ok,
       %{
         channel: start_supervised!({Agent, fn -> nil end}, id: make_ref()),
         host_id: config.host_id,
         host_name: config.machine_name,
         socket: self(),
         memory: %{"selected" => "host_memory.v2", "partitions" => []}
       }}
    )

    send(worker, :connect_retry)
    assert_receive {:connect, ^config}

    assert %{
             memory_supervisor: ^memory_supervisor,
             capture_supervisor: ^capture_supervisor,
             http_supervisor: ^http_supervisor,
             last_error: nil
           } = GenServer.call(worker, :status)

    assert %{edge_syncer: edge_syncer} = GenServer.call(worker, :status)
    assert is_pid(edge_syncer) and Process.alive?(edge_syncer)
    GenServer.stop(worker)

    refute_receive {:capture_start, _}, 50
    refute_receive {:http_memory_config, _, _, _}, 50
  end

  test "late asynchronous channel replies cannot crash the connection owner" do
    {:ok, state} = Worker.init(connect?: false, sync_on_start?: false)
    message = %Phoenix.SocketClient.Message{event: "phx_reply", payload: %{}, ref: "late"}
    assert {:noreply, ^state} = Worker.handle_info(message, state)
  end

  test "a joined channel is retired if connection installation fails" do
    channel = start_supervised!({Agent, fn -> nil end})
    :persistent_term.put({FakeConnector, :owner}, self())
    :persistent_term.put({FakeConnector, :connection}, {:ok, %{channel: channel}})

    on_exit(fn ->
      :persistent_term.erase({FakeConnector, :owner})
      :persistent_term.erase({FakeConnector, :connection})
    end)

    worker =
      start_supervised!(
        {Worker,
         name: nil,
         connect?: true,
         config_module: FakeRuntimeConfig,
         connector_module: FakeConnector,
         http_server_module: FakeHttpServer,
         memory_proxy_module: RejectingMemoryProxy,
         sync_on_start?: false}
      )

    assert_receive {:connect, _}
    assert %{channel: nil, last_error: :fixture_install_failed} = GenServer.call(worker, :status)
    refute Process.alive?(channel)
  end

  test "obsolete retry timers cannot replace a newer connection" do
    {:ok, state} = Worker.init(connect?: false, sync_on_start?: false, channel: self())

    assert {:noreply, ^state} =
             Worker.handle_info({:timeout, make_ref(), :connect_retry}, state)
  end

  test "a failed owned channel is retired once and obsolete loss notifications are ignored" do
    channel = start_supervised!({Agent, fn -> nil end})
    ref = Process.monitor(channel)

    {:ok, state} =
      Worker.init(
        connect?: false,
        sync_on_start?: false,
        owns_connection?: true,
        channel: channel
      )

    state = %{state | channel_monitor_ref: ref}
    assert {:noreply, next} = Worker.handle_info({:memory_connection_lost, channel}, state)
    refute Process.alive?(channel)
    assert next.channel == nil
    assert next.channel_monitor_ref == nil
    assert is_reference(next.connect_retry_ref)
    assert {:noreply, ^next} = Worker.handle_info({:memory_connection_lost, channel}, next)
    Process.cancel_timer(next.connect_retry_ref)
  end

  test "server channel failure automatically reconnects shared providers and the edge syncer" do
    alias Backplane.HostAgent.{AgentChannel, MemoryProxy}
    alias Backplane.HostAgent.Memory.Edge.Syncer
    start_supervised!({Registry, keys: :unique, name: __MODULE__.ReconnectRegistry})
    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    args = {nil, nil, "host_agent:reconnect-fixture", %{}, __MODULE__.ReconnectRegistry}
    {:ok, first} = DynamicSupervisor.start_child(supervisor, {AgentChannel, args})
    {:ok, config} = StructRuntimeConfig.load_default()
    config = %{config | interval_ms: 20}

    connection = %{
      channel: first,
      host_id: "host-1",
      socket: nil,
      memory: %{"selected" => "host_memory.v2", "partitions" => []}
    }

    :persistent_term.put({FakeConnector, :owner}, self())
    :persistent_term.put({FakeConnector, :connection}, {:ok, connection})

    on_exit(fn ->
      :persistent_term.erase({FakeConnector, :owner})
      :persistent_term.erase({FakeConnector, :connection})
      MemoryProxy.set_channel(nil)
    end)

    worker =
      start_supervised!(
        {Worker,
         name: nil,
         connect?: true,
         config: config,
         connector_module: FakeConnector,
         http_server_module: FakeHttpServer,
         sync_on_start?: false}
      )

    assert_receive {:connect, _}
    assert %{edge_syncer: edge, channel_monitor_ref: old_ref} = GenServer.call(worker, :status)
    assert MemoryProxy.channel() == first
    assert Syncer.status(edge).channel == first

    # Prepare the next authenticated channel before notifying the first of its
    # server-side closure; no direct connect_retry message drives this recovery.
    next_args = {nil, nil, "host_agent:reconnect-next", %{}, __MODULE__.ReconnectRegistry}
    {:ok, second} = DynamicSupervisor.start_child(supervisor, {AgentChannel, next_args})
    :persistent_term.put({FakeConnector, :connection}, {:ok, %{connection | channel: second}})
    send(first, %Phoenix.SocketClient.Message{event: "phx_error", payload: %{}})
    assert_receive {:connect, _}, 1_000
    assert %{channel: ^second, edge_syncer: ^edge} = GenServer.call(worker, :status)
    assert MemoryProxy.channel() == second
    assert Syncer.status(edge).channel == second
    assert DynamicSupervisor.count_children(supervisor).active == 1
    send(worker, {:DOWN, old_ref, :process, first, :normal})
    assert %{channel: ^second} = GenServer.call(worker, :status)
    refute_receive {:connect, _}, 50

    GenServer.stop(worker)
    refute Process.alive?(second)
    assert MemoryProxy.channel() == nil
  end

  test "v2 selection starts an edge syncer at the configured interval and v1 reconnect stops it" do
    :persistent_term.put({FakeConnector, :owner}, self())
    :persistent_term.put({FakeMemoryProxy, :owner}, self())
    first_channel = start_supervised!({Agent, fn -> nil end})

    :persistent_term.put(
      {FakeConnector, :connection},
      {:ok,
       %{
         channel: first_channel,
         host_id: "host-1",
         host_name: "t430",
         socket: self(),
         memory: %{"selected" => "host_memory.v2", "partitions" => []}
       }}
    )

    on_exit(fn ->
      :persistent_term.erase({FakeConnector, :owner})
      :persistent_term.erase({FakeConnector, :connection})
      :persistent_term.erase({FakeMemoryProxy, :owner})
    end)

    {:ok, worker} =
      Worker.start_link(
        name: nil,
        connect?: true,
        config_module: StructRuntimeConfig,
        connector_module: FakeConnector,
        http_server_module: FakeHttpServer,
        memory_proxy_module: FakeMemoryProxy,
        sync_on_start?: false
      )

    assert_receive {:connect, %Config{}}
    assert %{edge_syncer: edge_syncer} = GenServer.call(worker, :status)
    assert is_pid(edge_syncer) and Process.alive?(edge_syncer)

    assert %{
             poll_interval_ms: 1_000,
             mirror_opts: [config: %{enabled: true, development_plaintext: true}]
           } =
             Backplane.HostAgent.Memory.Edge.Syncer.status(edge_syncer)

    :persistent_term.put(
      {FakeConnector, :connection},
      {:ok,
       %{
         channel: start_supervised!({Agent, fn -> nil end}, id: make_ref()),
         host_id: "host-1",
         host_name: "t430",
         socket: self(),
         memory: %{"selected" => "host_memory.v1"}
       }}
    )

    send(worker, :connect_retry)
    assert_receive {:connect, _}
    assert %{edge_syncer: nil} = GenServer.call(worker, :status)
    refute Process.alive?(edge_syncer)
    GenServer.stop(worker)
  end

  test "normal worker shutdown promptly terminates its linked edge syncer" do
    :persistent_term.put({FakeConnector, :owner}, self())
    :persistent_term.put({FakeMemoryProxy, :owner}, self())

    :persistent_term.put(
      {FakeConnector, :connection},
      {:ok,
       %{
         channel: start_supervised!({Agent, fn -> nil end}, id: make_ref()),
         host_id: "host-1",
         host_name: "t430",
         socket: self(),
         memory: %{"selected" => "host_memory.v2", "partitions" => []}
       }}
    )

    on_exit(fn ->
      :persistent_term.erase({FakeConnector, :owner})
      :persistent_term.erase({FakeConnector, :connection})
      :persistent_term.erase({FakeMemoryProxy, :owner})
    end)

    {:ok, worker} =
      Worker.start_link(
        name: nil,
        connect?: false,
        config_module: FakeRuntimeConfig,
        connector_module: FakeConnector,
        http_server_module: FakeHttpServer,
        memory_proxy_module: FakeMemoryProxy,
        sync_on_start?: false
      )

    send(worker, :connect_retry)
    assert_receive {:connect, _}
    assert %{edge_syncer: edge_syncer} = GenServer.call(worker, :status)
    ref = Process.monitor(edge_syncer)
    assert :ok = GenServer.stop(worker, :normal, 1_000)
    assert_receive {:DOWN, ^ref, :process, ^edge_syncer, :normal}, 1_000
  end

  test "starts and retains capture and HTTP while the hub remains offline" do
    owners = [FailingConnector, FakeMemoryProxy, FakeCaptureSupervisor, LiveHttpServer]
    Enum.each(owners, &:persistent_term.put({&1, :owner}, self()))

    on_exit(fn -> Enum.each(owners, &:persistent_term.erase({&1, :owner})) end)

    {:ok, worker} =
      Worker.start_link(
        name: nil,
        config_module: OfflineRuntimeConfig,
        connector_module: FailingConnector,
        capture_supervisor_module: FakeCaptureSupervisor,
        http_server_module: LiveHttpServer,
        memory_proxy_module: FakeMemoryProxy,
        sync_on_start?: false
      )

    assert_receive first_message
    assert {:set_config, %{host_id: "host-authoritative"}} = first_message

    assert_receive second_message

    assert {:capture_start,
            %{enabled: true, host_id: "host-authoritative", db_path: "/tmp/capture.db"}} =
             second_message

    assert_receive third_message
    assert {:http_child_spec_called, %{host_id: "host-authoritative"}} = third_message
    assert_receive {:connect_failed, %{host_id: "host-authoritative"}}
    assert_receive {:http_child_started, http_child}

    assert %{
             capture_supervisor: capture_supervisor,
             http_supervisor: http_supervisor,
             config: %{host_id: "host-authoritative"},
             last_error: :hub_down
           } = GenServer.call(worker, :status)

    assert Process.alive?(capture_supervisor)
    assert Process.alive?(http_supervisor)
    assert Process.alive?(http_child)

    send(worker, :connect_retry)

    assert_receive {:set_config, %{host_id: "host-authoritative"}}
    assert_receive {:connect_failed, %{host_id: "host-authoritative"}}
    refute_receive {:capture_start, _}, 50
    refute_receive {:http_child_spec_called, _}, 50

    assert %{
             capture_supervisor: ^capture_supervisor,
             http_supervisor: ^http_supervisor
           } = GenServer.call(worker, :status)
  end

  test "reconnect success reuses the capture supervisor started while offline" do
    owners = [FakeConnector, FakeMemoryProxy, FakeCaptureSupervisor, FakeHttpServer]
    Enum.each(owners, &:persistent_term.put({&1, :owner}, self()))

    on_exit(fn -> Enum.each(owners, &:persistent_term.erase({&1, :owner})) end)

    {:ok, worker} =
      Worker.start_link(
        name: nil,
        connect?: false,
        config_module: OfflineRuntimeConfig,
        connector_module: FakeConnector,
        capture_supervisor_module: FakeCaptureSupervisor,
        http_server_module: FakeHttpServer,
        memory_proxy_module: FakeMemoryProxy,
        sync_on_start?: false
      )

    send(worker, :connect_retry)

    assert_receive {:capture_start, %{host_id: "host-authoritative"}}
    assert_receive {:connect, %{host_id: "host-authoritative"}}

    assert %{capture_supervisor: capture_supervisor, channel: ^worker} =
             GenServer.call(worker, :status)

    send(worker, :connect_retry)
    assert_receive {:connect, %{host_id: "host-authoritative"}}
    refute_receive {:capture_start, _}, 50

    assert %{capture_supervisor: ^capture_supervisor, channel: ^worker} =
             GenServer.call(worker, :status)
  end

  test "classifies capture startup failures without attempting a connection" do
    owners = [FailingConnector, FakeMemoryProxy, FailingCaptureSupervisor]
    Enum.each(owners, &:persistent_term.put({&1, :owner}, self()))

    on_exit(fn -> Enum.each(owners, &:persistent_term.erase({&1, :owner})) end)

    {:ok, worker} =
      Worker.start_link(
        name: nil,
        config_module: OfflineRuntimeConfig,
        connector_module: FailingConnector,
        capture_supervisor_module: FailingCaptureSupervisor,
        http_server_module: FakeHttpServer,
        memory_proxy_module: FakeMemoryProxy,
        sync_on_start?: false
      )

    assert_receive {:capture_start_failed, %{host_id: "host-authoritative"}}
    refute_receive {:connect_failed, _}, 50

    assert %{last_error: {:capture_start_failed, :spool_unavailable}} =
             GenServer.call(worker, :status)
  end

  test "reconnect reuses alive side supervisors" do
    :persistent_term.put({FakeConnector, :owner}, self())
    :persistent_term.put({FakeMemoryProxy, :owner}, self())
    :persistent_term.put({CountingHttpServer, :owner}, self())

    memory_supervisor = alive_pid()
    http_supervisor = alive_pid()

    on_exit(fn ->
      :persistent_term.erase({FakeConnector, :owner})
      :persistent_term.erase({FakeMemoryProxy, :owner})
      :persistent_term.erase({CountingHttpServer, :owner})
      stop_pid(memory_supervisor)
      stop_pid(http_supervisor)
    end)

    {:ok, pid} =
      Worker.start_link(
        name: nil,
        connect?: false,
        config_module: ReconnectRuntimeConfig,
        connector_module: FakeConnector,
        http_server_module: CountingHttpServer,
        memory_proxy_module: FakeMemoryProxy,
        memory_supervisor: memory_supervisor,
        http_supervisor: http_supervisor,
        owns_connection?: true,
        sync_on_start?: false
      )

    send(pid, :connect_retry)

    assert_receive {:connect, %{memory: %{enabled: true}}}
    assert_receive {:set_channel, ^pid}
    refute_receive {:http_child_spec_called, _config}, 50

    assert %{
             channel: ^pid,
             memory_supervisor: ^memory_supervisor,
             http_supervisor: ^http_supervisor,
             last_error: nil
           } = GenServer.call(pid, :status)
  end

  @tag :tmp_dir
  test "reconnect replaces the existing sync timer instead of leaving it pending", %{
    tmp_dir: tmp_dir
  } do
    config =
      config(tmp_dir)
      |> Map.put(:interval_ms, 60_000)
      |> put_in([:memory, :enabled], false)
      |> put_in([:telemetry, :enabled], false)

    :persistent_term.put({FakeChannel, :owner}, self())
    :persistent_term.put({FakeConnector, :owner}, self())
    :persistent_term.put({FakeMemoryProxy, :owner}, self())

    on_exit(fn ->
      :persistent_term.erase({FakeChannel, :owner})
      :persistent_term.erase({FakeConnector, :owner})
      :persistent_term.erase({FakeMemoryProxy, :owner})
    end)

    {:ok, pid} =
      Worker.start_link(
        name: nil,
        connect?: false,
        channel: self(),
        channel_module: FakeChannel,
        config: config,
        config_module: FakeRuntimeConfig,
        connector_module: FakeConnector,
        http_server_module: FakeHttpServer,
        memory_proxy_module: FakeMemoryProxy,
        desired: %{"skills" => []},
        installer_module: FakeInstaller,
        owns_connection?: true
      )

    assert_receive {:push, "heartbeat", %{"machine_name" => "t430"}}
    assert_receive {:push, "sync_result", %{"status" => "synced"}}

    assert %{sync_timer_ref: old_timer_ref} = GenServer.call(pid, :status)
    assert is_reference(old_timer_ref)

    send(pid, :connect_retry)

    assert_receive {:connect, %{host_id: "host-1"}}
    assert_receive {:set_channel, ^pid}

    assert %{sync_timer_ref: new_timer_ref} = GenServer.call(pid, :status)
    assert is_reference(new_timer_ref)
    assert new_timer_ref != old_timer_ref
    assert Process.cancel_timer(old_timer_ref) == false
  end

  @tag :tmp_dir
  test "schedules an immediate sync after startup", %{tmp_dir: tmp_dir} do
    config = config(tmp_dir)
    :persistent_term.put({FakeChannel, :owner}, self())

    on_exit(fn ->
      :persistent_term.erase({FakeChannel, :owner})
    end)

    {:ok, pid} =
      Worker.start_link(
        name: nil,
        connect?: false,
        channel: self(),
        channel_module: FakeChannel,
        config: Map.put(config, :interval_ms, 60_000),
        desired: %{"skills" => []},
        installer_module: FakeInstaller
      )

    assert_receive {:push, "heartbeat", %{"machine_name" => "t430"}}
    assert_receive {:push, "sync_result", %{"status" => "synced", "results" => []}}

    assert %{last_sync: %DateTime{}, last_error: nil, sync_timer_ref: timer_ref} =
             GenServer.call(pid, :status)

    assert is_reference(timer_ref)
  end

  @tag :tmp_dir
  test "run_once uses injected desired state and installs planned skills", %{tmp_dir: tmp_dir} do
    config = config(tmp_dir)

    desired = %{
      "skills" => [
        %{
          "name" => "Repo Review",
          "slug" => "repo-review",
          "version" => "1.0.0",
          "checksum" => "sha256:a",
          "targets" => ["agents"]
        }
      ]
    }

    state = state(config, desired: desired)

    assert {:ok, updated} = Worker.run_once(state)
    assert %{last_sync: %DateTime{}, last_error: nil} = updated

    assert_receive {:push, "config_report",
                    %{
                      "agent" => %{
                        "host_id" => "host-1",
                        "machine_name" => "t430",
                        "token" => "REDACTED"
                      },
                      "memory" => %{"bound_scope" => "proj_local"},
                      "telemetry" => %{"dir" => telemetry_dir},
                      "targets" => [%{"name" => "agents", "path" => ^tmp_dir}]
                    }}

    assert telemetry_dir == Path.join(tmp_dir, "telemetry")
    assert_receive {:push, "heartbeat", %{"machine_name" => "t430"}}
    refute_received {:push, "get_desired", %{}}

    assert_receive {:install, desired_skill, install_config}
    assert desired_skill["slug"] == "repo-review"
    assert_install_config(install_config, config)

    assert_receive {:push, "sync_result", %{"status" => "synced", "results" => [result]}}

    assert %{
             "skill_name" => "Repo Review",
             "skill_slug" => "repo-review",
             "status" => "installed",
             "checksum" => "sha256:a",
             "targets" => ["agents"]
           } = result

    assert {:ok, manifest} = Manifest.read(config.manifest_path, config.machine_name)

    assert [
             %{
               checksum: "sha256:a",
               name: "Repo Review",
               owned: true,
               slug: "repo-review",
               targets: ["agents"],
               version: "1.0.0"
             }
           ] = manifest.skills

    assert {:ok, _updated_again} = Worker.run_once(state)

    refute_received {:install, _skill, _config}
    assert_receive {:push, "heartbeat", %{"machine_name" => "t430"}}
    assert_receive {:push, "sync_result", %{"status" => "synced", "results" => [noop_result]}}
    assert %{"skill_slug" => "repo-review", "status" => "noop"} = noop_result
  end

  @tag :tmp_dir
  test "run_once fetches desired state when not injected", %{tmp_dir: tmp_dir} do
    config = config(tmp_dir)

    desired = %{
      "skills" => [
        %{
          "name" => "Repo Review",
          "slug" => "repo-review",
          "checksum" => "sha256:a",
          "targets" => ["agents"]
        }
      ]
    }

    Process.put({FakeChannel, "get_desired"}, {:ok, desired})

    assert {:ok, _updated} = Worker.run_once(state(config))

    assert_receive {:push, "heartbeat", %{"machine_name" => "t430"}}
    assert_receive {:push, "get_desired", %{}}
    assert_receive {:install, desired_skill, install_config}
    assert desired_skill["slug"] == "repo-review"
    assert_install_config(install_config, config)
    assert_receive {:push, "sync_result", %{"status" => "synced"}}
  end

  @tag :tmp_dir
  test "run_once does not update manifest when sync_result reporting fails", %{tmp_dir: tmp_dir} do
    config = config(tmp_dir)
    Process.put({FakeChannel, "sync_result"}, {:error, :socket_down})

    desired = %{
      "skills" => [
        %{
          "name" => "Repo Review",
          "slug" => "repo-review",
          "checksum" => "sha256:a",
          "targets" => ["agents"]
        }
      ]
    }

    assert {:error, :socket_down, updated} = Worker.run_once(state(config, desired: desired))
    assert updated.last_error == :socket_down

    assert_receive {:install, _desired_skill, install_config}
    assert_install_config(install_config, config)
    assert_receive {:push, "sync_result", %{"status" => "synced"}}

    assert {:ok, manifest} = Manifest.read(config.manifest_path, config.machine_name)
    assert manifest.skills == []
  end

  @tag :tmp_dir
  test "run_once records channel exits instead of crashing", %{tmp_dir: tmp_dir} do
    config = config(tmp_dir)

    assert {:error, {:channel_exit, :shutdown}, updated} =
             Worker.run_once(%{state(config) | channel_module: ExitingChannel})

    assert updated.last_error == {:channel_exit, :shutdown}
    assert_receive {:push, "config_report", %{"agent" => %{"machine_name" => "t430"}}}
  end

  @tag :tmp_dir
  test "owned worker clears dead channel and schedules reconnect on not_connected", %{
    tmp_dir: tmp_dir
  } do
    config = config(tmp_dir)
    Process.put({FakeChannel, "sync_result"}, {:error, :not_connected})

    state =
      config
      |> state(desired: %{"skills" => []})
      |> Map.merge(%{
        connect_retry_ref: nil,
        connect_opts: [],
        owns_connection?: true,
        sync_timer_ref: nil
      })

    assert {:error, :not_connected, updated} = Worker.run_once(state)

    assert updated.channel == nil
    assert updated.last_error == :not_connected
    assert is_reference(updated.connect_retry_ref)
  end

  @tag :tmp_dir
  test "run_once stores the targets actually installed in the manifest", %{tmp_dir: tmp_dir} do
    config = config(tmp_dir)
    Process.put(FakeInstaller, {:ok, ["agents"]})

    desired = %{
      "skills" => [
        %{
          "name" => "Repo Review",
          "slug" => "repo-review",
          "checksum" => "sha256:a",
          "targets" => ["agents", "commands"]
        }
      ]
    }

    assert {:ok, _updated} = Worker.run_once(state(config, desired: desired))

    assert {:ok, manifest} = Manifest.read(config.manifest_path, config.machine_name)
    assert [%{slug: "repo-review", targets: ["agents"]}] = manifest.skills
  end

  @tag :tmp_dir
  test "run_once records manifest read errors instead of crashing", %{tmp_dir: tmp_dir} do
    config = config(tmp_dir)
    File.write!(config.manifest_path, "{not-json")

    assert {:error, {:manifest_read_error, _message}, updated} =
             Worker.run_once(state(config, desired: %{"skills" => []}))

    assert {:manifest_read_error, _message} = updated.last_error
  end

  @tag :tmp_dir
  test "run_once records valid JSON manifest shape errors instead of crashing", %{
    tmp_dir: tmp_dir
  } do
    config = config(tmp_dir)
    File.write!(config.manifest_path, "[]")

    assert {:error, {:manifest_read_error, _message}, updated} =
             Worker.run_once(state(config, desired: %{"skills" => []}))

    assert {:manifest_read_error, _message} = updated.last_error
  end

  @tag :tmp_dir
  test "run_once records non-object manifest JSON errors instead of crashing", %{tmp_dir: tmp_dir} do
    for json <- ["null", "1", "\"value\"", "true"] do
      config = config(Path.join(tmp_dir, Base.encode16(json)))
      File.mkdir_p!(Path.dirname(config.manifest_path))
      File.write!(config.manifest_path, json)

      assert {:error, {:manifest_read_error, _message}, updated} =
               Worker.run_once(state(config, desired: %{"skills" => []}))

      assert {:manifest_read_error, _message} = updated.last_error
    end
  end

  @tag :tmp_dir
  test "run_once returns noop and removes manifest-owned stale skills", %{tmp_dir: tmp_dir} do
    config = config(tmp_dir)

    write_manifest(config.manifest_path, [
      %{name: "Manual", slug: "manual", checksum: "sha256:m", targets: ["agents"], owned: false},
      %{
        name: "Old Skill",
        slug: "old-skill",
        checksum: "sha256:o",
        targets: ["agents"],
        owned: true
      }
    ])

    desired = %{
      "skills" => [
        %{
          "name" => "Manual",
          "slug" => "manual",
          "checksum" => "sha256:m",
          "targets" => ["agents"]
        }
      ]
    }

    assert {:ok, _updated} = Worker.run_once(state(config, desired: desired))

    refute_received {:install, _skill, _config}
    assert_receive {:remove, removed_skill, ^config}
    assert removed_skill.slug == "old-skill"

    assert_receive {:push, "sync_result", %{"results" => results}}

    assert [
             %{"skill_slug" => "manual", "status" => "noop"},
             %{"skill_slug" => "old-skill", "status" => "removed"}
           ] = results

    assert {:ok, manifest} = Manifest.read(config.manifest_path, config.machine_name)
    assert [%{owned: false, slug: "manual"}] = manifest.skills
  end

  @tag :tmp_dir
  test "run_once retains manifest targets not removed by a partial remove", %{tmp_dir: tmp_dir} do
    config = config(tmp_dir)
    Process.put({FakeInstaller, :remove}, {:ok, ["agents"]})

    write_manifest(config.manifest_path, [
      %{
        name: "Old Skill",
        slug: "old-skill",
        checksum: "sha256:o",
        targets: ["agents", "commands"],
        owned: true
      }
    ])

    assert {:ok, _updated} = Worker.run_once(state(config, desired: %{"skills" => []}))

    assert_receive {:remove, removed_skill, ^config}
    assert removed_skill.slug == "old-skill"
    assert_receive {:push, "sync_result", %{"results" => [%{"targets" => ["agents"]}]}}

    assert {:ok, manifest} = Manifest.read(config.manifest_path, config.machine_name)
    assert [%{owned: true, slug: "old-skill", targets: ["commands"]}] = manifest.skills
  end

  @tag :tmp_dir
  test "run_once marks installer failures and records last_error", %{tmp_dir: tmp_dir} do
    config = config(tmp_dir)
    Process.put(FakeInstaller, {:error, :download_missing})

    desired = %{
      "skills" => [
        %{
          "name" => "Repo Review",
          "slug" => "repo-review",
          "checksum" => "sha256:a",
          "targets" => ["agents"]
        }
      ]
    }

    assert {:error, "download_missing", updated} =
             Worker.run_once(state(config, desired: desired))

    assert updated.last_sync == nil
    assert updated.last_error == "download_missing"

    assert_receive {:push, "sync_result", %{"status" => "failed", "results" => [result]}}

    assert %{"skill_slug" => "repo-review", "status" => "failed", "error" => "download_missing"} =
             result
  end

  defp state(config, opts \\ []) do
    %{
      channel: self(),
      channel_module: FakeChannel,
      config: config,
      desired: Keyword.get(opts, :desired),
      installer_module: FakeInstaller,
      last_error: nil,
      last_sync: nil
    }
  end

  defp config(tmp_dir) do
    %{
      host_id: "host-1",
      hub_url: "http://localhost:4220",
      interval_ms: 60_000,
      machine_name: "t430",
      manifest_path: Path.join(tmp_dir, "manifest.json"),
      token: "host-token",
      work_dir: tmp_dir,
      http_bind: "127.0.0.1",
      http_port: 4222,
      memory: %{
        enabled: true,
        db_path: Path.join(tmp_dir, "memory/host_agent_memory.db"),
        bound_scope: "proj_local",
        local_ttl_days: 90,
        sync_interval_ms: 5_000,
        sync_batch_size: 50,
        max_attempts: 5,
        tombstone_relearn: "block"
      },
      telemetry: %{
        enabled: true,
        dir: Path.join(tmp_dir, "telemetry"),
        sync_interval_ms: 10_000,
        sync_batch_size: 100,
        retention_days: 14
      },
      targets: [%{name: "agents", runtime: "agent-skills", path: tmp_dir, enabled: true}]
    }
  end

  defp write_manifest(path, skills) do
    File.write!(path, Jason.encode!(%{schema_version: 1, machine_name: "t430", skills: skills}))
  end

  defp assert_install_config(install_config, config) do
    assert install_config.machine_name == config.machine_name
    assert install_config.manifest_path == config.manifest_path
    assert install_config.targets == config.targets
    assert install_config.channel == self()
    assert install_config.channel_module == FakeChannel
  end

  defp alive_pid do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  defp stop_pid(pid) do
    if Process.alive?(pid), do: send(pid, :stop)
  end
end

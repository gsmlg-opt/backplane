defmodule Backplane.HostAgent.ConnectorTest do
  use ExUnit.Case, async: false

  alias Backplane.HostAgent.{Connector, MemoryTestFixtures}
  alias Backplane.HostAgent.{MemoryFacade, MemoryProxy}

  defmodule RejectUpgrade do
    def init(opts), do: opts
    def call(conn, status), do: Plug.Conn.send_resp(conn, status, "rejected")
  end

  defmodule ObservedSocketClient do
    def start_link(opts) do
      result = Phoenix.SocketClient.start_link(opts)

      case result do
        {:ok, socket} ->
          send(:persistent_term.get({__MODULE__, :owner}), {:socket_started, socket})

        _ ->
          :ok
      end

      result
    end

    defdelegate connect(socket), to: Phoenix.SocketClient
    defdelegate connected?(socket), to: Phoenix.SocketClient
    defdelegate connection_info(socket), to: Phoenix.SocketClient
    defdelegate disconnect(socket), to: Phoenix.SocketClient
  end

  defmodule SlowUpgrade do
    def init(opts), do: opts

    def call(conn, _) do
      Process.sleep(6_000)
      Plug.Conn.send_resp(conn, 503, "late")
    end
  end

  defmodule ScriptedSocketClient do
    def start_link(_opts) do
      snapshots = Process.get(:socket_snapshots)
      {:ok, socket} = Agent.start_link(fn -> snapshots end)
      send(self(), {:socket_started, socket})
      {:ok, socket}
    end

    def connected?(_), do: false

    def connect(socket) do
      send(self(), {:connect, socket})
      :ok
    end

    def connection_info(socket) do
      Agent.get_and_update(socket, fn
        [snapshot] -> {snapshot, [snapshot]}
        [snapshot | rest] -> {snapshot, rest}
      end)
    end

    def disconnect(socket) do
      send(self(), {:disconnect, socket})
      :ok
    end
  end

  defmodule FailedCleanupClient do
    defdelegate start_link(opts), to: ScriptedSocketClient
    defdelegate connect(socket), to: ScriptedSocketClient
    defdelegate connected?(socket), to: ScriptedSocketClient
    defdelegate connection_info(socket), to: ScriptedSocketClient
    def disconnect(_socket), do: exit(:cleanup_connection_lost)
  end

  defmodule ScriptedJoin do
    def join(socket, topic, _payload) do
      send(self(), {:join, socket, topic})
      Process.get(:join_result, {:ok, %{}, self()})
    end
  end

  @moduletag :tmp_dir

  setup do
    keys = [:socket_client_module, :socket_channel_join_module]
    previous = Map.new(keys, &{&1, Application.get_env(:backplane_host_agent, &1)})

    telemetry =
      Map.new([:enabled, :sampler_rate], &{&1, Phoenix.SocketClient.Telemetry.get_config(&1)})

    :persistent_term.put({ObservedSocketClient, :owner}, self())
    Application.put_env(:backplane_host_agent, :socket_client_module, ObservedSocketClient)
    MemoryProxy.set_channel(nil)

    on_exit(fn ->
      MemoryProxy.set_channel(nil)
      Phoenix.SocketClient.Telemetry.update_config(telemetry)
      :persistent_term.erase({ObservedSocketClient, :owner})

      Enum.each(previous, fn {key, value} ->
        if is_nil(value),
          do: Application.delete_env(:backplane_host_agent, key),
          else: Application.put_env(:backplane_host_agent, key, value)
      end)
    end)

    :ok
  end

  for status <- [401, 403], telemetry <- [:disabled, :unsampled] do
    @tag :authoritative_connection
    @tag :prompt_rejection_cleanup
    test "real HTTP #{status} rejection is fail-closed with telemetry #{telemetry}", %{
      tmp_dir: dir
    } do
      fixture = MemoryTestFixtures.start!(dir)

      Phoenix.SocketClient.Telemetry.update_config(%{
        enabled: unquote(telemetry) != :disabled,
        sampler_rate: 0.0
      })

      server = start_supervised!({Gaoxy.HTTP, plug: {RejectUpgrade, unquote(status)}, port: 0})
      %{local: {:ok, {_ip, port}}} = Gaoxy.info(server, :http)
      MemoryProxy.set_config(config(port))
      assert_authorized_offline(fixture)
      started = System.monotonic_time(:millisecond)

      assert {:error, {:reconnect_failed, :unauthorized}} =
               MemoryProxy.call("recall", %{"query" => "memory"}, agent_id: "codex")

      assert System.monotonic_time(:millisecond) - started < 2_000
      assert_receive {:socket_started, socket}
      refute Process.alive?(socket)

      assert {:error, :unauthorized} =
               MemoryFacade.call(
                 "recall",
                 %{"query" => "memory"},
                 MemoryTestFixtures.context(fixture)
               )

      assert {:error, :unauthorized} =
               MemoryFacade.call("list", %{}, MemoryTestFixtures.context(fixture))

      refute_received {:socket_started, _}
    end
  end

  @tag :authoritative_connection
  test "real refused connection retains authorized mirror access and retires the failed socket",
       %{tmp_dir: dir} do
    fixture = MemoryTestFixtures.start!(dir)
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, {_address, port}} = :inet.sockname(listener)
    :ok = :gen_tcp.close(listener)
    MemoryProxy.set_config(config(port))

    assert {:error, {:reconnect_failed, reason}} =
             MemoryProxy.call("recall", %{"query" => "memory"}, agent_id: "codex")

    assert MemoryFacade.transport_error?({:reconnect_failed, reason})
    assert_receive {:socket_started, socket}
    refute Process.alive?(socket)
    assert_authorized_offline(fixture)
  end

  @tag :authoritative_connection
  test "real opening timeout retains authorized mirror access and cancels the failed socket", %{
    tmp_dir: dir
  } do
    fixture = MemoryTestFixtures.start!(dir)
    server = start_supervised!({Gaoxy.HTTP, plug: {SlowUpgrade, []}, port: 0})
    %{local: {:ok, {_ip, port}}} = Gaoxy.info(server, :http)
    MemoryProxy.set_config(config(port))

    assert {:error, {:reconnect_failed, :socket_timeout}} =
             MemoryProxy.call("recall", %{"query" => "memory"}, agent_id: "codex")

    assert_receive {:socket_started, socket}
    refute Process.alive?(socket)
    assert_authorized_offline(fixture)
  end

  @tag :authoritative_connection
  test "a superseded rejection cannot overwrite the latest connected attempt" do
    old = make_ref()
    new = make_ref()

    scripted([
      %{attempt_ref: old, status: :disconnected, last_error: {:unexpected_status, 403}},
      %{attempt_ref: new, status: :connected, last_error: nil}
    ])

    assert {:ok, %{socket: socket, channel: channel}} = Connector.connect(config(1))
    assert channel == self()
    assert Process.alive?(socket)
    assert_received {:join, ^socket, "host_agent:revoked-host"}
    assert_received {:connect, ^socket}
    refute_received {:connect, ^socket}
    Agent.stop(socket)
  end

  @tag :authoritative_connection
  test "cancellation and join rejection retire their socket without claiming authentication rejection" do
    ref = make_ref()
    scripted([%{attempt_ref: ref, status: :disconnected, last_error: :cancelled}])
    assert {:error, :not_connected} = Connector.connect(config(1))
    assert_receive {:socket_started, cancelled}
    assert_received {:disconnect, ^cancelled}
    refute Process.alive?(cancelled)
    refute_received {:join, _, _}

    scripted([%{attempt_ref: make_ref(), status: :connected, last_error: nil}])
    Process.put(:join_result, {:error, :join_denied})
    assert {:error, :join_denied} = Connector.connect(config(1))
    assert_receive {:socket_started, rejected}
    assert_received {:disconnect, ^rejected}
    refute Process.alive?(rejected)
  end

  @tag :authoritative_connection
  test "cleanup failure preserves the primary rejection and still retires the socket" do
    scripted([
      %{attempt_ref: make_ref(), status: :disconnected, last_error: {:unexpected_status, 401}}
    ])

    Application.put_env(:backplane_host_agent, :socket_client_module, FailedCleanupClient)
    assert {:error, :unauthorized} = Connector.connect(config(1))
    assert_receive {:socket_started, socket}
    refute Process.alive?(socket)
    refute_received {:join, _, _}
  end

  defp scripted(snapshots) do
    Process.put(:socket_snapshots, snapshots)
    Application.put_env(:backplane_host_agent, :socket_client_module, ScriptedSocketClient)
    Application.put_env(:backplane_host_agent, :socket_channel_join_module, ScriptedJoin)
  end

  defp config(port),
    do: %{
      host_id: "revoked-host",
      token: "revoked-test-token",
      socket_url: "ws://127.0.0.1:#{port}/host-agent/socket/websocket"
    }

  defp assert_authorized_offline(fixture) do
    assert {:ok, %{"mode" => "offline", "consistency" => "bounded_stale", "results" => results}} =
             MemoryFacade.call(
               "recall",
               %{"query" => "memory"},
               MemoryTestFixtures.context(fixture)
             )

    assert Enum.sort(Enum.map(results, &(&1["canonical_id"] || &1["id"]))) ==
             Enum.sort([fixture.canonical_id, fixture.pending_id])

    assert Enum.any?(results, &(&1["content"] == "protected mirror memory"))

    assert Enum.any?(
             results,
             &(&1["content"] == "protected pending memory" and &1["provisional"] == true)
           )
  end

  test "rejects a missing host identity before opening a socket" do
    assert {:error, {:missing_required_config, [:host_id]}} = Connector.connect(%{})
  end
end

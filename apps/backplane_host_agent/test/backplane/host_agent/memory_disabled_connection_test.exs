defmodule Backplane.HostAgent.MemoryDisabledConnectionTest do
  use ExUnit.Case, async: false

  alias Backplane.HostAgent.{MemoryProxy, Worker}

  defmodule HubSocket do
    def init(owner), do: {:ok, owner}

    def handle_in({bytes, _metadata}, owner) do
      [join_ref, ref, topic, event, payload] = Jason.decode!(bytes)
      send(owner, {:hub_event, self(), event, payload})

      if event == "sync_result",
        do: send(owner, {:hub_sync_at, System.monotonic_time(:millisecond)})

      response =
        case event do
          "phx_join" ->
            if Map.has_key?(payload, "memory_v2") do
              %{
                "selected" => "host_memory.v2",
                "partitions" => [],
                "extensions" => ["memory_access.v1"]
              }
            else
              %{}
            end

          "get_desired" ->
            %{"skills" => []}

          _ ->
            %{"ok" => true}
        end

      reply = [join_ref, ref, topic, "phx_reply", %{"status" => "ok", "response" => response}]
      {:push, {:text, Jason.encode!(reply)}, owner}
    end

    def handle_info(_message, owner), do: {:ok, owner}
  end

  defmodule HubPlug do
    def init(owner), do: owner

    def call(conn, owner) do
      send(owner, {:hub_connect, Plug.Conn.get_req_header(conn, "x-backplane-host-token")})
      Plug.Conn.upgrade_adapter(conn, :websocket, {HubSocket, owner, []})
    end
  end

  @moduletag :tmp_dir

  setup do
    keys = [
      :socket_client_module,
      :socket_channel_module,
      :socket_channel_join_module,
      :memory_config,
      :memory_store,
      :memory_host_sync,
      :capture_runtime
    ]

    previous = Map.new(keys, &{&1, Application.get_env(:backplane_host_agent, &1)})
    Enum.each(Enum.take(keys, 3), &Application.delete_env(:backplane_host_agent, &1))
    MemoryProxy.set_channel(nil)

    on_exit(fn ->
      MemoryProxy.set_channel(nil)

      Enum.each(previous, fn {key, value} ->
        if is_nil(value),
          do: Application.delete_env(:backplane_host_agent, key),
          else: Application.put_env(:backplane_host_agent, key, value)
      end)
    end)

    :ok
  end

  test "memory-disabled worker retains its real connection and syncs across an interval", %{
    tmp_dir: directory
  } do
    hub = start_supervised!({Gaoxy.HTTP, plug: {HubPlug, self()}, ip: {127, 0, 0, 1}, port: 0})
    %{local: {:ok, {_ip, hub_port}}} = Gaoxy.info(hub, :http)
    http_port = unused_port()
    interval_ms = 100

    config = %{
      host_id: "memory-disabled-host",
      machine_name: "fixture-workstation",
      hub_url: "http://127.0.0.1:#{hub_port}",
      socket_url: "ws://127.0.0.1:#{hub_port}/host-agent/socket/websocket",
      token: "fixture-host-token",
      interval_ms: interval_ms,
      work_dir: directory,
      manifest_path: Path.join(directory, "manifest.json"),
      http_bind: "127.0.0.1",
      http_port: http_port,
      memory: %{enabled: false, host_sync: %{enabled: false}},
      capture: %{enabled: false},
      telemetry: %{enabled: false},
      targets: []
    }

    {:ok, worker} = Worker.start_link(name: nil, connect?: true, config: config)
    Process.unlink(worker)
    on_exit(fn -> if Process.alive?(worker), do: GenServer.stop(worker) end)
    assert_receive {:hub_connect, ["fixture-host-token"]}, 2_000
    assert_receive {:hub_event, peer, "phx_join", offer}, 2_000
    assert offer == %{"host_api" => %{"protocol" => "host_api.v1"}}

    assert_receive {:hub_event, ^peer, "config_report", report}, 2_000
    assert report["memory"]["enabled"] == false
    assert report["capture"]["enabled"] == false
    assert report["telemetry"]["enabled"] == false
    assert_receive {:hub_event, ^peer, "heartbeat", _}, 2_000
    assert_receive {:hub_event, ^peer, "sync_result", %{"status" => "synced"}}, 2_000

    assert_receive {:hub_sync_at, first_sync_at}
    first = GenServer.call(worker, :status)
    assert is_pid(first.channel)
    assert is_pid(first.http_supervisor)
    assert first.memory_supervisor == nil
    assert first.last_error == nil
    assert Process.alive?(first.channel)
    assert Process.alive?(first.socket)

    assert {:ok, local_http} =
             :gen_tcp.connect({127, 0, 0, 1}, http_port, [:binary, active: false])

    :ok = :gen_tcp.close(local_http)

    assert_receive {:hub_event, ^peer, "config_report", _}, 2_000
    assert_receive {:hub_event, ^peer, "heartbeat", _}, 2_000
    assert_receive {:hub_event, ^peer, "sync_result", %{"status" => "synced"}}, 2_000
    assert_receive {:hub_sync_at, second_sync_at}
    assert second_sync_at - first_sync_at >= interval_ms

    second = GenServer.call(worker, :status)
    assert second.channel == first.channel
    assert second.socket == first.socket
    assert second.last_error == nil
    refute_received {:hub_connect, _}
    refute_received {:hub_event, _, "phx_join", _}

    assert :ok = GenServer.stop(worker)
    refute Process.alive?(second.channel)
    refute Process.alive?(second.socket)
  end

  defp unused_port do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_ip, port}} = :inet.sockname(listener)
    :ok = :gen_tcp.close(listener)
    port
  end
end

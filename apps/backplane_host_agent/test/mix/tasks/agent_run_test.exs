defmodule Mix.Tasks.Agent.RunTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Agent.Run, as: AgentRun

  defmodule FakeMemoryProxy do
    def set_config(config) do
      send(owner(), {:set_config, config})
      :ok
    end

    def set_connection(connection, config) do
      send(owner(), {:set_connection, connection, config})
      :ok
    end

    defp owner, do: :persistent_term.get({__MODULE__, :owner})
  end

  defmodule FakeCaptureSupervisor do
    def start_link(config) do
      send(owner(), {:capture_start, config})
      {:ok, sleeper()}
    end

    defp owner, do: :persistent_term.get({__MODULE__, :owner})
    defp sleeper, do: spawn_link(fn -> Process.sleep(:infinity) end)
  end

  defmodule FakeMemorySupervisor do
    def start_link(config) do
      send(owner(), {:memory_start, config})
      {:ok, spawn_link(fn -> Process.sleep(:infinity) end)}
    end

    defp owner, do: :persistent_term.get({__MODULE__, :owner})
  end

  defmodule FakeTraceSupervisor do
    def start_link(config) do
      send(owner(), {:trace_start, config})
      {:ok, spawn_link(fn -> Process.sleep(:infinity) end)}
    end

    defp owner, do: :persistent_term.get({__MODULE__, :owner})
  end

  defmodule FakeHttpServer do
    def child_spec(config) do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:http_child_spec, config})

      Task.child_spec(fn ->
        send(owner, {:http_child_started, self()})
        Process.sleep(:infinity)
      end)
    end
  end

  defmodule RetryConnector do
    def connect(config) do
      attempt = Process.get({__MODULE__, :attempt}, 0) + 1
      Process.put({__MODULE__, :attempt}, attempt)
      send(owner(), {:connect, attempt, config})

      if attempt == 1 do
        {:error, :hub_down}
      else
        {:ok, %{channel: self(), host_id: config.host_id, host_name: config.machine_name}}
      end
    end

    defp owner, do: :persistent_term.get({__MODULE__, :owner})
  end

  defmodule FailingCaptureSupervisor do
    def start_link(_config), do: {:error, :spool_unavailable}
  end

  test "mix agent.run task is available" do
    assert Code.ensure_loaded?(Mix.Tasks.Agent.Run)
    assert function_exported?(Mix.Tasks.Agent.Run, :run, 1)
  end

  test "bootstraps every offline service before retrying the hub connection" do
    modules = [
      FakeMemoryProxy,
      FakeCaptureSupervisor,
      FakeMemorySupervisor,
      FakeTraceSupervisor,
      FakeHttpServer,
      RetryConnector
    ]

    Enum.each(modules, &:persistent_term.put({&1, :owner}, self()))
    on_exit(fn -> Enum.each(modules, &:persistent_term.erase({&1, :owner})) end)

    assert {:ok, runtime} =
             AgentRun.bootstrap(config(),
               memory_proxy_module: FakeMemoryProxy,
               capture_supervisor_module: FakeCaptureSupervisor,
               memory_supervisor_module: FakeMemorySupervisor,
               trace_supervisor_module: FakeTraceSupervisor,
               http_server_module: FakeHttpServer,
               connector_module: RetryConnector,
               retry_interval_ms: 0,
               sleep_fun: fn milliseconds -> send(self(), {:sleep, milliseconds}) end
             )

    assert_receive first
    assert {:set_config, %{host_id: "host-authoritative"}} = first
    assert_receive second

    assert {:capture_start, %{host_id: "host-authoritative", db_path: "/tmp/capture.db"}} =
             second

    assert_receive third
    assert {:memory_start, %{enabled: true}} = third
    assert_receive fourth
    assert {:trace_start, %{enabled: true}} = fourth
    assert_receive fifth
    assert {:http_child_spec, %{host_id: "host-authoritative"}} = fifth
    assert_receive {:connect, 1, %{host_id: "host-authoritative"}}
    assert_receive {:sleep, 0}
    assert_receive {:connect, 2, %{host_id: "host-authoritative"}}

    assert_receive {:set_connection, %{channel: channel}, %{host_id: "host-authoritative"}}

    assert_receive {:http_child_started, http_child}

    assert channel == self()
    assert Process.alive?(runtime.capture_supervisor)
    assert Process.alive?(runtime.memory_supervisor)
    assert Process.alive?(runtime.trace_supervisor)
    assert Process.alive?(runtime.http_supervisor)
    assert Process.alive?(http_child)

    stop_runtime(runtime)
  end

  test "reports capture startup failures consistently" do
    :persistent_term.put({FakeMemoryProxy, :owner}, self())
    on_exit(fn -> :persistent_term.erase({FakeMemoryProxy, :owner}) end)

    assert_raise Mix.Error, ~r/failed to start capture spool: :spool_unavailable/, fn ->
      AgentRun.bootstrap(config(),
        memory_proxy_module: FakeMemoryProxy,
        capture_supervisor_module: FailingCaptureSupervisor,
        memory_supervisor_module: FakeMemorySupervisor,
        trace_supervisor_module: FakeTraceSupervisor,
        http_server_module: FakeHttpServer,
        connector_module: RetryConnector,
        retry_interval_ms: 0
      )
    end
  end

  defp config do
    %{
      host_id: "host-authoritative",
      machine_name: "t430",
      hub_url: "http://localhost:4220",
      capture: %{enabled: true, host_id: "spoofed", db_path: "/tmp/capture.db"},
      memory: %{enabled: true, db_path: "/tmp/memory.db"},
      telemetry: %{enabled: true, dir: "/tmp/trace"},
      http_bind: "127.0.0.1",
      http_port: 4222
    }
  end

  defp stop_runtime(runtime) do
    Enum.each(
      [:http_supervisor, :trace_supervisor, :memory_supervisor, :capture_supervisor],
      fn key ->
        case Map.get(runtime, key) do
          pid when is_pid(pid) ->
            Process.unlink(pid)
            Process.exit(pid, :shutdown)

          _ ->
            :ok
        end
      end
    )
  end
end

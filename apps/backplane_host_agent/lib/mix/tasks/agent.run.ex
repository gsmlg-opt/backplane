defmodule Mix.Tasks.Agent.Run do
  @shortdoc "Runs the Backplane host agent"

  @moduledoc """
  Runs the Backplane host agent against a configured hub.

  ## Configuration

  The agent reads YAML from `$BACKPLANE_HOST_AGENT_CONFIG` if set, otherwise from
  `$XDG_CONFIG_HOME/backplane/host_agent.yaml` (defaults to
  `~/.config/backplane/host_agent.yaml`).

  If the file does not exist, a sample is written there and the task exits.
  Edit it to set `agent.hub_url`, `agent.token`, and any targets, then re-run.

  ## Examples

      mix agent.run
      BACKPLANE_HOST_AGENT_CONFIG=./agent.yaml mix agent.run

  """

  use Mix.Task

  alias Backplane.HostAgent.{
    Config,
    Connector,
    HttpServer,
    MemoryProxy,
    RunLock,
    Worker
  }

  alias Backplane.HostAgent.Memory.CaptureSupervisor
  alias Backplane.HostAgent.Memory.Supervisor, as: MemorySupervisor
  alias Backplane.HostAgent.TraceSupervisor

  @retry_interval_ms 4_000

  @impl true
  def run(_args) do
    Mix.Task.run("app.config")
    Application.put_env(:backplane_host_agent, :start_on_application, false)

    {:ok, _apps} = Application.ensure_all_started(:backplane_host_agent)

    case Config.load_default() do
      {:ok, config} ->
        ensure_required!(config)
        acquire_lock_and_run(config)

      {:error, {:missing, path}} ->
        :ok = Config.write_sample(path)

        Mix.shell().info("""
        Wrote sample host agent config to #{path}.
        Edit it to set agent.hub_url, agent.token, and target paths, then run `mix agent.run` again.
        """)

      {:error, reason} ->
        Mix.raise("failed to load host agent config: #{inspect(reason)}")
    end
  end

  defp ensure_required!(config) do
    missing =
      Enum.filter(
        [
          {:hub_url, config.hub_url},
          {:token, config.token},
          {:machine_name, config.machine_name}
        ],
        fn {_key, val} -> is_nil(val) or val == "" or val == "REPLACE_WITH_AUTH_TOKEN" end
      )
      |> Enum.map(&elem(&1, 0))

    if missing != [] do
      Mix.raise(
        "host agent config missing required fields: #{Enum.join(missing, ", ")} " <>
          "(edit #{Config.resolved_path()})"
      )
    end
  end

  defp acquire_lock_and_run(config) do
    case RunLock.acquire(Config.resolved_path()) do
      {:ok, lock} ->
        try do
          connect_and_run(config)
        after
          RunLock.release(lock)
        end

      {:error, {:already_running, pid, path}} ->
        Mix.raise("host agent is already running with OS pid #{pid} (lock: #{path})")

      {:error, reason} ->
        Mix.raise("failed to acquire host agent run lock: #{inspect(reason)}")
    end
  end

  defp connect_and_run(config) do
    {:ok, %{connection: %{channel: channel}}} = bootstrap(config)

    {:ok, worker} =
      Worker.start_link(
        channel: channel,
        config: config,
        name: Backplane.HostAgent.Worker
      )

    Mix.shell().info("Host agent worker started (pid=#{inspect(worker)}). Idling…")
    Process.sleep(:infinity)
  end

  @doc false
  def bootstrap(config, opts \\ []) do
    memory_proxy_module = Keyword.get(opts, :memory_proxy_module, MemoryProxy)

    capture_supervisor_module =
      Keyword.get(opts, :capture_supervisor_module, CaptureSupervisor)

    memory_supervisor_module = Keyword.get(opts, :memory_supervisor_module, MemorySupervisor)
    trace_supervisor_module = Keyword.get(opts, :trace_supervisor_module, TraceSupervisor)
    http_server_module = Keyword.get(opts, :http_server_module, HttpServer)

    :ok = memory_proxy_module.set_config(config)
    capture_supervisor = maybe_start_capture(config, capture_supervisor_module)
    memory_supervisor = maybe_start_memory(config, memory_supervisor_module)
    trace_supervisor = maybe_start_trace(config, trace_supervisor_module)
    http_supervisor = maybe_start_http_server(config, http_server_module)

    connection = connect_with_retry(config, opts)
    :ok = memory_proxy_module.set_connection(connection, config)

    {:ok,
     %{
       capture_supervisor: capture_supervisor,
       memory_supervisor: memory_supervisor,
       trace_supervisor: trace_supervisor,
       http_supervisor: http_supervisor,
       connection: connection
     }}
  end

  defp maybe_start_capture(%{capture: capture_config} = config, capture_supervisor_module)
       when is_map(capture_config) do
    capture_config = Map.put(capture_config, :host_id, config.host_id)

    case capture_supervisor_module.start_link(capture_config) do
      {:ok, pid} ->
        Mix.shell().info("Capture spool ready at #{capture_config.db_path}.")
        pid

      :ignore ->
        nil

      {:error, {:already_started, pid}} ->
        pid

      {:error, reason} ->
        Mix.raise("failed to start capture spool: #{inspect(reason)}")
    end
  end

  defp maybe_start_capture(_config, _capture_supervisor_module), do: nil

  defp maybe_start_memory(
         %{memory: %{enabled: true} = memory_config},
         memory_supervisor_module
       ) do
    case memory_supervisor_module.start_link(memory_config) do
      {:ok, pid} ->
        Mix.shell().info("Memory store ready at #{memory_config.db_path}.")
        pid

      :ignore ->
        nil

      {:error, {:already_started, pid}} ->
        pid

      {:error, reason} ->
        Mix.raise("failed to start memory store: #{inspect(reason)}")
    end
  end

  defp maybe_start_memory(_config, _memory_supervisor_module), do: nil

  defp maybe_start_trace(
         %{telemetry: %{enabled: true} = telemetry_config},
         trace_supervisor_module
       ) do
    case trace_supervisor_module.start_link(telemetry_config) do
      {:ok, pid} ->
        Application.put_env(:backplane_host_agent, :telemetry_config, telemetry_config)
        Mix.shell().info("Trace store ready at #{telemetry_config.dir}.")
        pid

      :ignore ->
        nil

      {:error, {:already_started, pid}} ->
        pid

      {:error, reason} ->
        Mix.raise("failed to start trace store: #{inspect(reason)}")
    end
  end

  defp maybe_start_trace(_config, _trace_supervisor_module), do: nil

  defp connect_with_retry(config, opts) do
    connector_module = Keyword.get(opts, :connector_module, Connector)
    retry_interval_ms = Keyword.get(opts, :retry_interval_ms, @retry_interval_ms)
    sleep_fun = Keyword.get(opts, :sleep_fun, &Process.sleep/1)

    Mix.shell().info("Connecting host agent #{config.machine_name} to #{config.hub_url}…")

    case connector_module.connect(config) do
      {:ok, %{host_name: host_name} = link} ->
        Mix.shell().info("Connected as host \"#{host_name}\" (id=#{link.host_id}).")
        link

      {:error, reason} ->
        Mix.shell().error(
          "Failed to connect to Backplane hub: #{inspect(reason)}; retrying in #{retry_interval_ms}ms."
        )

        sleep_fun.(retry_interval_ms)
        connect_with_retry(config, opts)
    end
  end

  defp maybe_start_http_server(config, http_server_module) do
    case http_server_module.child_spec(config) do
      nil ->
        nil

      spec ->
        case Supervisor.start_link([spec], strategy: :one_for_one) do
          {:ok, sup} ->
            Mix.shell().info(
              "Memory HTTP API listening on http://#{config.http_bind}:#{config.http_port}/memory/:agent_id/{call/:method,mcp}"
            )

            sup

          {:error, reason} ->
            Mix.raise("failed to start memory HTTP server: #{inspect(reason)}")
        end
    end
  end
end

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
    McpManager,
    MemoryProxy,
    RunLock,
    Worker
  }

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
    MemoryProxy.set_config(config)
    ensure_mcp_manager_started()

    %{channel: channel} = link = connect_with_retry(config)
    MemoryProxy.set_connection(link, config)
    maybe_start_http_server(config)

    {:ok, worker} =
      Worker.start_link(
        channel: channel,
        config: config,
        name: Backplane.HostAgent.Worker
      )

    Mix.shell().info("Host agent worker started (pid=#{inspect(worker)}). Idling…")
    Process.sleep(:infinity)
  end

  defp ensure_mcp_manager_started do
    case McpManager.start_link(name: McpManager) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} ->
        Mix.raise("failed to start host agent MCP manager: #{inspect(reason)}")
    end
  end

  defp connect_with_retry(config) do
    Mix.shell().info("Connecting host agent #{config.machine_name} to #{config.hub_url}…")

    case Connector.connect(config) do
      {:ok, %{host_name: host_name} = link} ->
        Mix.shell().info("Connected as host \"#{host_name}\" (id=#{link.host_id}).")
        link

      {:error, reason} ->
        Mix.shell().error(
          "Failed to connect to Backplane hub: #{inspect(reason)}; retrying in #{@retry_interval_ms}ms."
        )

        Process.sleep(@retry_interval_ms)
        connect_with_retry(config)
    end
  end

  defp maybe_start_http_server(config) do
    case HttpServer.child_spec(config) do
      nil ->
        :ok

      spec ->
        case Supervisor.start_link([spec], strategy: :one_for_one) do
          {:ok, _sup} ->
            Mix.shell().info(
              "Memory HTTP API listening on http://#{config.http_bind}:#{config.http_port}/memory/:agent_id/{call/:method,mcp}"
            )

          {:error, reason} ->
            Mix.raise("failed to start memory HTTP server: #{inspect(reason)}")
        end
    end
  end
end

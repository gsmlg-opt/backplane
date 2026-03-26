defmodule Backplane.Config.Watcher do
  @moduledoc """
  Watches for config reload signals (SIGHUP) and reloads backplane.toml.
  """

  use GenServer
  require Logger

  alias Backplane.Config.Validator
  alias Backplane.Proxy.Pool

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # Debounce interval: coalesce rapid SIGHUP signals into a single reload
  @debounce_ms 1_000

  @impl true
  def init(_opts) do
    # Register for SIGHUP on supported systems
    if function_exported?(:os, :set_signal, 2) do
      :os.set_signal(:sighup, :handle)
    end

    {:ok, %{reload_timer: nil}}
  end

  @impl true
  def handle_info({:signal, :sighup}, state) do
    Logger.info("Received SIGHUP, scheduling config reload")

    # Cancel pending reload timer if one exists (debounce)
    if state.reload_timer, do: Process.cancel_timer(state.reload_timer)
    timer = Process.send_after(self(), :do_reload, @debounce_ms)
    {:noreply, %{state | reload_timer: timer}}
  end

  def handle_info(:do_reload, state) do
    reload()
    {:noreply, %{state | reload_timer: nil}}
  end

  def handle_info(msg, state) do
    Logger.debug("Config.Watcher received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @doc "Manually trigger config reload."
  @spec reload() :: :ok | {:error, term()}
  def reload do
    path = config_path()

    if File.exists?(path) do
      do_reload(path)
    else
      {:error, :not_found}
    end
  end

  defp do_reload(path) do
    config = Backplane.Config.load!(path)
    Validator.validate!(config)
    apply_config(config)
    Logger.info("Configuration reloaded successfully")
    :ok
  rescue
    e ->
      Logger.error("Failed to reload configuration: #{inspect(e)}")
      {:error, :reload_failed}
  end

  defp config_path do
    Application.get_env(:backplane, :config_path, "backplane.toml")
  end

  defp apply_config(config) do
    # Update auth token(s) from [backplane] section
    if token = get_in(config, [:backplane, :auth_token]) do
      Application.put_env(:backplane, :auth_token, token)
    end

    if tokens = get_in(config, [:backplane, :auth_tokens]) do
      Application.put_env(:backplane, :auth_tokens, tokens)
    end

    # Update git providers — merge into the single :git_providers key
    # that Tools.Git, Hub, and HealthCheck read from
    current = Application.get_env(:backplane, :git_providers, %{})

    updated =
      current
      |> then(fn m -> if config[:github], do: Map.put(m, :github, config[:github]), else: m end)
      |> then(fn m -> if config[:gitlab], do: Map.put(m, :gitlab, config[:gitlab]), else: m end)

    if updated != current do
      Application.put_env(:backplane, :git_providers, updated)
    end

    # Update project configurations
    if projects = config[:projects] do
      Application.put_env(:backplane, :projects, projects)
    end

    # Update skill source configurations
    if skills = config[:skills] do
      Application.put_env(:backplane, :skill_sources, skills)
    end

    # Reconcile upstream MCP connections (add new, remove stale)
    reconcile_upstreams(config[:upstream] || [])

    :ok
  end

  defp reconcile_upstreams(desired_upstreams) do
    running = Pool.list_upstream_pids()
    running_by_prefix = Map.new(running, fn {pid, status} -> {status.prefix, pid} end)
    desired_prefixes = MapSet.new(desired_upstreams, & &1.prefix)
    running_prefixes = MapSet.new(Map.keys(running_by_prefix))

    # Stop upstreams that are no longer in the config
    removed = MapSet.difference(running_prefixes, desired_prefixes)

    for prefix <- removed do
      Logger.info("Stopping removed upstream: #{prefix}")
      Pool.stop_upstream(running_by_prefix[prefix])
    end

    # Start upstreams that are new in the config
    added = MapSet.difference(desired_prefixes, running_prefixes)

    for upstream <- desired_upstreams, upstream.prefix in added do
      Logger.info("Starting new upstream: #{upstream.prefix}")
      Pool.start_upstream(upstream)
    end

    if MapSet.size(removed) > 0 or MapSet.size(added) > 0 do
      Logger.info(
        "Upstream reconciliation: added=#{MapSet.size(added)} removed=#{MapSet.size(removed)}"
      )
    end
  end
end

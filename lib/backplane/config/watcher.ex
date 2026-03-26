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
    Backplane.Notifications.tools_changed()
    Backplane.PubSubBroadcaster.broadcast_config_reloaded()
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
    apply_backplane_settings(config[:backplane] || %{})
    apply_git_providers(config)
    maybe_put_env(:projects, config[:projects])
    maybe_put_env(:skill_sources, config[:skills])
    reconcile_upstreams(config[:upstream] || [])
    :ok
  end

  defp apply_backplane_settings(backplane) do
    for {config_key, env_key} <- [
          {:auth_token, :auth_token},
          {:auth_tokens, :auth_tokens},
          {:admin_username, :admin_username},
          {:admin_password, :admin_password}
        ] do
      maybe_put_env(env_key, backplane[config_key])
    end
  end

  defp apply_git_providers(config) do
    current = Application.get_env(:backplane, :git_providers, %{})

    updated =
      current
      |> then(fn m -> if config[:github], do: Map.put(m, :github, config[:github]), else: m end)
      |> then(fn m -> if config[:gitlab], do: Map.put(m, :gitlab, config[:gitlab]), else: m end)

    if updated != current do
      Application.put_env(:backplane, :git_providers, updated)
    end
  end

  defp maybe_put_env(_key, nil), do: :ok

  defp maybe_put_env(key, value) do
    Application.put_env(:backplane, key, value)
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

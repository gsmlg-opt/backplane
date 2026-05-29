defmodule Backplane.HostAgent.Worker do
  @moduledoc false

  use GenServer

  require Logger

  alias Backplane.HostAgent.{
    Channel,
    Config,
    Connector,
    HttpServer,
    Installer,
    Manifest,
    McpManager,
    MemoryProxy,
    Reconciler,
    Reporter
  }

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def sync_now do
    GenServer.call(__MODULE__, :sync_now)
  end

  def status do
    GenServer.call(__MODULE__, :status)
  end

  def run_once(%{channel: channel, config: config} = state)
      when not is_nil(channel) and not is_nil(config) do
    channel_module = Map.get(state, :channel_module, Channel)

    with {:ok, _reply} <- push(channel_module, channel, "heartbeat", Reporter.heartbeat(config)),
         {:ok, desired_state} <- desired_state(state),
         {:ok, manifest} <- read_manifest(config) do
      # Reconcile MCP servers
      mcp_manager = Map.get(state, :mcp_manager_module, McpManager)
      reconcile_mcp_servers(mcp_manager, desired_state)

      # Reconcile skills
      desired = skills(desired_state)
      actions = Reconciler.plan(desired, manifest)
      results = execute_actions(actions, state)
      status = sync_status(results)
      result_payload = Reporter.sync_result(status, results)

      with {:ok, _reply} <- push(channel_module, channel, "sync_result", result_payload),
           :ok <- maybe_write_manifest(config, manifest, actions, results, status) do
        finish_run(state, status, results)
      else
        {:error, reason} -> fail_run(state, reason)
      end
    else
      {:error, reason} -> fail_run(state, reason)
    end
  end

  def run_once(state) do
    fail_run(state, :not_configured)
  end

  @impl true
  def init(opts) do
    case initial_state(opts) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:sync_now, _from, state) do
    case run_once(state) do
      {:ok, updated_state} -> {:reply, :ok, updated_state}
      {:error, reason, updated_state} -> {:reply, {:error, reason}, updated_state}
    end
  end

  def handle_call(:status, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_info(:sync, state) do
    case run_once(state) do
      {:ok, updated_state} -> {:noreply, updated_state}
      {:error, _reason, updated_state} -> {:noreply, updated_state}
    end
  end

  defp desired_state(%{desired: desired}) when not is_nil(desired), do: {:ok, desired}

  defp desired_state(%{channel: channel} = state) do
    channel_module = Map.get(state, :channel_module, Channel)

    push(channel_module, channel, "get_desired", %{})
  end

  defp initial_state(opts) do
    if connect_on_start?(opts) do
      connect_state(opts)
    else
      {:ok, state_from_opts(opts)}
    end
  end

  defp connect_on_start?(opts) do
    Keyword.get(
      opts,
      :connect?,
      is_nil(Keyword.get(opts, :channel)) and is_nil(Keyword.get(opts, :config))
    )
  end

  defp connect_state(opts) do
    config_module = Keyword.get(opts, :config_module, Config)
    connector_module = Keyword.get(opts, :connector_module, Connector)
    http_server_module = Keyword.get(opts, :http_server_module, HttpServer)
    memory_proxy_module = Keyword.get(opts, :memory_proxy_module, MemoryProxy)

    with {:ok, config} <- config_module.load_default(),
         :ok <- validate_required_config(config),
         {:ok, %{channel: channel} = connection} <- connector_module.connect(config),
         :ok <- set_memory_connection(memory_proxy_module, connection, config),
         {:ok, http_supervisor} <- maybe_start_http_server(http_server_module, config) do
      opts =
        opts
        |> Keyword.put(:channel, channel)
        |> Keyword.put(:config, config)
        |> Keyword.put(:http_supervisor, http_supervisor)

      {:ok, state_from_opts(opts)}
    else
      {:error, {:missing, path}} ->
        maybe_write_sample(config_module, path)
        {:error, {:missing_config, path}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp state_from_opts(opts) do
    %{
      channel: Keyword.get(opts, :channel),
      channel_module: Keyword.get(opts, :channel_module, Channel),
      config: Keyword.get(opts, :config),
      desired: Keyword.get(opts, :desired),
      http_supervisor: Keyword.get(opts, :http_supervisor),
      installer_module: Keyword.get(opts, :installer_module, Installer),
      last_sync: nil,
      last_error: nil
    }
  end

  defp set_memory_connection(memory_proxy_module, connection, config) do
    if function_exported?(memory_proxy_module, :set_connection, 2) do
      memory_proxy_module.set_connection(connection, config)
    else
      memory_proxy_module.set_channel(connection.channel)
    end
  end

  defp validate_required_config(config) do
    missing =
      [:hub_url, :token, :machine_name]
      |> Enum.filter(fn key ->
        value = field(config, key)
        is_nil(value) or value == "" or value == "REPLACE_WITH_AUTH_TOKEN"
      end)

    case missing do
      [] -> :ok
      fields -> {:error, {:missing_required_config, fields}}
    end
  end

  defp maybe_start_http_server(http_server_module, config) do
    case http_server_module.child_spec(config) do
      nil ->
        {:ok, nil}

      spec ->
        case Supervisor.start_link([spec], strategy: :one_for_one) do
          {:ok, pid} -> {:ok, pid}
          {:error, reason} -> {:error, {:http_server_start_failed, reason}}
        end
    end
  end

  defp maybe_write_sample(config_module, path) do
    if function_exported?(config_module, :write_sample, 1) do
      config_module.write_sample(path)
    end
  end

  defp read_manifest(config) do
    Manifest.read(Map.fetch!(config, :manifest_path), Map.fetch!(config, :machine_name))
  rescue
    error in [File.Error, Jason.DecodeError, ArgumentError] ->
      {:error, {:manifest_read_error, Exception.message(error)}}
  end

  defp execute_actions(actions, state) do
    Enum.map(actions, &execute_action(&1, state))
  end

  defp execute_action(%{action: action, skill: skill} = planned, state)
       when action in [:install, :update, :repair] do
    installer_module = Map.get(state, :installer_module, Installer)

    case installer_module.install(skill, Map.fetch!(state, :config)) do
      {:ok, installed_targets} ->
        result(planned, status_for(action), installed_targets)

      :ok ->
        result(planned, status_for(action), targets(skill))

      {:error, reason} ->
        planned
        |> result(:failed, targets(skill))
        |> Map.put("error", format_error(reason))
    end
  end

  defp execute_action(%{action: :noop} = planned, _state) do
    result(planned, :noop, targets(planned.skill))
  end

  defp execute_action(%{action: :remove} = planned, state) do
    installer_module = Map.get(state, :installer_module, Installer)

    case installer_module.remove(planned.skill, Map.fetch!(state, :config)) do
      {:ok, removed_targets} ->
        result(planned, :removed, removed_targets)

      :ok ->
        result(planned, :removed, targets(planned.skill))

      {:error, reason} ->
        planned
        |> result(:failed, targets(planned.skill))
        |> Map.put("error", format_error(reason))
    end
  end

  defp finish_run(state, :failed, results) do
    reason =
      results
      |> Enum.find_value(fn result -> if result["status"] == "failed", do: result["error"] end)
      |> Kernel.||(:sync_failed)

    fail_run(state, reason)
  end

  defp finish_run(state, _status, _results) do
    {:ok, Map.merge(state, %{last_sync: DateTime.utc_now(), last_error: nil})}
  end

  defp fail_run(state, reason) do
    {:error, reason, Map.put(state, :last_error, reason)}
  end

  defp push(channel_module, channel, event, payload) do
    case channel_module.push(channel, event, payload) do
      {:ok, reply} -> {:ok, reply}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_reply, other}}
    end
  end

  defp skills(%{"skills" => skills}) when is_list(skills), do: skills
  defp skills(%{skills: skills}) when is_list(skills), do: skills
  defp skills(_desired_state), do: []

  defp mcp_servers(%{"mcp_servers" => servers}) when is_list(servers), do: servers
  defp mcp_servers(%{mcp_servers: servers}) when is_list(servers), do: servers
  defp mcp_servers(_desired_state), do: []

  defp reconcile_mcp_servers(mcp_manager, desired_state) do
    servers = mcp_servers(desired_state)
    mcp_manager.reconcile(servers)
  catch
    kind, reason ->
      Logger.warning("MCP server reconciliation failed: #{inspect(kind)} #{inspect(reason)}")
  end

  defp status_for(:install), do: :installed
  defp status_for(:update), do: :updated
  defp status_for(:repair), do: :repaired

  defp sync_status(results) do
    if Enum.any?(results, &(&1["status"] == "failed")) do
      :failed
    else
      :synced
    end
  end

  defp result(planned, status, installed_targets) do
    skill = planned.skill

    %{
      "checksum" => field(skill, :checksum),
      "desired_checksum" => field(skill, :checksum),
      "desired_version" => field(skill, :version),
      "installed_checksum" => installed_checksum(status, skill),
      "installed_version" => installed_version(status, skill),
      "skill_id" => field(skill, :id),
      "skill_name" => field(skill, :name, planned.slug),
      "skill_slug" => planned.slug,
      "status" => to_string(status),
      "targets" => installed_targets
    }
  end

  defp installed_checksum(:failed, _skill), do: nil
  defp installed_checksum(_status, skill), do: field(skill, :checksum)

  defp installed_version(:failed, _skill), do: nil
  defp installed_version(_status, skill), do: field(skill, :version)

  defp targets(skill), do: field(skill, :targets, [])

  defp field(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp maybe_write_manifest(_config, _manifest, _actions, _results, :failed), do: :ok

  defp maybe_write_manifest(config, manifest, actions, results, _status) do
    next_manifest = apply_manifest_actions(manifest, actions, results)

    Manifest.write(Map.fetch!(config, :manifest_path), next_manifest)
    :ok
  rescue
    error in File.Error -> {:error, {:file_error, error.reason}}
    error in Jason.EncodeError -> {:error, {:manifest_encode_error, error.message}}
  end

  defp apply_manifest_actions(manifest, actions, results) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()
    result_by_slug = Map.new(results, fn result -> {result["skill_slug"], result} end)

    skills =
      Enum.reduce(actions, manifest.skills, fn action, skills ->
        result = Map.get(result_by_slug, action.slug)

        if result && result["status"] == "failed" do
          skills
        else
          apply_manifest_action(skills, action, result, now)
        end
      end)

    %{manifest | skills: skills}
  end

  defp apply_manifest_action(skills, %{action: :remove, slug: slug}, result, _now) do
    removed_targets = field(result || %{}, :targets, [])

    case Enum.find(skills, &(field(&1, :slug) == slug)) do
      nil ->
        skills

      existing ->
        remaining_targets = targets(existing) -- removed_targets
        other_skills = Enum.reject(skills, &(field(&1, :slug) == slug))

        if remaining_targets == [] do
          other_skills
        else
          [Map.put(existing, :targets, remaining_targets) | other_skills]
        end
    end
  end

  defp apply_manifest_action(skills, %{action: :noop, slug: slug}, _result, _now) do
    skills
    |> Enum.find(&(field(&1, :slug) == slug))
    |> case do
      nil -> skills
      existing -> [existing | Enum.reject(skills, &(field(&1, :slug) == slug))]
    end
  end

  defp apply_manifest_action(skills, %{action: action, skill: skill, slug: slug}, result, now)
       when action in [:install, :update, :repair] do
    entry = manifest_entry(skill, result, now)

    [entry | Enum.reject(skills, &(field(&1, :slug) == slug))]
  end

  defp manifest_entry(skill, result, installed_at) do
    %{
      name: field(skill, :name),
      slug: field(skill, :slug),
      version: field(skill, :version),
      checksum: field(skill, :checksum),
      targets: field(result || %{}, :targets, targets(skill)),
      owned: true,
      installed_at: installed_at
    }
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_error(reason), do: inspect(reason)
end

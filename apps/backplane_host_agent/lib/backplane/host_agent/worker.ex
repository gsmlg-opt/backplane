defmodule Backplane.HostAgent.Worker do
  @moduledoc false

  use GenServer

  require Logger

  defguardp channel_exit_reason(reason)
            when is_tuple(reason) and tuple_size(reason) == 2 and elem(reason, 0) == :channel_exit

  alias Backplane.HostAgent.{
    Channel,
    Config,
    Connector,
    HttpServer,
    Installer,
    Manifest,
    MemoryProxy,
    Reconciler,
    Reporter
  }

  alias Backplane.HostAgent.Memory.CaptureSupervisor
  alias Backplane.HostAgent.Memory.Edge.Syncer, as: EdgeSyncer
  alias Backplane.HostAgent.Memory.Supervisor, as: MemorySupervisor
  alias Backplane.HostAgent.TraceSupervisor

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
    started_at = DateTime.utc_now()

    with {:ok, _reply} <-
           push(channel_module, channel, "config_report", Reporter.config_report(config, state)),
         {:ok, _reply} <- push(channel_module, channel, "heartbeat", Reporter.heartbeat(config)),
         {:ok, desired_state} <- desired_state(state),
         {:ok, manifest} <- read_manifest(config) do
      # Reconcile skills
      desired = skills(desired_state)
      actions = Reconciler.plan(desired, manifest)
      results = execute_actions(actions, state)
      status = sync_status(results)
      result_payload = Reporter.sync_result(status, results, started_at)

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
  def init(opts), do: with_safe_diagnostics(fn -> init_worker(opts) end)

  defp init_worker(opts) do
    case initial_state(opts) do
      {:continue, state} ->
        {:ok, state, {:continue, :connect}}

      {:ok, state} ->
        {:ok, maybe_schedule_initial_sync(state)}
    end
  end

  @impl true
  def handle_continue(message, state),
    do: with_safe_diagnostics(fn -> continue_worker(message, state) end)

  defp continue_worker(:connect, state), do: connect_or_retry(state)

  @impl true
  def handle_call(message, from, state),
    do: with_safe_diagnostics(fn -> call_worker(message, from, state) end)

  defp call_worker(:sync_now, _from, state) do
    case run_once(state) do
      {:ok, updated_state} -> {:reply, :ok, updated_state}
      {:error, reason, updated_state} -> {:reply, {:error, reason}, updated_state}
    end
  end

  defp call_worker(:status, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_info(message, state),
    do: with_safe_diagnostics(fn -> info_worker(message, state) end)

  defp info_worker(:sync, state) do
    case run_once(state) do
      {:ok, updated_state} -> {:noreply, schedule_next_sync(updated_state)}
      {:error, _reason, updated_state} -> {:noreply, schedule_next_sync(updated_state)}
    end
  end

  defp info_worker(:connect_retry, state) do
    cancel_timer(state.connect_retry_ref)
    connect_or_retry(%{state | connect_retry_ref: nil})
  end

  defp info_worker({:timeout, ref, :connect_retry}, %{connect_retry_ref: ref} = state),
    do: connect_or_retry(%{state | connect_retry_ref: nil})

  defp info_worker({:timeout, _ref, :connect_retry}, state), do: {:noreply, state}

  # The channel library forwards replies to asynchronous pushes to its join
  # caller. They do not own a Worker request and may arrive after replacement.
  defp info_worker(%Phoenix.SocketClient.Message{event: "phx_reply"}, state),
    do: {:noreply, state}

  defp info_worker(
         {:memory_connection_lost, channel},
         %{channel: channel, owns_connection?: true} = state
       ) do
    {:noreply,
     state
     |> retire_connection()
     |> Map.put(:last_error, :not_connected)
     |> schedule_connect_retry()}
  end

  defp info_worker({:memory_connection_lost, _channel}, state), do: {:noreply, state}

  defp info_worker(
         {:DOWN, ref, :process, channel, _reason},
         %{channel_monitor_ref: ref, channel: channel, owns_connection?: true} = state
       ) do
    {:noreply,
     state
     |> retire_connection()
     |> Map.put(:last_error, :not_connected)
     |> schedule_connect_retry()}
  end

  defp info_worker({:DOWN, _ref, :process, _channel, _reason}, state), do: {:noreply, state}

  @impl true
  def format_status(status) do
    Map.new(status, fn
      {:state, state} -> {:state, Map.drop(state, [:config, :connect_opts])}
      {:reason, reason} -> {:reason, diagnostic_reason(reason)}
      {:message, _message} -> {:message, :redacted}
      {:log, _log} -> {:log, []}
      entry -> entry
    end)
  end

  # OTP appends the original callback stack after format_status/1 returns.
  # Remove arguments at the callback boundary so crash reports cannot restore them.
  defp with_safe_diagnostics(callback) do
    callback.()
  catch
    kind, reason ->
      :erlang.raise(kind, diagnostic_reason(reason), diagnostic_stacktrace(__STACKTRACE__))
  end

  defp diagnostic_stacktrace(stacktrace) do
    for {module, function, arguments, location} <- stacktrace do
      arity = if is_list(arguments), do: length(arguments), else: arguments
      {module, function, arity, Keyword.take(location, [:file, :line])}
    end
  end

  defp diagnostic_reason(%{__exception__: true, __struct__: exception}) do
    # Defaults retain the exception type without retaining runtime payloads such
    # as KeyError.term, MatchError.term, or a provider's exception message.
    safe = struct(exception)
    if Map.has_key?(safe, :message), do: Map.put(safe, :message, "details redacted"), else: safe
  end

  defp diagnostic_reason(reason) when is_atom(reason), do: reason

  defp diagnostic_reason(reason) when is_tuple(reason) and is_atom(elem(reason, 0)) do
    reason
    |> Tuple.to_list()
    |> then(fn [tag | args] -> [tag | Enum.map(args, fn _ -> :redacted end)] end)
    |> List.to_tuple()
  end

  defp diagnostic_reason(_reason), do: :redacted

  @impl true
  def terminate(reason, state),
    do: with_safe_diagnostics(fn -> terminate_worker(reason, state) end)

  defp terminate_worker(_reason, state) do
    _state = retire_connection(state)
    memory_proxy_module = Map.get(state, :memory_proxy_module, MemoryProxy)

    if Map.get(state, :owns_connection?, false) and
         function_exported?(memory_proxy_module, :clear_connection_owner, 1),
       do: memory_proxy_module.clear_connection_owner(self())

    case Map.get(state, :edge_syncer) do
      pid when is_pid(pid) -> if Process.alive?(pid), do: EdgeSyncer.stop(pid)
      _ -> :ok
    end

    :ok
  end

  defp desired_state(%{desired: desired}) when not is_nil(desired), do: {:ok, desired}

  defp desired_state(%{channel: channel} = state) do
    channel_module = Map.get(state, :channel_module, Channel)

    push(channel_module, channel, "get_desired", %{})
  end

  defp initial_state(opts) do
    if connect_on_start?(opts) do
      {:continue, state_from_opts(Keyword.put(opts, :owns_connection?, true))}
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

  defp connect_state(opts, state) do
    config_module = Keyword.get(opts, :config_module, Config)
    connector_module = Keyword.get(opts, :connector_module, Connector)

    capture_supervisor_module =
      Keyword.get(opts, :capture_supervisor_module, CaptureSupervisor)

    http_server_module = Keyword.get(opts, :http_server_module, HttpServer)
    memory_proxy_module = Keyword.get(opts, :memory_proxy_module, MemoryProxy)

    config_result =
      case Keyword.get(opts, :config) do
        nil -> config_module.load_default()
        config -> {:ok, config}
      end

    case config_result do
      {:ok, config} ->
        connect_loaded_state(
          state,
          config,
          connector_module,
          capture_supervisor_module,
          http_server_module,
          memory_proxy_module
        )

      {:error, {:missing, path}} ->
        maybe_write_sample(config_module, path)
        {:error, {:missing_config, path}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp connect_loaded_state(
         state,
         config,
         connector_module,
         capture_supervisor_module,
         http_server_module,
         memory_proxy_module
       ) do
    case validate_required_config(config) do
      :ok ->
        state = %{state | config: config}

        case prepare_local_runtime(
               state,
               config,
               capture_supervisor_module,
               http_server_module,
               memory_proxy_module
             ) do
          {:ok, local_state} ->
            memory_generation = %{
              id: System.unique_integer([:monotonic, :positive]),
              sent_at_ms: System.monotonic_time(:millisecond)
            }

            case connector_module.connect(config) do
              {:ok, %{channel: channel} = connection} ->
                connection =
                  Map.put(
                    connection,
                    :memory_generation,
                    Map.put(memory_generation, :channel, channel)
                  )

                case set_memory_connection(memory_proxy_module, connection, config) do
                  :ok ->
                    case set_edge_connection(connection, config, local_state) do
                      {:ok, edge_syncer} ->
                        {:ok,
                         %{
                           local_state
                           | channel: channel,
                             socket: Map.get(connection, :socket),
                             edge_syncer: edge_syncer,
                             owns_connection?: true,
                             memory_negotiation_report: worker_negotiation(connection)
                         }
                         |> monitor_channel(channel)}

                      {:error, reason} ->
                        retire_unpublished_connection(connection)
                        {:error, reason, local_state}
                    end

                  {:error, reason} ->
                    retire_unpublished_connection(connection)
                    {:error, reason, local_state}
                end

              {:error, reason} ->
                {:error, reason, local_state}
            end

          {:error, reason, local_state} ->
            {:error, reason, local_state}
        end

      {:error, {:missing_required_config, _fields} = reason} ->
        {:error, reason}
    end
  end

  defp prepare_local_runtime(
         state,
         config,
         capture_supervisor_module,
         http_server_module,
         memory_proxy_module
       ) do
    configure_memory_router(Map.get(config, :memory) || %{})

    with :ok <- set_memory_config(memory_proxy_module, config),
         {:ok, state} <-
           start_and_store(state, :capture_supervisor, fn existing_pid ->
             maybe_start_capture(capture_supervisor_module, config, existing_pid)
           end),
         {:ok, state} <-
           start_and_store(state, :memory_supervisor, fn existing_pid ->
             maybe_start_memory(config, existing_pid)
           end),
         {:ok, state} <-
           start_and_store(state, :trace_supervisor, fn existing_pid ->
             maybe_start_trace(config, existing_pid)
           end),
         {:ok, state} <-
           start_and_store(state, :http_supervisor, fn existing_pid ->
             maybe_start_http_server(http_server_module, config, existing_pid)
           end) do
      {:ok, Map.put(state, :local_settings_applied_at, DateTime.to_iso8601(DateTime.utc_now()))}
    else
      {:error, reason, failed_state} -> {:error, reason, failed_state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp worker_negotiation(%{memory: %{"selected" => selected} = memory})
       when selected == "host_memory.v2" do
    partitions =
      case memory do
        %{"partitions" => partitions} when is_list(partitions) -> partitions
        _ -> []
      end

    %{
      "selected" => selected,
      "partitions" => Enum.take(partitions, 50),
      "applied_at" => DateTime.to_iso8601(DateTime.utc_now())
    }
  end

  defp worker_negotiation(_connection), do: nil

  defp start_and_store(state, key, start_fun) do
    case start_fun.(Map.get(state, key)) do
      {:ok, pid} -> {:ok, Map.put(state, key, pid)}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp state_from_opts(opts) do
    %{
      channel: Keyword.get(opts, :channel),
      socket: Keyword.get(opts, :socket),
      channel_module: Keyword.get(opts, :channel_module, Channel),
      config: Keyword.get(opts, :config),
      desired: Keyword.get(opts, :desired),
      capture_supervisor: Keyword.get(opts, :capture_supervisor),
      http_supervisor: Keyword.get(opts, :http_supervisor),
      memory_supervisor: Keyword.get(opts, :memory_supervisor),
      edge_syncer: Keyword.get(opts, :edge_syncer),
      trace_supervisor: Keyword.get(opts, :trace_supervisor),
      installer_module: Keyword.get(opts, :installer_module, Installer),
      config_module: Keyword.get(opts, :config_module, Config),
      connector_module: Keyword.get(opts, :connector_module, Connector),
      capture_supervisor_module: Keyword.get(opts, :capture_supervisor_module, CaptureSupervisor),
      http_server_module: Keyword.get(opts, :http_server_module, HttpServer),
      memory_proxy_module: Keyword.get(opts, :memory_proxy_module, MemoryProxy),
      connect_opts: opts,
      owns_connection?: Keyword.get(opts, :owns_connection?, false),
      local_settings_applied_at: nil,
      memory_negotiation_report: nil,
      last_sync: nil,
      last_error: nil,
      sync_on_start?: Keyword.get(opts, :sync_on_start?, true),
      sync_timer_ref: nil,
      connect_retry_ref: nil,
      channel_monitor_ref: nil
    }
  end

  defp monitor_channel(state, channel) do
    if is_reference(state.channel_monitor_ref),
      do: Process.demonitor(state.channel_monitor_ref, [:flush])

    %{state | channel_monitor_ref: Process.monitor(channel)}
  end

  defp connect_or_retry(state) do
    state = retire_connection(state)

    case connect_state(Map.get(state, :connect_opts, []), state) do
      {:ok, connected_state} ->
        connected_state =
          connected_state
          |> Map.put(:last_error, nil)
          |> Map.put(:connect_retry_ref, nil)

        {:noreply, maybe_schedule_initial_sync(connected_state)}

      {:error, {:missing_config, _path} = reason} ->
        {:stop, reason, state}

      {:error, {:missing_required_config, _fields} = reason} ->
        {:stop, reason, state}

      {:error, reason, failed_state} ->
        publish_connection_error(failed_state, reason)
        Logger.warning("Host agent connect failed; retrying later: #{inspect(reason)}")

        {:noreply,
         failed_state
         |> Map.put(:last_error, reason)
         |> schedule_connect_retry()}

      {:error, reason} ->
        publish_connection_error(state, reason)
        Logger.warning("Host agent connect failed; retrying later: #{inspect(reason)}")
        {:noreply, schedule_connect_retry(%{state | last_error: reason})}
    end
  end

  defp publish_connection_error(state, reason) do
    proxy = state.memory_proxy_module

    if function_exported?(proxy, :set_connection_error, 2),
      do: proxy.set_connection_error(reason, self())
  end

  defp schedule_connect_retry(%{connect_retry_ref: ref} = state) when is_reference(ref), do: state

  defp schedule_connect_retry(state) do
    interval_ms = reconnect_interval_ms(state)
    %{state | connect_retry_ref: :erlang.start_timer(interval_ms, self(), :connect_retry)}
  end

  defp retire_connection(%{owns_connection?: true, channel: channel} = state) do
    monitored? = is_reference(Map.get(state, :channel_monitor_ref))

    if monitored?,
      do: Process.demonitor(state.channel_monitor_ref, [:flush])

    if monitored? and is_pid(channel) and channel != self() and Process.alive?(channel) do
      Channel.retire(channel)
    end

    retire_socket(Map.get(state, :socket))

    state |> Map.put(:channel, nil) |> Map.put(:socket, nil) |> Map.put(:channel_monitor_ref, nil)
  end

  defp retire_connection(state), do: state

  defp retire_unpublished_connection(%{channel: channel} = connection) do
    if is_pid(channel) and channel != self(), do: Channel.retire(channel)
    retire_socket(Map.get(connection, :socket))
  end

  defp retire_socket(socket) when is_pid(socket) and socket != self(),
    do: Channel.retire_socket(socket)

  defp retire_socket(_socket), do: :ok

  defp maybe_schedule_initial_sync(
         %{sync_on_start?: true, channel: channel, config: config} = state
       )
       when not is_nil(channel) and not is_nil(config) do
    schedule_sync(state, 0)
  end

  defp maybe_schedule_initial_sync(state), do: state

  defp schedule_next_sync(state) do
    schedule_sync(state, sync_interval_ms(state.config))
  end

  defp schedule_sync(state, interval_ms) do
    cancel_timer(state.sync_timer_ref)
    %{state | sync_timer_ref: Process.send_after(self(), :sync, interval_ms)}
  end

  defp sync_interval_ms(config) when is_map(config) do
    case Map.get(config, :interval_ms, 60_000) do
      interval_ms when is_integer(interval_ms) and interval_ms > 0 -> interval_ms
      _ -> 60_000
    end
  end

  defp sync_interval_ms(_config), do: 60_000

  defp reconnect_interval_ms(state) do
    state
    |> Map.get(:config)
    |> sync_interval_ms()
    |> min(60_000)
  end

  defp set_memory_connection(memory_proxy_module, connection, config) do
    if function_exported?(memory_proxy_module, :set_connection, 2) do
      memory_proxy_module.set_connection(connection, config)
    else
      memory_proxy_module.set_channel(connection.channel)
    end
  end

  defp set_memory_config(memory_proxy_module, config) do
    owner_result =
      if function_exported?(memory_proxy_module, :set_connection_owner, 1),
        do: memory_proxy_module.set_connection_owner(self()),
        else: :ok

    with :ok <- owner_result do
      if function_exported?(memory_proxy_module, :set_config, 1) do
        memory_proxy_module.set_config(config)
      else
        :ok
      end
    end
  end

  defp set_edge_connection(
         %{memory: %{"selected" => "host_memory.v2"}} = connection,
         config,
         state
       ) do
    edge_config = Map.get(Map.get(config, :memory) || %{}, :host_sync) || %{}

    opts = [
      channel: connection.channel,
      selected: "host_memory.v2",
      partitions: Map.get(connection.memory, "partitions", []),
      generation: connection[:memory_generation],
      extensions: Map.get(connection.memory, "extensions", []),
      poll_interval_ms: Map.get(edge_config, :sync_interval_ms, 60_000),
      mirror_opts: [config: edge_config]
    ]

    case state.edge_syncer do
      pid when is_pid(pid) ->
        if Process.alive?(pid) do
          EdgeSyncer.set_connection(pid, connection)
          {:ok, pid}
        else
          start_edge_syncer(opts, connection)
        end

      _ ->
        start_edge_syncer(opts, connection)
    end
  end

  defp set_edge_connection(_connection, _config, %{edge_syncer: pid} = _state) when is_pid(pid) do
    if Process.alive?(pid), do: EdgeSyncer.stop(pid)
    {:ok, nil}
  end

  defp set_edge_connection(_connection, _config, _state), do: {:ok, nil}

  defp start_edge_syncer(opts, connection) do
    case EdgeSyncer.start_link(opts) do
      {:ok, pid} ->
        EdgeSyncer.set_connection(pid, connection)
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        EdgeSyncer.set_connection(pid, connection)
        {:ok, pid}

      {:error, reason} ->
        {:error, {:edge_syncer_start_failed, reason}}
    end
  end

  defp cancel_timer(ref) when is_reference(ref), do: Process.cancel_timer(ref)
  defp cancel_timer(_ref), do: false

  defp maybe_start_capture(capture_supervisor_module, config, existing_pid)

  defp maybe_start_capture(capture_supervisor_module, config, existing_pid)
       when is_pid(existing_pid) do
    if Process.alive?(existing_pid) do
      {:ok, existing_pid}
    else
      maybe_start_capture(capture_supervisor_module, config, nil)
    end
  end

  defp maybe_start_capture(capture_supervisor_module, %{capture: capture_config} = config, _pid)
       when is_map(capture_config) do
    capture_config = Map.put(capture_config, :host_id, field(config, :host_id))

    case capture_supervisor_module.start_link(capture_config) do
      {:ok, pid} -> {:ok, pid}
      :ignore -> {:ok, nil}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, {:capture_start_failed, reason}}
    end
  end

  defp maybe_start_capture(_capture_supervisor_module, _config, _pid), do: {:ok, nil}

  defp maybe_start_memory(config, existing_pid \\ nil)

  defp maybe_start_memory(config, existing_pid) when is_pid(existing_pid) do
    if Process.alive?(existing_pid), do: {:ok, existing_pid}, else: maybe_start_memory(config)
  end

  defp maybe_start_memory(%{memory: %{enabled: true} = memory_config}, _existing_pid) do
    case MemorySupervisor.start_link(memory_config) do
      {:ok, pid} ->
        {:ok, pid}

      :ignore ->
        {:ok, nil}

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      {:error, reason} ->
        {:error, {:memory_start_failed, reason}}
    end
  end

  defp maybe_start_memory(_config, _existing_pid), do: {:ok, nil}

  defp maybe_start_trace(config, existing_pid \\ nil)

  defp maybe_start_trace(config, existing_pid) when is_pid(existing_pid) do
    if Process.alive?(existing_pid), do: {:ok, existing_pid}, else: maybe_start_trace(config)
  end

  defp maybe_start_trace(%{telemetry: %{enabled: true} = telemetry_config}, _existing_pid) do
    case TraceSupervisor.start_link(telemetry_config) do
      {:ok, pid} ->
        configure_trace(telemetry_config)
        {:ok, pid}

      :ignore ->
        {:ok, nil}

      {:error, {:already_started, pid}} ->
        configure_trace(telemetry_config)
        {:ok, pid}

      {:error, reason} ->
        {:error, {:trace_start_failed, reason}}
    end
  end

  defp maybe_start_trace(_config, _existing_pid), do: {:ok, nil}

  defp configure_trace(telemetry_config) do
    Application.put_env(:backplane_host_agent, :telemetry_config, telemetry_config)
  end

  defp configure_memory_router(memory_config) do
    Application.put_env(:backplane_host_agent, :memory_config, memory_config)

    Application.put_env(
      :backplane_host_agent,
      :memory_store,
      Map.get(memory_config, :store_name, Backplane.HostAgent.Memory.Store)
    )

    Application.put_env(
      :backplane_host_agent,
      :memory_host_sync,
      Map.get(memory_config, :host_sync, %{})
    )
  end

  defp validate_required_config(config) do
    missing =
      [:host_id, :hub_url, :token, :machine_name]
      |> Enum.filter(fn key ->
        value = field(config, key)

        is_nil(value) or value == "" or
          value in ["REPLACE_WITH_AUTH_TOKEN", "REPLACE_WITH_AGENT_ID"]
      end)

    case missing do
      [] -> :ok
      fields -> {:error, {:missing_required_config, fields}}
    end
  end

  defp maybe_start_http_server(http_server_module, config, existing_pid \\ nil)

  defp maybe_start_http_server(http_server_module, config, existing_pid)
       when is_pid(existing_pid) do
    if Process.alive?(existing_pid) do
      {:ok, existing_pid}
    else
      maybe_start_http_server(http_server_module, config)
    end
  end

  defp maybe_start_http_server(http_server_module, config, _existing_pid) do
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

    case installer_module.install(skill, installer_config(state)) do
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

  defp fail_run(%{owns_connection?: true} = state, reason)
       when reason == :not_connected or channel_exit_reason(reason) do
    state =
      state
      |> retire_connection()
      |> Map.put(:last_error, reason)
      |> schedule_connect_retry()

    {:error, reason, state}
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
  catch
    :exit, reason -> {:error, {:channel_exit, reason}}
  end

  defp skills(%{"skills" => skills}) when is_list(skills), do: skills
  defp skills(%{skills: skills}) when is_list(skills), do: skills
  defp skills(_desired_state), do: []

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

  defp installer_config(state) do
    state
    |> Map.fetch!(:config)
    |> Map.put(:channel, Map.get(state, :channel))
    |> Map.put(:channel_module, Map.get(state, :channel_module, Channel))
  end

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

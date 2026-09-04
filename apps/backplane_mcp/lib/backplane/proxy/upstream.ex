defmodule Backplane.Proxy.Upstream do
  @moduledoc """
  Coordinates one configured upstream MCP server through the protocol client.

  The protocol package owns negotiation, transport framing, request IDs,
  Streamable HTTP sessions, and stdio ports. This GenServer owns the Backplane
  lifecycle: catalog registration, health checks, call degradation, and one
  monitored reconnect loop.
  """

  use GenServer
  require Logger

  alias Backplane.McpProtocol.Client
  alias Backplane.McpProtocol.MCP.Response
  alias Backplane.McpProtocol.Protocol.Registry, as: ProtocolRegistry
  alias Backplane.Observability.Event
  alias Backplane.Observability.{Context, Error, Id}
  alias Backplane.Proxy.{ClientLeaseManager, ClientPool, ProtocolClient, ToolCatalog}
  alias Backplane.PubSubBroadcaster
  alias Backplane.Registry.ToolRegistry

  @default_timeout 30_000
  @refresh_interval 300_000
  @health_ping_interval 60_000
  @max_consecutive_failures 3
  @initial_backoff_ms 1_000
  @max_backoff_ms 60_000
  @supported_transports ~w(http stdio)

  # Client API

  def start_link(config) do
    GenServer.start_link(__MODULE__, config)
  end

  @doc """
  Forward a tool call to this upstream server.

  The optional `timeout` parameter remains both the package operation deadline
  and the caller's GenServer deadline.
  """
  @spec forward(pid(), String.t(), map(), pos_integer()) :: {:ok, term()} | {:error, term()}
  def forward(pid, tool_name, arguments, timeout \\ @default_timeout) do
    GenServer.call(pid, {:tools_call, tool_name, arguments, timeout, nil}, timeout)
    |> normalize_reply()
  catch
    :exit, {:timeout, _} -> {:error, "Upstream timeout after #{timeout}ms"}
    :exit, _reason -> {:error, "Upstream connection error"}
  end

  @doc """
  Forward a tool call with parent observability context for child span recording.
  """
  @spec forward(pid(), String.t(), map(), pos_integer(), map()) ::
          {:ok, term(), map()} | {:error, term(), map()}
  def forward(pid, tool_name, arguments, timeout, %{context: %Context{}} = observability)
      when is_integer(timeout) and timeout > 0 do
    GenServer.call(pid, {:tools_call, tool_name, arguments, timeout, observability}, timeout)
    |> normalize_observability_reply()
  catch
    :exit, {:timeout, _} ->
      meta = timeout_meta(timeout)
      emit_upstream_exception(observability, tool_name, timeout, meta, "timeout")
      {:error, "Upstream timeout after #{timeout}ms", meta}

    :exit, _reason ->
      meta = %{attempt_count: 1, outcome: "error", error_kind: "upstream"}
      emit_upstream_exception(observability, tool_name, timeout, meta, "connection")
      {:error, "Upstream connection error", meta}
  end

  @doc "Get the status of this upstream connection."
  @spec status(pid()) :: map()
  def status(pid), do: GenServer.call(pid, :status)

  @doc "Trigger a tool refresh."
  @spec refresh(pid()) :: :ok
  def refresh(pid), do: GenServer.cast(pid, :refresh)

  @doc false
  @spec prepare_stop(pid(), timeout()) :: :ok
  def prepare_stop(pid, timeout \\ 5_000), do: GenServer.call(pid, :prepare_stop, timeout)

  # Server implementation

  @impl true
  def init(config) do
    if config.transport in @supported_transports do
      options = ProtocolClient.client_options(config)

      state = %{
        name: config.name,
        prefix: config.prefix,
        transport: config.transport,
        config: config,
        client: ProtocolClient.client_name(config.prefix),
        client_supervisor: nil,
        client_monitor: nil,
        protocol_preference: configured_preference(config),
        negotiated_version: nil,
        era: nil,
        negotiation_status: :connecting,
        server_info: nil,
        server_capabilities: nil,
        tools: [],
        status: :connecting,
        reconnect_attempts: 0,
        consecutive_call_failures: 0,
        consecutive_ping_failures: 0,
        last_ping_at: nil,
        last_pong_at: nil,
        tool_timeout: Keyword.fetch!(options, :timeout),
        refresh_interval: Map.get(config, :refresh_interval),
        reconnect_timer: nil,
        refresh_timer: nil,
        health_timer: nil,
        stopping: false,
        pool_owned: false
      }

      {:ok, state, {:continue, :connect}}
    else
      {:stop, {:unsupported_transport, config.transport}}
    end
  end

  @impl true
  def handle_continue(:connect, %{client_supervisor: supervisor} = state)
      when is_pid(supervisor) do
    {:noreply, state}
  end

  def handle_continue(:connect, state) do
    state =
      state
      |> cancel_timer(:reconnect_timer)
      |> Map.put(:status, :connecting)

    case start_client_tree(state) do
      {:ok, supervisor, pool_owned} ->
        monitor = Process.monitor(supervisor)

        connecting = %{
          state
          | client_supervisor: supervisor,
            client_monitor: monitor,
            pool_owned: pool_owned
        }

        case connect_client(connecting) do
          {:ok, connected} ->
            connected = connected |> schedule_refresh() |> schedule_health()

            PubSubBroadcaster.broadcast_upstream(connected.prefix, :connected, %{
              name: connected.name
            })

            {:noreply, connected}

          {:error, reason, failed} ->
            {:noreply, disconnect(failed, reason)}
        end

      {:error, reason} ->
        {:noreply, disconnect(state, reason)}
    end
  end

  @impl true
  def handle_call(:prepare_stop, _from, state) do
    {:reply, :ok, stop_owned_resources(state)}
  end

  def handle_call(
        {:tools_call, tool_name, _arguments, timeout, observability},
        _from,
        %{stopping: true} = state
      ) do
    reply =
      if observability do
        {:error, "Upstream connection error",
         upstream_meta(state, tool_name, timeout, "error", observability)}
      else
        {:error, "Upstream connection error"}
      end

    {:reply, reply, state}
  end

  def handle_call({:tools_call, tool_name, arguments, timeout}, from, state) do
    handle_call({:tools_call, tool_name, arguments, timeout, nil}, from, state)
  end

  def handle_call({:tools_call, tool_name, arguments, timeout, observability}, _from, state) do
    started_ms = System.monotonic_time(:millisecond)

    case call_tool(state, tool_name, arguments, timeout) do
      {:ok, result} ->
        meta = upstream_meta(state, tool_name, timeout, "success", observability, started_ms)
        maybe_emit_upstream_stop(observability, tool_name, timeout, meta, nil)
        reply = if observability, do: {:ok, result, meta}, else: {:ok, result}
        {:reply, reply, track_call_result(state, {:ok, result})}

      {:error, reason, :protocol} ->
        message = ProtocolClient.error_message(reason)
        result = {:error, message}

        meta =
          upstream_meta(
            state,
            tool_name,
            timeout,
            "error",
            observability,
            started_ms,
            reason,
            :protocol
          )

        maybe_emit_upstream_stop(observability, tool_name, timeout, meta, message)
        reply = if observability, do: {:error, message, meta}, else: result
        {:reply, reply, track_call_result(state, result)}

      {:error, reason, :connection} ->
        message = ProtocolClient.error_message(reason)
        result = {:error, message}

        meta =
          upstream_meta(
            state,
            tool_name,
            timeout,
            "error",
            observability,
            started_ms,
            reason,
            :connection
          )

        maybe_emit_upstream_stop(observability, tool_name, timeout, meta, message)
        reply = if observability, do: {:error, message, meta}, else: result
        {:reply, reply, disconnect(state, reason)}
    end
  end

  def handle_call(:status, _from, state) do
    {negotiated_version, era, negotiation_status} = safe_negotiation_status(state)

    info = %{
      name: state.name,
      prefix: state.prefix,
      transport: state.transport,
      status: state.status,
      tool_count: length(state.tools),
      last_ping_at: state.last_ping_at,
      last_pong_at: state.last_pong_at,
      consecutive_ping_failures: state.consecutive_ping_failures,
      post_url_known: false,
      protocol_preference: state.protocol_preference,
      negotiated_version: negotiated_version,
      era: era,
      negotiation_status: negotiation_status
    }

    {:reply, info, state}
  end

  @impl true
  def handle_cast(:refresh, %{stopping: true} = state), do: {:noreply, state}

  def handle_cast(:refresh, state) do
    {:noreply, state |> cancel_timer(:refresh_timer) |> refresh_now()}
  end

  @impl true
  def handle_info(_message, %{stopping: true} = state), do: {:noreply, state}

  def handle_info(:refresh, state) do
    {:noreply, state |> cancel_timer(:refresh_timer) |> refresh_now()}
  end

  def handle_info({:refresh, token}, %{refresh_timer: {_timer, token}} = state) do
    {:noreply, state |> Map.put(:refresh_timer, nil) |> refresh_now()}
  end

  def handle_info({:refresh, _stale_token}, state), do: {:noreply, state}

  def handle_info(:reconnect, %{client_supervisor: nil} = state) do
    state = cancel_timer(state, :reconnect_timer)
    {:noreply, %{state | status: :connecting}, {:continue, :connect}}
  end

  def handle_info(:reconnect, state), do: {:noreply, state}

  def handle_info(
        {:reconnect, token},
        %{reconnect_timer: {_timer, token}, client_supervisor: nil} = state
      ) do
    {:noreply, %{state | reconnect_timer: nil, status: :connecting}, {:continue, :connect}}
  end

  def handle_info({:reconnect, _stale_token}, state), do: {:noreply, state}

  def handle_info(:health_ping, state) do
    {:noreply, state |> cancel_timer(:health_timer) |> health_now()}
  end

  def handle_info({:health_ping, token}, %{health_timer: {_timer, token}} = state) do
    {:noreply, state |> Map.put(:health_timer, nil) |> health_now()}
  end

  def handle_info({:health_ping, _stale_token}, state), do: {:noreply, state}

  def handle_info(
        {:DOWN, monitor, :process, supervisor, reason},
        %{client_monitor: monitor, client_supervisor: supervisor} = state
      ) do
    detach_client(state, supervisor)
    state = %{state | client_monitor: nil, client_supervisor: nil}
    {:noreply, disconnect(state, reason)}
  end

  def handle_info({:DOWN, _monitor, :process, _supervisor, _reason}, state),
    do: {:noreply, state}

  def handle_info(message, state) do
    Logger.debug("Upstream received an unexpected message",
      upstream: state.name,
      message: inspect(message, limit: 5, printable_limit: 128)
    )

    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    _state = stop_owned_resources(state)
    :ok
  end

  # Connection and catalog

  defp connect_client(state) do
    with :ok <- await_ready(state),
         {:ok, info} <- protocol_info(state),
         {:ok, tools} <- fetch_catalog(state) do
      ToolRegistry.register_upstream(state.prefix, self(), tools)
      broadcast_tools_refreshed(state, tools)

      {:ok,
       %{
         state
         | negotiated_version: info.negotiated_version,
           era: info.era,
           negotiation_status: info.negotiation_status,
           server_info: info.server_info,
           server_capabilities: info.server_capabilities,
           tools: tools,
           status: :connected,
           reconnect_attempts: 0,
           consecutive_call_failures: 0,
           consecutive_ping_failures: 0
       }}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp await_ready(state) do
    case safe_client_call(fn -> Client.await_ready(state.client, timeout: state.tool_timeout) end) do
      {:ok, :ok} -> :ok
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
      {:ok, _invalid} -> {:error, :invalid_ready_result}
    end
  end

  defp protocol_info(state) do
    case safe_client_call(fn ->
           Client.get_protocol_info(state.client, timeout: state.tool_timeout)
         end) do
      {:ok,
       %{
         negotiated_version: version,
         era: era,
         negotiation_status: :ready,
         server_info: server_info,
         server_capabilities: server_capabilities
       } = info}
      when is_binary(version) and era in [:legacy, :modern] and
             (is_map(server_info) or is_nil(server_info)) and is_map(server_capabilities) ->
        {:ok, info}

      {:ok, _invalid} ->
        {:error, :invalid_protocol_info}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_catalog(state) do
    with {:ok, raw_tools} <- ToolCatalog.fetch_all(&list_tools_page(state, &1)),
         {:ok, tools} <-
           ToolCatalog.normalize_all(raw_tools, state.prefix, self(), state.tool_timeout) do
      {:ok, apply_tool_timeouts(tools, state.config, state.tool_timeout)}
    end
  end

  defp list_tools_page(state, nil) do
    client_result(fn -> Client.list_tools(state.client, timeout: state.tool_timeout) end)
  end

  defp list_tools_page(state, cursor) do
    client_result(fn ->
      Client.list_tools(state.client, cursor: cursor, timeout: state.tool_timeout)
    end)
  end

  defp client_result(fun) do
    case safe_client_call(fun) do
      {:ok, result} -> result
      {:error, _reason} -> {:error, :client_unavailable}
    end
  end

  defp apply_tool_timeouts(tools, config, default_timeout) do
    configured = Map.get(config, :tool_timeouts)
    configured = if is_map(configured), do: configured, else: %{}

    Enum.map(tools, fn tool ->
      timeout =
        case Map.get(configured, tool.original_name) do
          timeout when is_integer(timeout) and timeout > 0 -> timeout
          _missing_or_invalid -> default_timeout
        end

      %{tool | timeout: timeout}
    end)
  end

  defp refresh_now(%{status: status} = state) when status in [:connecting, :disconnected] do
    state
  end

  defp refresh_now(state) do
    case fetch_catalog(state) do
      {:ok, tools} ->
        ToolRegistry.register_upstream(state.prefix, self(), tools)
        broadcast_tools_refreshed(state, tools)

        state
        |> Map.merge(%{tools: tools, status: :connected, reconnect_attempts: 0})
        |> schedule_refresh()

      {:error, reason} ->
        if client_tree_available?(state) do
          schedule_refresh(state)
        else
          disconnect(state, reason)
        end
    end
  end

  # Calls and health

  defp call_tool(%{client_supervisor: nil}, _tool_name, _arguments, _timeout),
    do: {:error, :not_connected, :connection}

  defp call_tool(state, tool_name, arguments, timeout) do
    case safe_client_call(fn ->
           Client.call_tool(state.client, tool_name, arguments, timeout: timeout)
         end) do
      {:ok, {:ok, %Response{result: result}}} -> {:ok, result}
      {:ok, {:error, reason}} -> {:error, reason, :protocol}
      {:ok, _invalid} -> {:error, :invalid_tool_response, :protocol}
      {:error, reason} -> {:error, reason, :connection}
    end
  end

  defp health_now(%{status: status} = state) when status in [:connecting, :disconnected],
    do: state

  defp health_now(state) do
    now = System.system_time(:second)
    checking = %{state | last_ping_at: now}

    result =
      case state.era do
        :legacy -> legacy_ping(checking)
        :modern -> fetch_catalog(checking)
        _unknown -> {:error, :not_ready}
      end

    case result do
      :pong ->
        health_success(checking, now)

      {:ok, tools} when state.era == :modern ->
        ToolRegistry.register_upstream(state.prefix, self(), tools)
        broadcast_tools_refreshed(state, tools)
        health_success(%{checking | tools: tools}, now)

      {:error, reason} ->
        if client_tree_available?(state) do
          health_failure(checking, reason)
        else
          disconnect(checking, reason)
        end
    end
  end

  defp legacy_ping(state) do
    case safe_client_call(fn -> Client.ping(state.client, timeout: state.tool_timeout) end) do
      {:ok, :pong} -> :pong
      {:ok, {:error, reason}} -> {:error, reason}
      {:ok, _invalid} -> {:error, :invalid_ping_result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp health_success(state, now) do
    state
    |> Map.merge(%{
      last_pong_at: now,
      consecutive_ping_failures: 0,
      status: :connected
    })
    |> schedule_health()
  end

  defp health_failure(state, reason) do
    failures = state.consecutive_ping_failures + 1

    Logger.warning("Upstream health check failed",
      upstream: state.name,
      reason: ProtocolClient.error_message(reason),
      consecutive_failures: failures
    )

    status = if failures >= @max_consecutive_failures, do: :degraded, else: state.status

    state
    |> Map.merge(%{consecutive_ping_failures: failures, status: status})
    |> schedule_health()
  end

  defp track_call_result(state, {:ok, _result}) do
    %{state | consecutive_call_failures: 0, status: :connected}
  end

  defp track_call_result(state, {:error, _reason}) do
    failures = state.consecutive_call_failures + 1

    status =
      cond do
        state.status in [:connecting, :disconnected] -> state.status
        failures >= @max_consecutive_failures -> :degraded
        true -> state.status
      end

    %{state | consecutive_call_failures: failures, status: status}
  end

  # Lifecycle and timers

  defp stop_owned_resources(state) do
    state =
      state
      |> Map.put(:stopping, true)
      |> cancel_all_timers()
      |> stop_client_tree()

    ToolRegistry.deregister_upstream(state.prefix, self())
    release_client_lease(state)

    Map.merge(state, %{
      tools: [],
      status: :disconnected,
      negotiated_version: nil,
      era: nil,
      negotiation_status: :connecting,
      server_info: nil,
      server_capabilities: nil
    })
  end

  defp disconnect(state, reason) do
    message = ProtocolClient.error_message(reason)

    Logger.warning("Upstream connection unavailable", upstream: state.name, reason: message)

    state =
      state
      |> cancel_timer(:refresh_timer)
      |> cancel_timer(:health_timer)
      |> stop_client_tree()

    ToolRegistry.deregister_upstream(state.prefix, self())

    PubSubBroadcaster.broadcast_upstream(state.prefix, :disconnected, %{
      name: state.name,
      reason: message
    })

    attempt = state.reconnect_attempts

    state
    |> Map.merge(%{
      tools: [],
      status: :disconnected,
      negotiated_version: nil,
      era: nil,
      negotiation_status: :connecting,
      server_info: nil,
      server_capabilities: nil,
      reconnect_attempts: attempt + 1
    })
    |> schedule_reconnect(attempt)
  end

  defp stop_client_tree(state) do
    client_supervisor = state.client_supervisor

    if is_reference(state.client_monitor) do
      Process.demonitor(state.client_monitor, [:flush])
    end

    if is_pid(client_supervisor) do
      stop_client(state, client_supervisor)
    end

    %{state | client_supervisor: nil, client_monitor: nil}
  end

  defp client_tree_available?(state) do
    is_pid(state.client_supervisor) and Process.alive?(state.client_supervisor) and
      is_pid(GenServer.whereis(state.client))
  catch
    :exit, _reason -> false
  end

  defp safe_client_call(fun) do
    {:ok, fun.()}
  rescue
    _exception -> {:error, :client_unavailable}
  catch
    :exit, _reason -> {:error, :client_unavailable}
    _kind, _reason -> {:error, :client_unavailable}
  end

  defp start_client_tree(state) do
    options = ProtocolClient.client_options(state.config)

    case ClientLeaseManager.start_client(self(), state.prefix, options) do
      {:ok, supervisor} ->
        {:ok, supervisor, true}

      {:error, :not_owned} ->
        case ClientPool.start_client(options) do
          {:ok, supervisor} -> {:ok, supervisor, false}
          {:error, _reason} = error -> error
        end

      {:error, _reason} = error ->
        error
    end
  catch
    :exit, _reason ->
      ClientLeaseManager.cleanup(self())
      {:error, :client_lease_manager_unavailable}
  end

  defp detach_client(%{pool_owned: true}, client_supervisor) do
    ClientLeaseManager.detach_client(self(), client_supervisor)
  end

  defp detach_client(_state, _client_supervisor), do: :ok

  defp stop_client(%{pool_owned: true}, client_supervisor) do
    ClientLeaseManager.stop_client(self(), client_supervisor)
  end

  defp stop_client(_state, client_supervisor) do
    try do
      _ = ClientPool.stop_client(client_supervisor)
    rescue
      _exception -> :ok
    catch
      :exit, _reason -> :ok
    end
  end

  defp release_client_lease(%{pool_owned: true}), do: ClientLeaseManager.cleanup(self())
  defp release_client_lease(_state), do: :ok

  defp configured_preference(config) do
    case ProtocolClient.protocol_preference(config) do
      :auto -> "auto"
      version -> version
    end
  end

  defp safe_negotiation_status(%{
         negotiated_version: version,
         era: era,
         negotiation_status: :ready
       })
       when is_binary(version) and era in [:legacy, :modern] do
    case ProtocolRegistry.profile(version) do
      {:ok, %{era: ^era}} -> {version, era, :ready}
      _unknown_or_mismatched -> {nil, nil, :connecting}
    end
  end

  defp safe_negotiation_status(%{negotiation_status: :ready}),
    do: {nil, nil, :connecting}

  defp safe_negotiation_status(state) do
    {nil, nil, state.negotiation_status}
  end

  defp broadcast_tools_refreshed(state, tools) do
    PubSubBroadcaster.broadcast_upstream(state.prefix, :tools_refreshed, %{
      name: state.name,
      tool_count: length(tools)
    })
  end

  defp schedule_refresh(state) do
    interval =
      if is_integer(state.refresh_interval) and state.refresh_interval > 0,
        do: state.refresh_interval,
        else: @refresh_interval

    schedule_timer(state, :refresh_timer, :refresh, interval)
  end

  defp schedule_health(state) do
    schedule_timer(state, :health_timer, :health_ping, @health_ping_interval)
  end

  defp schedule_reconnect(state, attempt) do
    base_delay = min(@initial_backoff_ms * Integer.pow(2, attempt), @max_backoff_ms)
    jitter = div(base_delay, 4)
    delay = base_delay - jitter + :rand.uniform(max(jitter * 2, 1))
    schedule_timer(state, :reconnect_timer, :reconnect, delay)
  end

  defp schedule_timer(state, field, message, delay) do
    state = cancel_timer(state, field)
    token = make_ref()
    timer = Process.send_after(self(), {message, token}, delay)
    Map.put(state, field, {timer, token})
  end

  defp cancel_timer(state, field) do
    case Map.get(state, field) do
      {timer, _token} when is_reference(timer) -> Process.cancel_timer(timer)
      _missing -> :ok
    end

    Map.put(state, field, nil)
  end

  defp cancel_all_timers(state) do
    state
    |> cancel_timer(:reconnect_timer)
    |> cancel_timer(:refresh_timer)
    |> cancel_timer(:health_timer)
  end

  defp normalize_reply({:ok, result}), do: {:ok, result}
  defp normalize_reply({:error, reason}), do: {:error, reason}
  defp normalize_reply(other), do: other

  defp normalize_observability_reply({:ok, result, meta}), do: {:ok, result, meta}
  defp normalize_observability_reply({:error, reason, meta}), do: {:error, reason, meta}
  defp normalize_observability_reply(other), do: other

  defp upstream_meta(
         state,
         original_tool_name,
         timeout,
         outcome,
         observability,
         started_ms \\ nil,
         reason \\ nil,
         category \\ nil
       ) do
    {negotiated_version, _, _} = safe_negotiation_status(state)

    duration_ms =
      if is_integer(started_ms) do
        System.monotonic_time(:millisecond) - started_ms
      else
        nil
      end

    %{
      upstream_name: state.name,
      upstream_prefix: state.prefix,
      upstream_transport: state.transport,
      upstream_protocol_version: negotiated_version,
      original_tool_name: original_tool_name,
      timeout_ms: timeout,
      attempt_count: 1,
      duration_ms: duration_ms,
      outcome: outcome,
      error_kind: upstream_error_kind(category, reason)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
    |> maybe_put_observability(observability)
  end

  defp maybe_put_observability(meta, nil), do: meta
  defp maybe_put_observability(meta, _observability), do: meta

  defp upstream_error_kind(:protocol, _reason), do: "protocol"
  defp upstream_error_kind(:connection, _reason), do: "upstream"
  defp upstream_error_kind(_category, _reason), do: nil

  defp maybe_emit_upstream_stop(nil, _tool_name, _timeout, _meta, _error_message), do: :ok

  defp maybe_emit_upstream_stop(
         %{context: parent_context},
         tool_name,
         _timeout,
         meta,
         error_message
       ) do
    upstream_context = Context.child(parent_context)
    event_id = Id.generator().event_id()

    _error =
      if meta[:outcome] == "success" do
        nil
      else
        Error.normalize(error_message || "upstream error",
          kind: meta[:error_kind] || "upstream",
          source: "mcp_upstream"
        )
      end

    Event.emit_stop(:mcp_proxy, "upstream", upstream_context,
      event_id: event_id,
      measurements: %{duration_ms: meta[:duration_ms]},
      attributes: Map.put(meta, :original_tool_name, tool_name)
    )
  end

  defp emit_upstream_exception(%{context: parent_context}, tool_name, timeout, meta, kind) do
    upstream_context = Context.child(parent_context)

    message =
      if kind == "timeout",
        do: "Upstream timeout after #{timeout}ms",
        else: "Upstream connection error"

    Event.emit_stop(:mcp_proxy, "upstream", upstream_context,
      event_id: Id.generator().event_id(),
      measurements: %{duration_ms: meta[:duration_ms]},
      attributes: Map.merge(meta, %{original_tool_name: tool_name, outcome: "error"}),
      error: Error.normalize(message, kind: meta[:error_kind] || kind, source: "mcp_upstream")
    )
  end

  defp timeout_meta(timeout) do
    %{
      attempt_count: 1,
      outcome: "error",
      error_kind: "timeout",
      timeout_ms: timeout,
      duration_ms: timeout
    }
  end
end

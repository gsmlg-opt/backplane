defmodule Backplane.Proxy.Upstream do
  @moduledoc """
  Coordinates one configured upstream MCP server through the protocol client.

  The protocol package owns negotiation, transport framing, request IDs,
  Streamable HTTP sessions, and stdio ports. This GenServer owns the Backplane
  lifecycle: catalog registration, health checks, call degradation, bounded
  non-blocking per-request execution, and one monitored reconnect loop.

  Health and catalog refresh share one monitored control worker per upstream.
  Repeated health/refresh triggers coalesce into one pending operation of each
  kind, served in arrival order. Catalog pages share one absolute timeout budget.
  Results are accepted only for the original client process and supervisor, and
  control workers are stopped on timeout, disconnect and shutdown.
  """

  use GenServer
  require Logger

  alias Backplane.McpProtocol.Client
  alias Backplane.McpProtocol.Client.ToolCall
  alias Backplane.McpProtocol.MCP.Error, as: McpError
  alias Backplane.McpProtocol.MCP.Response
  alias Backplane.McpProtocol.Protocol.Registry, as: ProtocolRegistry
  alias Backplane.Observability.Event
  alias Backplane.Observability.{Context, Error, Id}
  alias Backplane.Proxy.{ClientLeaseManager, ClientPool, ProtocolClient, ToolCatalog}
  alias Backplane.PubSubBroadcaster
  alias Backplane.Registry.ToolRegistry

  @default_timeout 30_000
  @default_max_concurrent_calls 32
  @default_max_queued_calls 128
  @registration_timeout_ms 5_000
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

  The absolute monotonic deadline is captured once at admission and enforced
  through queueing, dispatch, and response handling.
  """
  @spec forward(pid(), String.t(), map(), pos_integer() | keyword()) ::
          {:ok, term()} | {:error, term()}
  def forward(pid, tool_name, arguments, timeout_or_opts \\ @default_timeout)

  def forward(pid, tool_name, arguments, opts) when is_list(opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    observability = Keyword.get(opts, :observability)
    do_forward(pid, tool_name, arguments, timeout, observability, opts)
  end

  def forward(pid, tool_name, arguments, timeout) do
    do_forward(pid, tool_name, arguments, timeout, nil, [])
  end

  @doc """
  Forward a tool call with parent observability context or explicit request options.
  """
  @spec forward(pid(), String.t(), map(), pos_integer(), map() | keyword()) ::
          {:ok, term()} | {:error, term()} | {:ok, term(), map()} | {:error, term(), map()}
  def forward(pid, tool_name, arguments, timeout, %{context: %Context{}} = observability)
      when is_integer(timeout) do
    opts =
      case Map.get(observability, :deadline_ms) do
        deadline_ms when is_integer(deadline_ms) -> [deadline_ms: deadline_ms]
        _missing -> []
      end

    do_forward(pid, tool_name, arguments, timeout, observability, opts)
  end

  def forward(pid, tool_name, arguments, timeout, opts)
      when is_integer(timeout) and is_list(opts) do
    observability = Keyword.get(opts, :observability)
    do_forward(pid, tool_name, arguments, timeout, observability, opts)
  end

  @doc "Cancel an admitted or in-flight tool call by request reference."
  @spec cancel_forward(pid(), reference(), atom()) :: :ok
  def cancel_forward(pid, request_ref, reason \\ :cancelled)
      when is_pid(pid) and is_reference(request_ref) and is_atom(reason) do
    GenServer.cast(pid, {:cancel_tool_call, request_ref, reason})
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

  defp do_forward(pid, tool_name, arguments, timeout, observability, opts) do
    started_ms = System.monotonic_time(:millisecond)
    effective_timeout = if is_integer(timeout) and timeout > 0, do: timeout, else: 0

    deadline_ms =
      case Keyword.get(opts, :deadline_ms) do
        deadline when is_integer(deadline) -> deadline
        _missing -> started_ms + effective_timeout
      end

    request_ref =
      case Keyword.get(opts, :request_ref) do
        ref when is_reference(ref) -> ref
        _missing -> make_ref()
      end

    remaining = deadline_ms - started_ms

    if remaining <= 0 do
      forward_timeout_error(observability, tool_name, timeout, 0)
    else
      request =
        {:forward_request,
         %{
           request_ref: request_ref,
           deadline_ms: deadline_ms,
           started_ms: started_ms,
           caller_pid: self(),
           observability: observability
         }}

      try do
        pid
        |> GenServer.call({:tools_call, tool_name, arguments, timeout, request}, remaining)
        |> normalize_forward_reply(observability)
      catch
        :exit, {:timeout, _} ->
          GenServer.cast(pid, {:cancel_tool_call, request_ref, :timeout})
          elapsed = max(System.monotonic_time(:millisecond) - started_ms, 0)
          forward_timeout_error(observability, tool_name, timeout, elapsed)

        :exit, _reason ->
          forward_connection_error(observability, tool_name, timeout)
      end
    end
  end

  defp forward_timeout_error(nil, _tool_name, timeout, _elapsed) do
    {:error, "Upstream timeout after #{timeout}ms"}
  end

  defp forward_timeout_error(observability, tool_name, timeout, elapsed) do
    meta = timeout_meta(timeout, elapsed)
    emit_upstream_exception(observability, tool_name, timeout, meta, "timeout")
    {:error, "Upstream timeout after #{timeout}ms", meta}
  end

  defp forward_connection_error(nil, _tool_name, _timeout) do
    {:error, "Upstream connection error"}
  end

  defp forward_connection_error(observability, tool_name, timeout) do
    meta = %{attempt_count: 1, outcome: "error", error_kind: "upstream"}
    emit_upstream_exception(observability, tool_name, timeout, meta, "connection")
    {:error, "Upstream connection error", meta}
  end

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
        max_concurrent_calls: configured_max_concurrent_calls(config),
        max_queued_calls: configured_max_queued_calls(config),
        in_flight: %{},
        client_refs: %{},
        caller_monitors: %{},
        client_monitors: %{},
        queue: :queue.new(),
        queued_entries: %{},
        reconnect_timer: nil,
        refresh_timer: nil,
        health_timer: nil,
        control_operation: nil,
        pending_controls: [],
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

  def handle_call({:tools_call, tool_name, arguments, timeout}, from, state) do
    handle_call({:tools_call, tool_name, arguments, timeout, nil}, from, state)
  end

  def handle_call(
        {:tools_call, tool_name, arguments, timeout, {:forward_request, request}},
        from,
        state
      ) do
    admit_tool_call(state, from, tool_name, arguments, timeout, request)
  end

  def handle_call({:tools_call, tool_name, arguments, timeout, observability}, from, state) do
    now = System.monotonic_time(:millisecond)
    effective_timeout = if is_integer(timeout) and timeout > 0, do: timeout, else: 0

    request = %{
      request_ref: make_ref(),
      deadline_ms: now + effective_timeout,
      started_ms: now,
      caller_pid: elem(from, 0),
      observability: observability
    }

    admit_tool_call(state, from, tool_name, arguments, timeout, request)
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
      negotiation_status: negotiation_status,
      in_flight_calls: map_size(state.in_flight),
      queued_calls: map_size(state.queued_entries),
      max_concurrent_calls: state.max_concurrent_calls,
      max_queued_calls: state.max_queued_calls
    }

    {:reply, info, state}
  end

  @impl true
  def handle_cast(:refresh, %{stopping: true} = state), do: {:noreply, state}

  def handle_cast(:refresh, state) do
    {:noreply, state |> cancel_timer(:refresh_timer) |> refresh_now()}
  end

  def handle_cast({:cancel_tool_call, _request_ref, _reason}, %{stopping: true} = state),
    do: {:noreply, state}

  def handle_cast({:cancel_tool_call, request_ref, reason}, state) do
    {:noreply, cancel_request(state, request_ref, reason)}
  end

  @impl true
  def handle_info(_message, %{stopping: true} = state), do: {:noreply, state}

  def handle_info({:control_result, ref, result}, %{control_operation: %{ref: ref} = op} = state) do
    {:noreply, settle_control(state, op, result)}
  end

  def handle_info({:control_result, _stale_ref, _result}, state), do: {:noreply, state}

  def handle_info({:control_timeout, ref}, %{control_operation: %{ref: ref} = op} = state) do
    {:noreply, settle_control(state, op, {:error, :timeout})}
  end

  def handle_info({:control_timeout, _stale_ref}, state), do: {:noreply, state}

  def handle_info(
        {:DOWN, monitor, :process, _pid, _reason},
        %{control_operation: %{monitor: monitor} = op} = state
      ) do
    {:noreply, settle_control(state, op, {:error, :control_worker_down})}
  end

  def handle_info({ToolCall, reply_ref, result}, state) do
    {:noreply, handle_tool_call_result(state, reply_ref, result)}
  end

  def handle_info({:request_deadline, request_ref}, state) do
    {:noreply, handle_request_deadline(state, request_ref)}
  end

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

  def handle_info({:DOWN, monitor, :process, pid, reason}, state) do
    case Map.pop(state.caller_monitors, monitor) do
      {request_ref, caller_monitors} when is_reference(request_ref) ->
        state = %{state | caller_monitors: caller_monitors}
        {:noreply, handle_caller_down(state, request_ref)}

      {nil, _caller_monitors} ->
        case find_client_monitor(state, monitor, pid) do
          {:ok, request_refs} ->
            {:noreply, handle_client_process_down(state, pid, request_refs, reason)}

          :error ->
            {:noreply, state}
        end
    end
  end

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

  # Bounded per-request admission, scheduling, and retirement

  defp admit_tool_call(state, from, tool_name, arguments, timeout, request) do
    entry = %{
      request_ref: request.request_ref,
      from: from,
      caller_pid: request.caller_pid,
      caller_mon: nil,
      tool_name: tool_name,
      arguments: arguments,
      timeout: timeout,
      deadline_ms: request.deadline_ms,
      started_ms: request.started_ms,
      observability: request.observability,
      timer_ref: nil,
      client_handle: nil,
      client_pid: nil,
      client_reply_ref: nil
    }

    now = System.monotonic_time(:millisecond)
    remaining = entry.deadline_ms - now

    cond do
      state.stopping ->
        reply_connection_error(state, entry, "Upstream connection error")
        {:noreply, state}

      not Process.alive?(entry.caller_pid) ->
        {:noreply, state}

      remaining <= 0 ->
        reply_timeout(state, entry)
        {:noreply, state}

      is_nil(state.client_supervisor) or state.status in [:connecting, :disconnected] ->
        reply_connection_error(state, entry, ProtocolClient.error_message(:not_connected))
        {:noreply, state}

      map_size(state.in_flight) < state.max_concurrent_calls and
          map_size(state.queued_entries) == 0 ->
        {:noreply, dispatch_entry(state, entry)}

      map_size(state.queued_entries) < state.max_queued_calls ->
        {:noreply, enqueue_entry(state, entry, remaining)}

      true ->
        reply_overloaded(state, entry)
        {:noreply, state}
    end
  end

  defp enqueue_entry(state, entry, remaining) do
    caller_mon = Process.monitor(entry.caller_pid)
    timer_ref = Process.send_after(self(), {:request_deadline, entry.request_ref}, remaining)
    entry = %{entry | caller_mon: caller_mon, timer_ref: timer_ref}

    %{
      state
      | queue: :queue.in(entry.request_ref, state.queue),
        queued_entries: Map.put(state.queued_entries, entry.request_ref, entry),
        caller_monitors: Map.put(state.caller_monitors, caller_mon, entry.request_ref)
    }
  end

  defp dispatch_entry(state, entry) do
    remaining = entry.deadline_ms - System.monotonic_time(:millisecond)

    cond do
      not Process.alive?(entry.caller_pid) ->
        cleanup_entry_resources(state, entry)

      remaining <= 0 ->
        state = cleanup_entry_resources(state, entry)
        reply_timeout(state, entry)
        state

      true ->
        dispatch_live_entry(state, entry, remaining)
    end
  end

  defp dispatch_live_entry(state, entry, remaining) do
    client_pid = current_client(state)

    if is_pid(client_pid) and is_pid(state.client_supervisor) do
      registration_timeout = min(remaining, @registration_timeout_ms)

      case safe_client_call(fn ->
             Client.start_tool_call(
               client_pid,
               entry.tool_name,
               entry.arguments,
               timeout: remaining,
               deadline: entry.deadline_ms,
               admission_owner: entry.caller_pid,
               registration_timeout: registration_timeout
             )
           end) do
        {:ok, {:ok, handle}} ->
          if ToolCall.handle?(handle) do
            register_in_flight(state, entry, handle)
          else
            state = cleanup_entry_resources(state, entry)
            message = ProtocolClient.error_message(:invalid_tool_response)
            reply_protocol_error(state, entry, message, :invalid_tool_response)
            track_call_result(state, {:error, message})
          end

        {:ok, {:error, %McpError{reason: :registration_timeout}}} ->
          state = cleanup_entry_resources(state, entry)
          reply_timeout(state, entry)
          track_call_result(state, {:error, :timeout})

        {:ok, {:error, %McpError{reason: reason} = error}}
        when reason in [:client_not_found, :connection_closed, :registration_failed] ->
          state = cleanup_entry_resources(state, entry)
          reply_connection_error(state, entry, ProtocolClient.error_message(error))
          disconnect(state, reason)

        {:ok, {:error, reason}} ->
          state = cleanup_entry_resources(state, entry)
          message = ProtocolClient.error_message(reason)
          reply_protocol_error(state, entry, message, reason)
          track_call_result(state, {:error, message})

        {:ok, _invalid} ->
          state = cleanup_entry_resources(state, entry)
          message = ProtocolClient.error_message(:invalid_tool_response)
          reply_protocol_error(state, entry, message, :invalid_tool_response)
          track_call_result(state, {:error, message})

        {:error, reason} ->
          state = cleanup_entry_resources(state, entry)
          reply_connection_error(state, entry, ProtocolClient.error_message(reason))
          disconnect(state, reason)
      end
    else
      state = cleanup_entry_resources(state, entry)
      reply_connection_error(state, entry, ProtocolClient.error_message(:client_unavailable))
      disconnect(state, :client_unavailable)
    end
  end

  defp register_in_flight(state, entry, handle) do
    client_pid = ToolCall.client(handle)
    reply_ref = ToolCall.reply_ref(handle)

    {caller_mon, caller_monitors} =
      if is_reference(entry.caller_mon) do
        {entry.caller_mon, state.caller_monitors}
      else
        mon = Process.monitor(entry.caller_pid)
        {mon, Map.put(state.caller_monitors, mon, entry.request_ref)}
      end

    timer_ref =
      if is_reference(entry.timer_ref) do
        entry.timer_ref
      else
        remaining = max(entry.deadline_ms - System.monotonic_time(:millisecond), 0)
        Process.send_after(self(), {:request_deadline, entry.request_ref}, remaining)
      end

    entry = %{
      entry
      | caller_mon: caller_mon,
        timer_ref: timer_ref,
        client_handle: handle,
        client_pid: client_pid,
        client_reply_ref: reply_ref
    }

    state = %{
      state
      | caller_monitors: caller_monitors,
        in_flight: Map.put(state.in_flight, entry.request_ref, entry),
        client_refs: Map.put(state.client_refs, reply_ref, entry.request_ref)
    }

    attach_client_monitor(state, client_pid, entry.request_ref)
  end

  defp handle_tool_call_result(state, reply_ref, result) do
    case Map.pop(state.client_refs, reply_ref) do
      {nil, _client_refs} ->
        state

      {request_ref, client_refs} ->
        state = %{state | client_refs: client_refs}

        case Map.pop(state.in_flight, request_ref) do
          {nil, _in_flight} ->
            state

          {entry, in_flight} ->
            state =
              %{state | in_flight: in_flight}
              |> cleanup_entry_resources(entry)
              |> detach_client_monitor(entry.client_pid, request_ref)

            settle_tool_call_result(state, entry, result)
        end
    end
  end

  defp settle_tool_call_result(state, entry, {:ok, %Response{result: result}}) do
    meta = upstream_meta(state, entry, "success")
    maybe_emit_upstream_stop(entry.observability, entry.tool_name, entry.timeout, meta, nil)
    reply = if entry.observability, do: {:ok, result, meta}, else: {:ok, result}
    GenServer.reply(entry.from, reply)

    state
    |> track_call_result({:ok, result})
    |> drain_queue()
  end

  defp settle_tool_call_result(state, entry, {:error, %McpError{reason: :request_timeout}}) do
    reply_timeout(state, entry)

    state
    |> track_call_result({:error, :timeout})
    |> drain_queue()
  end

  defp settle_tool_call_result(state, entry, {:error, %McpError{reason: reason} = error})
       when reason in [:client_terminated, :connection_closed] do
    reply_connection_error(state, entry, ProtocolClient.error_message(error))

    if not client_tree_available?(state) or current_client(state) != entry.client_pid do
      disconnect(state, reason)
    else
      state
      |> track_call_result({:error, reason})
      |> drain_queue()
    end
  end

  defp settle_tool_call_result(state, entry, {:error, reason}) do
    message = ProtocolClient.error_message(reason)
    reply_protocol_error(state, entry, message, reason)

    state
    |> track_call_result({:error, message})
    |> drain_queue()
  end

  defp settle_tool_call_result(state, entry, _invalid) do
    message = ProtocolClient.error_message(:invalid_tool_response)
    reply_protocol_error(state, entry, message, :invalid_tool_response)

    state
    |> track_call_result({:error, message})
    |> drain_queue()
  end

  defp handle_request_deadline(state, request_ref) do
    case pop_request(state, request_ref) do
      {:queued, entry, state} ->
        state =
          state
          |> cleanup_entry_resources(%{entry | timer_ref: nil})
          |> maybe_compact_queue()

        reply_timeout(state, entry)
        state

      {:in_flight, entry, state} ->
        state = cleanup_entry_resources(state, %{entry | timer_ref: nil})
        safe_cancel_client_call(entry.client_handle, "timeout")
        reply_timeout(state, entry)

        state
        |> track_call_result({:error, :timeout})
        |> drain_queue()

      :not_found ->
        state
    end
  end

  defp cancel_request(state, request_ref, reason) do
    case pop_request(state, request_ref) do
      {:queued, entry, state} ->
        state =
          state
          |> cleanup_entry_resources(entry)
          |> maybe_compact_queue()

        if reason != :timeout do
          reply_cancelled(state, entry)
        end

        state

      {:in_flight, entry, state} ->
        state = cleanup_entry_resources(state, entry)
        safe_cancel_client_call(entry.client_handle, to_string(reason))

        state =
          if reason == :timeout do
            track_call_result(state, {:error, :timeout})
          else
            reply_cancelled(state, entry)
            state
          end

        drain_queue(state)

      :not_found ->
        state
    end
  end

  defp handle_caller_down(state, request_ref) do
    case pop_request(state, request_ref) do
      {:queued, entry, state} ->
        state
        |> cleanup_entry_resources(%{entry | caller_mon: nil})
        |> maybe_compact_queue()

      {:in_flight, entry, state} ->
        state = cleanup_entry_resources(state, %{entry | caller_mon: nil})
        safe_cancel_client_call(entry.client_handle, "caller_down")
        drain_queue(state)

      :not_found ->
        state
    end
  end

  defp handle_client_process_down(state, client_pid, request_refs, reason) do
    state = %{state | client_monitors: Map.delete(state.client_monitors, client_pid)}

    state =
      Enum.reduce(request_refs, state, fn request_ref, acc ->
        case Map.pop(acc.in_flight, request_ref) do
          {nil, _in_flight} ->
            acc

          {entry, in_flight} ->
            acc =
              %{
                acc
                | in_flight: in_flight,
                  client_refs: Map.delete(acc.client_refs, entry.client_reply_ref)
              }
              |> cleanup_entry_resources(entry)

            reply_connection_error(acc, entry, "Upstream connection error")
            acc
        end
      end)

    disconnect(state, {:client_down, reason})
  end

  defp drain_queue(state) do
    cond do
      state.stopping ->
        state

      is_nil(state.client_supervisor) or state.status in [:connecting, :disconnected] ->
        state

      map_size(state.in_flight) >= state.max_concurrent_calls ->
        state

      true ->
        case :queue.out(state.queue) do
          {:empty, queue} ->
            %{state | queue: queue}

          {{:value, request_ref}, queue} ->
            state = %{state | queue: queue}

            case Map.pop(state.queued_entries, request_ref) do
              {nil, _queued_entries} ->
                drain_queue(state)

              {entry, queued_entries} ->
                state = %{state | queued_entries: queued_entries}

                state
                |> dispatch_entry(entry)
                |> drain_queue()
            end
        end
    end
  end

  defp pop_request(state, request_ref) do
    case Map.pop(state.in_flight, request_ref) do
      {%{} = entry, in_flight} ->
        state =
          %{
            state
            | in_flight: in_flight,
              client_refs: Map.delete(state.client_refs, entry.client_reply_ref)
          }
          |> detach_client_monitor(entry.client_pid, request_ref)

        {:in_flight, entry, state}

      {nil, _in_flight} ->
        case Map.pop(state.queued_entries, request_ref) do
          {%{} = entry, queued_entries} ->
            {:queued, entry, %{state | queued_entries: queued_entries}}

          {nil, _queued_entries} ->
            :not_found
        end
    end
  end

  defp retire_all_requests(state, reason, opts) do
    cancel_client? = Keyword.get(opts, :cancel_client?, true)

    Enum.each(state.in_flight, fn {_ref, entry} ->
      cancel_entry_timer(entry.timer_ref)
      demonitor_ref(entry.caller_mon)

      if cancel_client? and entry.client_handle do
        safe_cancel_client_call(entry.client_handle, to_string(reason))
      end

      reply_connection_error(state, entry, "Upstream connection error")
    end)

    Enum.each(state.queued_entries, fn {_ref, entry} ->
      cancel_entry_timer(entry.timer_ref)
      demonitor_ref(entry.caller_mon)
      reply_connection_error(state, entry, "Upstream connection error")
    end)

    Enum.each(state.client_monitors, fn {_pid, %{monitor: monitor}} ->
      demonitor_ref(monitor)
    end)

    %{
      state
      | in_flight: %{},
        client_refs: %{},
        caller_monitors: %{},
        client_monitors: %{},
        queue: :queue.new(),
        queued_entries: %{}
    }
  end

  defp cleanup_entry_resources(state, entry) do
    cancel_entry_timer(entry.timer_ref)
    demonitor_ref(entry.caller_mon)

    if is_reference(entry.caller_mon) do
      %{state | caller_monitors: Map.delete(state.caller_monitors, entry.caller_mon)}
    else
      state
    end
  end

  defp cancel_entry_timer(ref) when is_reference(ref) do
    _ = Process.cancel_timer(ref)
    :ok
  end

  defp cancel_entry_timer(_ref), do: :ok

  defp demonitor_ref(ref) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    :ok
  end

  defp demonitor_ref(_ref), do: :ok

  defp maybe_compact_queue(state) do
    active_count = map_size(state.queued_entries)

    if :queue.len(state.queue) > max(active_count * 2, 32) do
      compacted = :queue.filter(&Map.has_key?(state.queued_entries, &1), state.queue)
      %{state | queue: compacted}
    else
      state
    end
  end

  defp attach_client_monitor(state, client_pid, request_ref) do
    updated =
      case Map.get(state.client_monitors, client_pid) do
        %{monitor: mon, request_refs: refs} ->
          %{monitor: mon, request_refs: MapSet.put(refs, request_ref)}

        nil ->
          %{monitor: Process.monitor(client_pid), request_refs: MapSet.new([request_ref])}
      end

    %{state | client_monitors: Map.put(state.client_monitors, client_pid, updated)}
  end

  defp detach_client_monitor(state, nil, _request_ref), do: state

  defp detach_client_monitor(state, client_pid, request_ref) do
    case Map.get(state.client_monitors, client_pid) do
      %{monitor: mon, request_refs: refs} ->
        remaining = MapSet.delete(refs, request_ref)

        if MapSet.size(remaining) == 0 do
          demonitor_ref(mon)
          %{state | client_monitors: Map.delete(state.client_monitors, client_pid)}
        else
          %{
            state
            | client_monitors:
                Map.put(state.client_monitors, client_pid, %{
                  monitor: mon,
                  request_refs: remaining
                })
          }
        end

      nil ->
        state
    end
  end

  defp find_client_monitor(state, monitor, pid) do
    case Map.get(state.client_monitors, pid) do
      %{monitor: ^monitor, request_refs: refs} -> {:ok, refs}
      _other -> :error
    end
  end

  defp safe_cancel_client_call(handle, reason) do
    if ToolCall.handle?(handle) do
      _ = Client.cancel_tool_call_async(handle, reason)
    end

    :ok
  rescue
    _exception -> :ok
  catch
    :exit, _reason -> :ok
  end

  defp reply_timeout(state, entry) do
    message = "Upstream timeout after #{entry.timeout}ms"
    meta = upstream_meta(state, entry, "error", error_kind: "timeout")
    maybe_emit_upstream_stop(entry.observability, entry.tool_name, entry.timeout, meta, message)
    reply = if entry.observability, do: {:error, message, meta}, else: {:error, message}
    GenServer.reply(entry.from, reply)
  end

  defp reply_cancelled(state, entry) do
    message = "Upstream call cancelled"
    meta = upstream_meta(state, entry, "error", error_kind: "cancelled")
    maybe_emit_upstream_stop(entry.observability, entry.tool_name, entry.timeout, meta, message)
    reply = if entry.observability, do: {:error, message, meta}, else: {:error, message}
    GenServer.reply(entry.from, reply)
  end

  defp reply_overloaded(state, entry) do
    message = "Upstream overloaded"
    meta = upstream_meta(state, entry, "error", error_kind: "overloaded")
    maybe_emit_upstream_stop(entry.observability, entry.tool_name, entry.timeout, meta, message)
    reply = if entry.observability, do: {:error, message, meta}, else: {:error, message}
    GenServer.reply(entry.from, reply)
  end

  defp reply_protocol_error(state, entry, message, reason) do
    meta = upstream_meta(state, entry, "error", category: :protocol, reason: reason)
    maybe_emit_upstream_stop(entry.observability, entry.tool_name, entry.timeout, meta, message)
    reply = if entry.observability, do: {:error, message, meta}, else: {:error, message}
    GenServer.reply(entry.from, reply)
  end

  defp reply_connection_error(state, entry, message) do
    meta = upstream_meta(state, entry, "error", category: :connection)
    maybe_emit_upstream_stop(entry.observability, entry.tool_name, entry.timeout, meta, message)
    reply = if entry.observability, do: {:error, message, meta}, else: {:error, message}
    GenServer.reply(entry.from, reply)
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

  defp fetch_catalog(state, owner \\ self()) do
    deadline = System.monotonic_time(:millisecond) + state.tool_timeout

    with {:ok, raw_tools} <- ToolCatalog.fetch_all(&list_tools_page(state, &1, deadline)),
         {:ok, tools} <-
           ToolCatalog.normalize_all(raw_tools, state.prefix, owner, state.tool_timeout) do
      {:ok, apply_tool_timeouts(tools, state.config, state.tool_timeout)}
    end
  end

  defp list_tools_page(state, cursor, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining > 0 do
      opts = if cursor, do: [cursor: cursor, timeout: remaining], else: [timeout: remaining]
      client_result(fn -> Client.list_tools(state.client, opts) end)
    else
      {:error, :timeout}
    end
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

  defp refresh_now(state), do: start_control(state, :refresh)

  # Health and catalog operations share one worker and a two-entry queue.
  # The scheduler retains all registry, lifecycle, timer and reconnect ownership.
  defp health_now(state), do: start_control(state, :health)

  defp start_control(%{status: status} = state, _kind)
       when status in [:connecting, :disconnected],
       do: state

  defp start_control(%{control_operation: op} = state, kind) when not is_nil(op) do
    %{state | pending_controls: Enum.uniq(state.pending_controls ++ [kind])}
  end

  defp start_control(state, kind) do
    owner = self()
    client = current_client(state)
    ref = make_ref()
    snapshot = %{state | client: client}

    {pid, monitor} =
      spawn_monitor(fn ->
        result =
          case {kind, snapshot.era} do
            {:health, :legacy} -> legacy_ping(snapshot)
            _catalog -> fetch_catalog(snapshot, owner)
          end

        send(owner, {:control_result, ref, result})
      end)

    timer = Process.send_after(self(), {:control_timeout, ref}, state.tool_timeout)

    op = %{
      ref: ref,
      kind: kind,
      pid: pid,
      monitor: monitor,
      timer: timer,
      client: client,
      supervisor: state.client_supervisor
    }

    state = %{state | control_operation: op}
    if kind == :health, do: %{state | last_ping_at: System.system_time(:second)}, else: state
  end

  defp settle_control(state, op, result) do
    state = finish_control(state)

    if current_client(state) == op.client and state.client_supervisor == op.supervisor do
      state |> apply_control_result(op.kind, result) |> start_pending_control()
    else
      disconnect(state, :client_replaced_during_control)
    end
  end

  defp finish_control(%{control_operation: nil} = state), do: state

  defp finish_control(%{control_operation: op} = state) do
    Process.cancel_timer(op.timer)
    Process.demonitor(op.monitor, [:flush])
    if Process.alive?(op.pid), do: Process.exit(op.pid, :kill)
    %{state | control_operation: nil}
  end

  defp start_pending_control(%{status: status} = state)
       when status in [:connecting, :disconnected],
       do: %{state | pending_controls: []}

  defp start_pending_control(%{pending_controls: []} = state), do: state

  defp start_pending_control(%{pending_controls: [kind | rest]} = state),
    do: start_control(%{state | pending_controls: rest}, kind)

  defp apply_control_result(state, :refresh, {:ok, tools}) do
    ToolRegistry.register_upstream(state.prefix, self(), tools)
    broadcast_tools_refreshed(state, tools)

    state
    |> Map.merge(%{tools: tools, status: :connected, reconnect_attempts: 0})
    |> schedule_refresh()
  end

  defp apply_control_result(state, :refresh, {:error, reason}) do
    if client_tree_available?(state), do: schedule_refresh(state), else: disconnect(state, reason)
  end

  defp apply_control_result(state, :health, :pong),
    do: health_success(state, System.system_time(:second))

  defp apply_control_result(state, :health, {:ok, tools}) do
    ToolRegistry.register_upstream(state.prefix, self(), tools)
    broadcast_tools_refreshed(state, tools)
    health_success(%{state | tools: tools}, System.system_time(:second))
  end

  defp apply_control_result(state, :health, {:error, reason}) do
    if client_tree_available?(state),
      do: health_failure(state, reason),
      else: disconnect(state, reason)
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
      |> finish_control()
      |> Map.put(:pending_controls, [])
      |> retire_all_requests(:stopping, cancel_client?: true)
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
      |> finish_control()
      |> Map.put(:pending_controls, [])
      |> retire_all_requests(reason, cancel_client?: is_pid(state.client_supervisor))
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

  defp current_client(state) do
    GenServer.whereis(state.client)
  catch
    :exit, _reason -> nil
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

  defp configured_max_concurrent_calls(config) do
    default =
      Application.get_env(
        :backplane_mcp,
        :upstream_max_concurrent_calls,
        @default_max_concurrent_calls
      )

    case Map.get(config, :max_concurrent_calls, Map.get(config, "max_concurrent_calls")) do
      limit when is_integer(limit) and limit > 0 -> limit
      _missing_or_invalid -> if(is_integer(default) and default > 0, do: default, else: 32)
    end
  end

  defp configured_max_queued_calls(config) do
    default =
      Application.get_env(
        :backplane_mcp,
        :upstream_max_queued_calls,
        @default_max_queued_calls
      )

    case Map.get(config, :max_queued_calls, Map.get(config, "max_queued_calls")) do
      limit when is_integer(limit) and limit >= 0 -> limit
      _missing_or_invalid -> if(is_integer(default) and default >= 0, do: default, else: 128)
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

  defp normalize_forward_reply(reply, nil), do: normalize_reply(reply)
  defp normalize_forward_reply(reply, _observability), do: normalize_observability_reply(reply)

  defp normalize_reply({:ok, result}), do: {:ok, result}
  defp normalize_reply({:error, reason}), do: {:error, reason}
  defp normalize_reply(other), do: other

  defp normalize_observability_reply({:ok, result, meta}), do: {:ok, result, meta}
  defp normalize_observability_reply({:error, reason, meta}), do: {:error, reason, meta}
  defp normalize_observability_reply(other), do: other

  defp upstream_meta(state, entry, outcome, opts \\ []) do
    {negotiated_version, _, _} = safe_negotiation_status(state)

    duration_ms =
      if is_integer(entry.started_ms) do
        max(System.monotonic_time(:millisecond) - entry.started_ms, 0)
      else
        nil
      end

    error_kind =
      Keyword.get(opts, :error_kind) ||
        upstream_error_kind(Keyword.get(opts, :category), Keyword.get(opts, :reason))

    %{
      upstream_name: state.name,
      upstream_prefix: state.prefix,
      upstream_transport: state.transport,
      upstream_protocol_version: negotiated_version,
      original_tool_name: entry.tool_name,
      timeout_ms: entry.timeout,
      attempt_count: 1,
      duration_ms: duration_ms,
      outcome: outcome,
      error_kind: error_kind
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

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

    error =
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
      attributes: Map.put(meta, :original_tool_name, tool_name),
      error: error
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

  defp timeout_meta(timeout, elapsed) do
    %{
      attempt_count: 1,
      outcome: "error",
      error_kind: "timeout",
      timeout_ms: timeout,
      duration_ms: elapsed
    }
  end
end

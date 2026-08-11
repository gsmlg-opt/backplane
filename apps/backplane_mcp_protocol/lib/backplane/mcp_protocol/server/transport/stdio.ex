defmodule Backplane.McpProtocol.Server.Transport.STDIO do
  @moduledoc """
  STDIO transport implementation for MCP servers.

  One connection process owns JSON line decoding, protocol-era selection, request
  bookkeeping, subscription multiplexing, and all writes to the output device.
  Legacy sessions are created lazily only after a valid initialize request.
  """

  @behaviour Backplane.McpProtocol.Transport.Behaviour

  use GenServer
  use Backplane.McpProtocol.Logging

  import Peri

  alias Backplane.McpProtocol.MCP.Error
  alias Backplane.McpProtocol.MCP.Message
  alias Backplane.McpProtocol.Protocol.Profile
  alias Backplane.McpProtocol.Server.Modern.Executor
  alias Backplane.McpProtocol.Server.Modern.RequestContext
  alias Backplane.McpProtocol.Server.Modern.Subscriptions
  alias Backplane.McpProtocol.Server.ProfileRouter
  alias Backplane.McpProtocol.Server.Registry
  alias Backplane.McpProtocol.Server.Supervisor, as: ServerSupervisor
  alias Backplane.McpProtocol.Telemetry
  alias Backplane.McpProtocol.Transport.Behaviour, as: Transport

  require Message

  @default_timeout to_timeout(second: 30)

  defmodule State do
    @moduledoc false

    defstruct [
      :server,
      :transport_name,
      :reading_task,
      :request_timeout,
      :io_device,
      :task_supervisor,
      :session_supervisor,
      :subscriptions,
      :session_config,
      detected_era: :unknown,
      legacy_session: nil,
      active_requests: %{},
      request_refs: %{},
      subscription_requests: %{},
      subscription_refs: %{}
    ]
  end

  @type t :: GenServer.server()

  @typedoc """
  STDIO transport options.

  The task supervisor, legacy session DynamicSupervisor, and subscription hub
  default to deterministic names derived from the server module.
  """
  @type option ::
          {:server, GenServer.server()}
          | {:name, GenServer.name()}
          | {:task_supervisor, GenServer.name()}
          | {:session_supervisor, GenServer.name()}
          | {:subscriptions, GenServer.name()}
          | {:session_config, map()}
          | GenServer.option()

  defschema(:parse_options, [
    {:server, {:required, {:oneof, [{:custom, &Backplane.McpProtocol.genserver_name/1}, :pid, {:tuple, [:atom, :any]}]}}},
    {:name, {:custom, &Backplane.McpProtocol.genserver_name/1}},
    {:request_timeout, {:integer, {:default, @default_timeout}}},
    {:io_device, {:any, {:default, :stdio}}},
    {:task_supervisor, {:custom, &Backplane.McpProtocol.genserver_name/1}},
    {:session_supervisor, {:custom, &Backplane.McpProtocol.genserver_name/1}},
    {:subscriptions, {:custom, &Backplane.McpProtocol.genserver_name/1}},
    {:session_config, :map}
  ])

  @impl Transport
  @spec start_link(Enumerable.t(option())) :: GenServer.on_start()
  def start_link(opts) do
    opts = parse_options!(opts)
    server_name = Keyword.get(opts, :name)

    if server_name do
      GenServer.start_link(__MODULE__, Map.new(opts), name: server_name)
    else
      GenServer.start_link(__MODULE__, Map.new(opts))
    end
  end

  @impl Transport
  def send_message(transport, message, opts) when is_binary(message) do
    GenServer.call(transport, {:send, message}, opts[:timeout])
  end

  @impl Transport
  @spec shutdown(GenServer.server()) :: :ok
  def shutdown(transport) do
    GenServer.cast(transport, :shutdown)
  end

  @impl Transport
  def supported_protocol_versions, do: :all

  @impl GenServer
  def init(opts) do
    :logger.update_handler_config(:default, :config, %{type: :standard_error})

    with {:error, err} <- :io.setopts(encoding: :utf8) do
      Logging.transport_event(
        "could not set up io options, may produce unexpected behavior: #{inspect(err)}",
        %{transport: :stdio, server: opts.server},
        level: :warning
      )
    end

    Process.flag(:trap_exit, true)

    state = %State{
      server: opts.server,
      transport_name: Map.get(opts, :name, self()),
      reading_task: nil,
      request_timeout: opts.request_timeout,
      io_device: opts.io_device,
      task_supervisor: Map.get(opts, :task_supervisor, default_name(opts.server, :task_supervisor)),
      session_supervisor: Map.get(opts, :session_supervisor, default_name(opts.server, :session_supervisor)),
      subscriptions: Map.get(opts, :subscriptions, default_name(opts.server, :subscriptions)),
      session_config: Map.get(opts, :session_config, %{})
    }

    Logger.metadata(mcp_transport: :stdio, mcp_server: state.server)
    Logging.transport_event("starting", %{transport: :stdio, server: state.server})

    Telemetry.execute(
      Telemetry.event_transport_init(),
      %{system_time: System.system_time()},
      %{transport: :stdio, server: state.server}
    )

    {:ok, state, {:continue, :start_reading}}
  end

  @impl GenServer
  def handle_continue(:start_reading, state) do
    {:noreply, start_reading(state)}
  end

  @impl GenServer
  def handle_info({ref, result}, %State{reading_task: %Task{ref: ref}} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    state = %{state | reading_task: nil}

    case result do
      {:ok, data} ->
        state = dispatch_line(data, state)
        {:noreply, start_reading(state)}

      {:error, :eof} ->
        Logging.transport_event("eof", "Client disconnected", level: :info)

        Telemetry.execute(
          Telemetry.event_transport_disconnect(),
          %{system_time: System.system_time()},
          %{transport: :stdio, server: state.server, reason: :eof}
        )

        {:stop, :normal, state}

      {:error, reason} ->
        Logging.transport_event("read_error", %{reason: reason}, level: :error)

        Telemetry.execute(
          Telemetry.event_transport_error(),
          %{system_time: System.system_time()},
          %{transport: :stdio, server: state.server, reason: reason}
        )

        {:stop, {:error, reason}, state}
    end
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    case take_active_request(state, ref, demonitor?: true) do
      :error ->
        {:noreply, state}

      {:ok, request_id, _entry, state} ->
        {:noreply, handle_task_result(result, request_id, state)}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) when is_reference(ref) do
    cond do
      match?(%Task{ref: ^ref}, state.reading_task) ->
        {:stop, {:read_task_down, reason}, %{state | reading_task: nil}}

      Map.has_key?(state.request_refs, ref) ->
        {:ok, request_id, _entry, state} = take_active_request(state, ref, demonitor?: false)
        response = Error.build_json_rpc(Error.protocol(:internal_error), request_id)
        {:noreply, write_json(state, response)}

      true ->
        {:noreply, state}
    end
  end

  def handle_info({:request_timeout, ref}, state) when is_reference(ref) do
    case take_active_request(state, ref, demonitor?: false) do
      :error ->
        {:noreply, state}

      {:ok, request_id, entry, state} ->
        _ = Task.shutdown(entry.task, :brutal_kill)
        {:noreply, write_error(state, Error.protocol(:internal_error), request_id)}
    end
  end

  def handle_info({:mcp_subscription, subscription_ref, envelope}, state) do
    case Map.fetch(state.subscription_refs, subscription_ref) do
      {:ok, request_id} ->
        state = write_json(state, envelope)

        if complete_subscription?(envelope, request_id) do
          {:noreply, remove_subscription_mapping(state, request_id, subscription_ref)}
        else
          {:noreply, state}
        end

      :error ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def handle_call({:send, message}, _from, state) do
    Logging.transport_event(
      "outgoing",
      %{transport: :stdio, message_size: byte_size(message)},
      level: :debug
    )

    Telemetry.execute(
      Telemetry.event_transport_send(),
      %{system_time: System.system_time()},
      %{transport: :stdio, message_size: byte_size(message)}
    )

    {:reply, :ok, write_line(state, message)}
  end

  @impl GenServer
  def handle_cast(:shutdown, state) do
    Logging.transport_event("shutdown", "Transport shutting down", level: :info)

    Telemetry.execute(
      Telemetry.event_transport_disconnect(),
      %{system_time: System.system_time()},
      %{transport: :stdio, reason: :shutdown}
    )

    {:stop, :normal, state}
  end

  @impl GenServer
  def terminate(reason, state) do
    cleanup(state)
    level = if reason in [:normal, :shutdown] or match?({:shutdown, _}, reason), do: :debug, else: :info
    Logging.transport_event("terminating", %{reason: reason}, level: level)

    Telemetry.execute(
      Telemetry.event_transport_terminate(),
      %{system_time: System.system_time()},
      %{transport: :stdio, reason: reason}
    )

    :ok
  end

  defp start_reading(state) do
    task = Task.async(fn -> read_from_stdin(state.io_device) end)
    %{state | reading_task: task}
  end

  defp read_from_stdin(device) do
    case IO.read(device, :line) do
      :eof -> {:error, :eof}
      {:error, reason} -> {:error, reason}
      data when is_binary(data) -> {:ok, data}
    end
  end

  defp dispatch_line(data, state) do
    Logging.transport_event(
      "incoming",
      %{transport: :stdio, message_size: byte_size(data)},
      level: :debug
    )

    Telemetry.execute(
      Telemetry.event_transport_receive(),
      %{system_time: System.system_time()},
      %{transport: :stdio, message_size: byte_size(data)}
    )

    case JSON.decode(String.trim(data)) do
      {:ok, message} when is_map(message) ->
        dispatch_message(message, state)

      {:ok, _invalid} ->
        write_error(state, Error.protocol(:invalid_request), nil)

      {:error, reason} ->
        Logging.transport_event("parse_error", %{reason: reason}, level: :error)
        write_error(state, Error.protocol(:parse_error), nil)
    end
  end

  defp dispatch_message(message, %State{detected_era: :unknown} = state) do
    modern_marker? = modern_marker?(message)
    legacy_initialize? = legacy_initialize?(message)

    cond do
      modern_marker? and legacy_initialize? ->
        write_invalid_request(state, message)

      modern_marker? ->
        state = %{state | detected_era: :modern}
        dispatch_modern(message, state)

      legacy_initialize? ->
        case validate_legacy(message) do
          {:ok, message} ->
            state = %{state | detected_era: :legacy}
            dispatch_legacy(message, state)

          :error ->
            write_invalid_request(state, message)
        end

      true ->
        write_invalid_request(state, message)
    end
  end

  defp dispatch_message(message, %State{detected_era: :modern} = state) do
    if legacy_initialize?(message), do: write_invalid_request(state, message), else: dispatch_modern(message, state)
  end

  defp dispatch_message(message, %State{detected_era: :legacy} = state) do
    if modern_marker?(message) do
      write_invalid_request(state, message)
    else
      case validate_legacy(message) do
        {:ok, message} -> dispatch_legacy(message, state)
        :error -> write_invalid_request(state, message)
      end
    end
  end

  defp dispatch_modern(message, state) do
    case validate_modern_envelope(message) do
      :request -> dispatch_modern_request(message, state)
      :cancelled -> cancel_modern(message, state)
      :error -> write_invalid_request(state, message)
    end
  end

  defp dispatch_modern_request(%{"method" => "subscriptions/listen"} = message, state) do
    request_id = message["id"]

    if Map.has_key?(state.active_requests, request_id) or
         Map.has_key?(state.subscription_requests, request_id) do
      write_invalid_request(state, message)
    else
      start_tracked_request(state, request_id, fn ->
        prepare_subscription(state.server, message, modern_transport_context(state))
      end)
    end
  end

  defp dispatch_modern_request(message, state) do
    request_id = message["id"]

    if Map.has_key?(state.active_requests, request_id) or
         Map.has_key?(state.subscription_requests, request_id) do
      write_invalid_request(state, message)
    else
      context = modern_transport_context(state)

      start_tracked_request(state, request_id, fn ->
        Executor.execute(state.server, message, context,
          task_supervisor: state.task_supervisor,
          timeout: state.request_timeout,
          isolation: :caller_supervised
        )
      end)
    end
  end

  defp prepare_subscription(server, message, context) do
    context = Map.put(context, :supported_versions, safe_supported_versions(server))

    with {:ok, {:modern, %Profile{} = profile}} <- ProfileRouter.route(message, context),
         {:ok, _request_context} <- RequestContext.build(profile, message, context),
         {:ok, capabilities} <- safe_server_capabilities(server) do
      {:subscription_ready,
       %{
         request: message,
         server_capabilities: capabilities,
         server_info: safe_server_info(server)
       }}
    else
      {:error, %Error{} = error} -> {:subscription_error, error}
      _failure -> {:subscription_error, Error.protocol(:internal_error)}
    end
  end

  defp start_tracked_request(state, request_id, fun) do
    task = Task.Supervisor.async_nolink(state.task_supervisor, fun)
    timer = Process.send_after(self(), {:request_timeout, task.ref}, state.request_timeout)
    entry = %{task: task, timer: timer}

    %{
      state
      | active_requests: Map.put(state.active_requests, request_id, entry),
        request_refs: Map.put(state.request_refs, task.ref, request_id)
    }
  catch
    :exit, _reason -> write_error(state, Error.protocol(:internal_error), request_id)
  end

  defp take_active_request(state, ref, opts) do
    case Map.pop(state.request_refs, ref) do
      {nil, _request_refs} ->
        :error

      {request_id, request_refs} ->
        {entry, active_requests} = Map.pop!(state.active_requests, request_id)
        _ = Process.cancel_timer(entry.timer)
        if opts[:demonitor?], do: Process.demonitor(ref, [:flush])
        state = %{state | request_refs: request_refs, active_requests: active_requests}
        {:ok, request_id, entry, state}
    end
  end

  defp handle_task_result({:response, response}, _request_id, state) when is_map(response) do
    write_json(state, response)
  end

  defp handle_task_result({:subscription_ready, subscription_context}, request_id, state) do
    case Subscriptions.subscribe(state.subscriptions, self(), subscription_context) do
      {:ok, subscription_ref} ->
        %{
          state
          | subscription_requests: Map.put(state.subscription_requests, request_id, subscription_ref),
            subscription_refs: Map.put(state.subscription_refs, subscription_ref, request_id)
        }

      {:error, %Error{} = error} ->
        write_error(state, error, request_id)
    end
  catch
    :exit, _reason -> write_error(state, Error.protocol(:internal_error), request_id)
  end

  defp handle_task_result({:subscription_error, %Error{} = error}, request_id, state) do
    write_error(state, error, request_id)
  end

  defp handle_task_result(_unexpected, request_id, state) do
    write_error(state, Error.protocol(:internal_error), request_id)
  end

  defp cancel_modern(message, state) do
    request_id = get_in(message, ["params", "requestId"])

    case Map.pop(state.active_requests, request_id) do
      {nil, _active_requests} ->
        cancel_subscription(request_id, state)

      {%{task: task, timer: timer}, active_requests} ->
        _ = Process.cancel_timer(timer)
        _ = Task.shutdown(task, :brutal_kill)

        %{
          state
          | active_requests: active_requests,
            request_refs: Map.delete(state.request_refs, task.ref)
        }
    end
  end

  defp cancel_subscription(request_id, state) do
    case Map.pop(state.subscription_requests, request_id) do
      {nil, _subscription_requests} ->
        state

      {subscription_ref, subscription_requests} ->
        :ok = Subscriptions.unsubscribe(state.subscriptions, subscription_ref)

        %{
          state
          | subscription_requests: subscription_requests,
            subscription_refs: Map.delete(state.subscription_refs, subscription_ref)
        }
    end
  catch
    :exit, _reason -> state
  end

  defp dispatch_legacy(message, state) do
    case ensure_legacy_session(state) do
      {:ok, state} ->
        context = %{type: :stdio, env: System.get_env(), pid: System.pid()}

        if Message.is_notification(message) do
          GenServer.cast(state.legacy_session, {:mcp_notification, message, context})
          state
        else
          forward_legacy_request(message, context, state)
        end

      {:error, reason, state} ->
        Logging.transport_event("session_error", %{reason: reason}, level: :error)
        write_error(state, Error.protocol(:internal_error), message["id"])
    end
  end

  defp ensure_legacy_session(%State{legacy_session: session} = state) when not is_nil(session) do
    if GenServer.whereis(session), do: {:ok, state}, else: start_legacy_session(%{state | legacy_session: nil})
  end

  defp ensure_legacy_session(state), do: start_legacy_session(state)

  defp start_legacy_session(%State{server: server} = state) when is_atom(server) do
    session_name = Registry.stdio_session_name(server)

    case GenServer.whereis(session_name) do
      pid when is_pid(pid) ->
        {:ok, %{state | legacy_session: session_name}}

      _missing ->
        config = state.session_config

        session_opts = [
          session_id: "stdio",
          server_module: server,
          name: session_name,
          transport: Map.get(config, :transport, layer: __MODULE__, name: state.transport_name),
          session_idle_timeout: Map.get(config, :session_idle_timeout) || to_timeout(minute: 30),
          timeout: Map.get(config, :timeout, state.request_timeout),
          max_concurrency: Map.get(config, :max_concurrency, 1),
          task_supervisor: Map.get(config, :task_supervisor, state.task_supervisor)
        ]

        session_opts =
          case Map.get(config, :task_store) do
            nil -> session_opts
            task_store -> Keyword.put(session_opts, :task_store, task_store)
          end

        case ServerSupervisor.start_session(server, session_opts) do
          {:ok, _pid} -> {:ok, %{state | legacy_session: session_name}}
          {:error, {:already_started, _pid}} -> {:ok, %{state | legacy_session: session_name}}
          {:error, reason} -> {:error, reason, state}
        end
    end
  end

  defp start_legacy_session(state), do: {:error, :invalid_server_module, state}

  defp forward_legacy_request(message, context, state) do
    case GenServer.call(state.legacy_session, {:mcp_request, message, context}, state.request_timeout) do
      {:ok, response} when is_binary(response) ->
        write_line(state, response)

      {:ok, nil} ->
        state

      {:error, reason} ->
        Logging.transport_event("session_error", %{reason: reason}, level: :error)
        state
    end
  catch
    :exit, reason ->
      Logging.transport_event("session_call_failed", %{reason: reason}, level: :error)
      write_error(state, Error.protocol(:internal_error), message["id"])
  end

  defp validate_modern_envelope(
         %{"jsonrpc" => "2.0", "method" => "notifications/cancelled", "params" => %{"requestId" => request_id} = params} =
           message
       )
       when is_binary(request_id) or is_integer(request_id) do
    reason_valid? = not Map.has_key?(params, "reason") or is_binary(params["reason"])

    if reason_valid? and not Map.has_key?(message, "id") and
         not Map.has_key?(message, "result") and not Map.has_key?(message, "error") do
      :cancelled
    else
      :error
    end
  end

  defp validate_modern_envelope(%{"jsonrpc" => "2.0", "method" => method, "id" => id, "params" => params} = message)
       when is_binary(method) and (is_binary(id) or is_integer(id)) and is_map(params) do
    if not Map.has_key?(message, "result") and not Map.has_key?(message, "error"),
      do: :request,
      else: :error
  end

  defp validate_modern_envelope(_message), do: :error

  defp validate_legacy(message) do
    case Message.validate_message(message) do
      {:ok, validated} -> {:ok, validated}
      {:error, _reason} -> :error
    end
  end

  defp modern_marker?(%{"method" => "server/discover"}), do: true

  defp modern_marker?(message) do
    case get_in(message, ["params", "_meta"]) do
      meta when is_map(meta) -> Map.has_key?(meta, "io.modelcontextprotocol/protocolVersion")
      _missing -> false
    end
  end

  defp legacy_initialize?(%{"method" => "initialize", "id" => id}) when is_binary(id) or is_integer(id), do: true
  defp legacy_initialize?(_message), do: false

  defp modern_transport_context(state) do
    %{
      type: :stdio,
      transport: :stdio,
      env: System.get_env(),
      pid: System.pid(),
      task_supervisor: state.task_supervisor,
      request_timeout: state.request_timeout
    }
  end

  defp safe_supported_versions(server) do
    versions = server.supported_protocol_versions()
    if is_list(versions), do: versions, else: []
  rescue
    _exception -> []
  catch
    _kind, _reason -> []
  end

  defp safe_server_capabilities(server) do
    capabilities = server.server_capabilities()
    if is_map(capabilities), do: {:ok, capabilities}, else: {:error, Error.protocol(:internal_error)}
  rescue
    _exception -> {:error, Error.protocol(:internal_error)}
  catch
    _kind, _reason -> {:error, Error.protocol(:internal_error)}
  end

  defp safe_server_info(server) do
    info = server.server_info()
    if is_map(info), do: info
  rescue
    _exception -> nil
  catch
    _kind, _reason -> nil
  end

  defp write_invalid_request(state, message) do
    write_error(state, Error.protocol(:invalid_request), valid_id(message["id"]))
  end

  defp write_error(state, error, id), do: write_json(state, Error.build_json_rpc(error, id))
  defp write_json(state, envelope), do: write_line(state, JSON.encode!(envelope))

  defp write_line(state, data) do
    line = String.trim_trailing(data, "\n") <> "\n"
    IO.write(state.io_device, line)
    state
  end

  defp valid_id(id) when is_binary(id) or is_integer(id), do: id
  defp valid_id(_id), do: nil

  defp complete_subscription?(%{"id" => request_id, "result" => %{"resultType" => "complete"}}, request_id), do: true
  defp complete_subscription?(_envelope, _request_id), do: false

  defp remove_subscription_mapping(state, request_id, subscription_ref) do
    %{
      state
      | subscription_requests: Map.delete(state.subscription_requests, request_id),
        subscription_refs: Map.delete(state.subscription_refs, subscription_ref)
    }
  end

  defp cleanup(state) do
    if state.reading_task, do: Task.shutdown(state.reading_task, :brutal_kill)

    Enum.each(state.active_requests, fn {_request_id, entry} ->
      _ = Process.cancel_timer(entry.timer)
      Task.shutdown(entry.task, :brutal_kill)
    end)

    Enum.each(state.subscription_refs, fn {subscription_ref, _request_id} ->
      try do
        Subscriptions.unsubscribe(state.subscriptions, subscription_ref)
      catch
        :exit, _reason -> :ok
      end
    end)
  end

  defp default_name(server, :task_supervisor) when is_atom(server), do: Registry.task_supervisor_name(server)
  defp default_name(server, :session_supervisor) when is_atom(server), do: Registry.session_supervisor_name(server)
  defp default_name(server, :subscriptions) when is_atom(server), do: Registry.subscriptions_name(server)
  defp default_name(_server, _kind), do: nil
end

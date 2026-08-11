defmodule Backplane.McpProtocol.Server.Modern.Executor do
  @moduledoc """
  Executes one modern MCP request without creating or retaining session state.

  Application initialization and dispatch run inside a supervised request task.
  Result normalization is deliberately kept outside that failure boundary.
  """

  alias Backplane.McpProtocol.MCP.Error
  alias Backplane.McpProtocol.MCP.Message
  alias Backplane.McpProtocol.Protocol.Profile
  alias Backplane.McpProtocol.Server.Frame
  alias Backplane.McpProtocol.Server.Handlers
  alias Backplane.McpProtocol.Server.Modern.Discovery
  alias Backplane.McpProtocol.Server.Modern.Headers
  alias Backplane.McpProtocol.Server.Modern.RequestContext
  alias Backplane.McpProtocol.Server.Modern.Result
  alias Backplane.McpProtocol.Server.ProfileRouter
  alias Backplane.McpProtocol.Server.Registry
  alias Backplane.McpProtocol.Telemetry

  @default_timeout to_timeout(second: 30)

  @type execute_result :: {:response, map()}

  @type server_snapshot :: %{
          supported_versions: [String.t()],
          capabilities: map(),
          server_info: map(),
          instructions: String.t() | nil
        }

  @spec execute(module(), map(), map(), keyword()) :: execute_result()
  def execute(server_module, request, transport_context, opts \\ [])
      when is_atom(server_module) and is_map(request) and is_map(transport_context) and is_list(opts) do
    timeout = normalize_timeout(opts[:timeout] || transport_context[:request_timeout])
    deadline = System.monotonic_time(:millisecond) + timeout
    task_supervisor = task_supervisor(server_module, transport_context, opts)

    case run_isolated(task_supervisor, deadline, opts, fn -> snapshot_server(server_module) end) do
      {:ok, {:server_snapshot, snapshot}} ->
        routing_context = Map.put(transport_context, :supported_versions, snapshot.supported_versions)

        case ProfileRouter.route(request, routing_context) do
          {:ok, {:modern, %Profile{} = profile}} ->
            execute_modern(
              server_module,
              snapshot,
              profile,
              request,
              routing_context,
              task_supervisor,
              deadline,
              opts
            )

          {:ok, :legacy} ->
            respond_error(Error.protocol(:invalid_request), request["id"])

          {:error, %Error{} = error} ->
            respond_error(error, request["id"])
        end

      _failure ->
        respond_callback_failure(request)
    end
  end

  defp execute_modern(server_module, snapshot, profile, request, transport_context, task_supervisor, deadline, opts) do
    with :ok <- Headers.validate(profile, request, transport_context),
         {:ok, request_context} <- RequestContext.build(profile, request, transport_context),
         :ok <- validate_method(profile, request_context.method),
         :ok <- validate_server_capability(snapshot.capabilities, request_context.method) do
      emit_request(request_context)

      if request_context.method == "server/discover" do
        task_supervisor
        |> run_isolated(deadline, opts, fn -> safely_discover(snapshot, request_context) end)
        |> normalize_discovery_to_envelope(snapshot, request_context)
      else
        task_supervisor
        |> run_isolated(deadline, opts, fn ->
          safely_dispatch(server_module, request_context, transport_context)
        end)
        |> normalize_callback_to_envelope(snapshot, request_context)
      end
    else
      {:error, %Error{} = error} -> respond_error(error, request["id"])
    end
  end

  defp snapshot_server(server_module) do
    snapshot = %{
      supported_versions: server_module.supported_protocol_versions(),
      capabilities: server_module.server_capabilities(),
      server_info: server_module.server_info(),
      instructions: server_instructions(server_module)
    }

    if valid_snapshot?(snapshot),
      do: {:server_snapshot, snapshot},
      else: :callback_failure
  rescue
    _exception -> :callback_failure
  catch
    _kind, _reason -> :callback_failure
  end

  defp server_instructions(server_module) do
    if Backplane.McpProtocol.exported?(server_module, :server_instructions, 0),
      do: server_module.server_instructions()
  end

  defp valid_snapshot?(snapshot) do
    is_list(snapshot.supported_versions) and
      Enum.all?(snapshot.supported_versions, &is_binary/1) and
      is_map(snapshot.capabilities) and
      is_map(snapshot.server_info) and
      (is_nil(snapshot.instructions) or is_binary(snapshot.instructions))
  end

  defp safely_discover(snapshot, request_context) do
    case Discovery.execute(snapshot, request_context) do
      {:ok, result} when is_map(result) -> {:discovery_result, result}
      {:error, %Error{} = error} -> {:protocol_error, error}
      _invalid -> :callback_failure
    end
  rescue
    _exception -> :callback_failure
  catch
    _kind, _reason -> :callback_failure
  end

  defp safely_dispatch(server_module, request_context, transport_context) do
    frame = fresh_frame(request_context)

    case maybe_init_request(server_module, request_context, frame) do
      {:ok, %Frame{} = initialized_frame} ->
        initialized_frame = %{
          initialized_frame
          | context: RequestContext.to_server_context(request_context)
        }

        case validate_tool_headers(server_module, request_context, initialized_frame, transport_context) do
          :ok -> {:callback_return, server_module.handle_request(request_context.request, initialized_frame)}
          {:error, %Error{} = error} -> {:protocol_error, error}
        end

      {:error, %Error{}, %Frame{}} = error_return ->
        {:callback_return, error_return}

      _invalid ->
        :callback_failure
    end
  rescue
    _exception -> :callback_failure
  catch
    _kind, _reason -> :callback_failure
  end

  defp maybe_init_request(server_module, request_context, frame) do
    if Backplane.McpProtocol.exported?(server_module, :init_request, 2) do
      server_module.init_request(request_context, frame)
    else
      {:ok, frame}
    end
  end

  defp validate_tool_headers(server_module, %RequestContext{method: "tools/call"} = context, frame, transport_context) do
    tool_name = get_in(context.request, ["params", "name"])
    tool = server_module |> Handlers.get_server_tools(frame) |> Enum.find(&(&1.name == tool_name))

    if tool, do: Headers.validate_tool_params(tool, context.request, transport_context), else: :ok
  end

  defp validate_tool_headers(_server_module, _request_context, _frame, _transport_context), do: :ok

  defp fresh_frame(request_context) do
    frame = Frame.new(request_context.assigns)
    %{frame | context: RequestContext.to_server_context(request_context)}
  end

  defp task_supervisor(server_module, transport_context, opts) do
    opts[:task_supervisor] ||
      transport_context[:task_supervisor] ||
      Registry.task_supervisor_name(server_module)
  end

  defp run_isolated(task_supervisor, deadline, opts, fun) do
    case remaining_timeout(deadline) do
      timeout when timeout > 0 ->
        if inline_isolation?(opts),
          do: {:ok, fun.()},
          else: run_supervised(task_supervisor, timeout, fun)

      _expired ->
        :callback_failure
    end
  rescue
    _exception -> :callback_failure
  catch
    _kind, _reason -> :callback_failure
  end

  defp run_supervised(task_supervisor, timeout, fun) do
    if task_supervisor_alive?(task_supervisor) do
      try do
        task = Task.Supervisor.async_nolink(task_supervisor, fun)

        case Task.yield(task, timeout) do
          {:ok, value} ->
            {:ok, value}

          {:exit, _reason} ->
            :callback_failure

          nil ->
            _ = Task.shutdown(task, :brutal_kill)
            :callback_failure
        end
      catch
        :exit, _reason -> :callback_failure
      end
    else
      :callback_failure
    end
  end

  defp task_supervisor_alive?(task_supervisor) do
    case GenServer.whereis(task_supervisor) do
      pid when is_pid(pid) -> Process.alive?(pid)
      _other -> false
    end
  catch
    :exit, _reason -> false
  end

  defp normalize_discovery_to_envelope({:ok, {:discovery_result, result}}, snapshot, context) do
    context.method
    |> Result.normalize({:reply, result, fresh_frame(context)}, context, snapshot)
    |> normalize_to_envelope(context)
  end

  defp normalize_discovery_to_envelope({:ok, {:protocol_error, %Error{} = error}}, _snapshot, context) do
    emit_response(context, :error)
    respond_error(error, context.request_id)
  end

  defp normalize_discovery_to_envelope(_failure, _snapshot, context) do
    respond_callback_failure(context)
  end

  defp normalize_callback_to_envelope({:ok, {:callback_return, callback_return}}, snapshot, context) do
    context.method
    |> Result.normalize(callback_return, context, snapshot)
    |> normalize_to_envelope(context)
  end

  defp normalize_callback_to_envelope({:ok, {:protocol_error, %Error{} = error}}, _server, context) do
    emit_response(context, :error)
    respond_error(error, context.request_id)
  end

  defp normalize_callback_to_envelope(_failure, _server, context) do
    respond_callback_failure(context)
  end

  defp respond_callback_failure(%RequestContext{} = context) do
    Telemetry.execute(
      Telemetry.event_server_error(),
      %{system_time: System.system_time()},
      %{id: context.request_id, method: context.method, status: :callback_failure, era: :modern}
    )

    emit_response(context, :error)
    respond_error(Error.protocol(:internal_error), context.request_id)
  end

  defp respond_callback_failure(request) when is_map(request) do
    Telemetry.execute(
      Telemetry.event_server_error(),
      %{system_time: System.system_time()},
      %{
        id: request["id"],
        method: request["method"],
        status: :callback_failure,
        era: :modern
      }
    )

    respond_error(Error.protocol(:internal_error), request["id"])
  end

  defp normalize_to_envelope({:ok, result}, context) when is_map(result) do
    emit_response(context, :success)
    {:response, Message.build_response(result, context.request_id, context.protocol_version)}
  end

  defp normalize_to_envelope({:error, %Error{} = error}, context) do
    emit_response(context, :error)
    respond_error(error, context.request_id)
  end

  defp validate_method(%Profile{request_methods: methods}, method) when is_binary(method) do
    if method in methods,
      do: :ok,
      else: {:error, Error.protocol(:method_not_found, %{method: method})}
  end

  defp validate_method(_profile, _method), do: {:error, Error.protocol(:invalid_request)}

  defp validate_server_capability(_capabilities, "server/discover"), do: :ok

  defp validate_server_capability(capabilities, method) do
    capability = required_server_capability(method)

    if is_nil(capability) or server_capability?(capabilities, capability) do
      :ok
    else
      {:error, Error.protocol(:method_not_found, %{method: method})}
    end
  end

  defp required_server_capability("completion/complete"), do: :completions
  defp required_server_capability("prompts/" <> _action), do: :prompts
  defp required_server_capability("resources/" <> _action), do: :resources
  defp required_server_capability("tools/" <> _action), do: :tools
  defp required_server_capability(_method), do: nil

  defp server_capability?(capabilities, :completions) when is_map(capabilities) do
    Enum.any?(["completions", :completions, "completion", :completion], &Map.has_key?(capabilities, &1))
  end

  defp server_capability?(capabilities, capability) when is_map(capabilities) do
    Map.has_key?(capabilities, capability) or Map.has_key?(capabilities, Atom.to_string(capability))
  end

  defp server_capability?(_capabilities, _capability), do: false

  defp emit_request(context) do
    Telemetry.execute(
      Telemetry.event_server_request(),
      %{system_time: System.system_time()},
      %{id: context.request_id, method: context.method, era: :modern}
    )
  end

  defp emit_response(context, status) do
    Telemetry.execute(
      Telemetry.event_server_response(),
      %{system_time: System.system_time()},
      %{id: context.request_id, method: context.method, status: status, era: :modern}
    )
  end

  defp respond_error(%Error{} = error, id), do: {:response, Error.build_json_rpc(error, id)}

  defp normalize_timeout(timeout) when is_integer(timeout) and timeout > 0, do: timeout
  defp normalize_timeout(_timeout), do: @default_timeout

  defp remaining_timeout(deadline), do: deadline - System.monotonic_time(:millisecond)

  if Mix.env() == :test do
    defp inline_isolation?(opts), do: opts[:isolation] == :inline
  else
    defp inline_isolation?(_opts), do: false
  end
end

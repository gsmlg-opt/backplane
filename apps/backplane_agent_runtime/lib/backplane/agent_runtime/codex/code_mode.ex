defmodule Backplane.AgentRuntime.Codex.CodeMode do
  @moduledoc """
  Opt-in, capability-limited JavaScript Code Mode.

  JavaScript runs in a Deno worker with all Deno permissions denied. The only
  host capability exposed to the program is `codex.tool/2` (and its raw-input
  variant), which is routed back through a host-supplied admitted dispatcher.
  A yielded generator is retained in a run-owned ResourceRegistry handle.
  """

  alias Backplane.AgentRuntime.{Error, Codex.ResourceRegistry}

  @grammar """
  start: pragma_source | plain_source
  pragma_source: PRAGMA_LINE NEWLINE SOURCE
  plain_source: SOURCE

  PRAGMA_LINE: /[ \\t]*\\/\\/ @exec:[^\\r\\n]*/
  NEWLINE: /\\r?\\n/
  SOURCE: /[\\s\\S]+/
  """

  @default_timeout 5_000
  @default_code_limit 131_072
  @default_output_limit 1_048_576
  @default_tool_limit 32

  @spec contracts(map()) :: [map()]
  def contracts(%{resource_registry: registry} = context) when is_pid(registry) do
    if lifecycle_capability(context) == :verified and
         is_binary(Map.get(context, :deno_path, System.find_executable("deno"))) do
      [
        %{
          name: "exec",
          description:
            "Execute JavaScript in isolated Code Mode and call admitted tools through codex.tool.",
          input_kind: :custom,
          format: %{type: "grammar", syntax: "lark", definition: @grammar},
          backend: Backplane.AgentRuntime.Codex.Backend,
          backend_context: %{family: :code_mode, context: context},
          revision: 1,
          strict: false,
          safety: %{read_only: false, retry_safe: false, parallel_safe: false}
        },
        %{
          name: "wait",
          description: "Wait on or terminate a yielded Code Mode cell.",
          schema: wait_schema(),
          backend: Backplane.AgentRuntime.Codex.Backend,
          backend_context: %{family: :code_mode, context: context},
          revision: 1,
          strict: false,
          safety: %{read_only: false, retry_safe: false, parallel_safe: false}
        }
      ]
    else
      []
    end
  end

  def contracts(_context), do: []

  @doc "Returns whether the host can verify and clean up a Code Mode process."
  @spec lifecycle_capability(map()) :: :verified | {:unsupported, atom()}
  def lifecycle_capability(context) when is_map(context) do
    case Map.get(context, :process_lifecycle_capability) do
      :verified -> detect_lifecycle_capability()
      :unsupported -> {:unsupported, :host_declared_unavailable}
      _ -> detect_lifecycle_capability()
    end
  end

  def lifecycle_capability(_), do: {:unsupported, :invalid_context}

  @spec call(map()) :: {:ok, map()} | {:error, Error.t()}
  def call(%{tool_name: "exec", arguments: code, run_id: owner} = operation)
      when is_binary(code) and is_binary(owner) do
    with {:ok, context} <- backend_context(operation),
         {:ok, registry} <- required_registry(context),
         {:ok, nested_dispatch} <- nested_dispatch(operation),
         opts =
           code_options(context,
             dispatcher: fn request, _execution_context -> nested_dispatch.(request) end,
             execution_context: %{
               run_id: owner,
               authority: operation.effective_authority,
               catalog_revision: operation.catalog_revision
             },
             incarnation: operation.incarnation,
             owner_pid: operation.backend_context[:resource_owner_pid]
           ),
         {:ok, result} <- execute(registry, owner, code, opts) do
      {:ok, public_result(result)}
    end
  end

  def call(%{tool_name: "wait", arguments: arguments, run_id: owner} = operation)
      when is_map(arguments) and is_binary(owner) do
    with {:ok, context} <- backend_context(operation),
         {:ok, registry} <- required_registry(context),
         {:ok, handle} <- public_handle(arguments["cell_id"], owner, operation.incarnation) do
      if arguments["terminate"] == true do
        with {:ok, _} <- cancel(registry, handle, owner),
             do: {:ok, %{cell_id: arguments["cell_id"], status: :terminated}}
      else
        with {:ok, nested_dispatch} <- nested_dispatch(operation),
             {:ok, result} <-
               resume(registry, handle, nil,
                 owner: owner,
                 dispatcher: fn request, _execution_context -> nested_dispatch.(request) end,
                 execution_context: %{
                   run_id: owner,
                   authority: operation.effective_authority,
                   catalog_revision: operation.catalog_revision
                 }
               ),
             do: {:ok, public_result(result)}
      end
    end
  end

  def call(_operation), do: {:error, Error.new(:not_found, "unknown Code Mode tool")}

  @spec execute(pid(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def execute(registry, owner, code, opts \\ [])
      when is_pid(registry) and is_binary(owner) and is_binary(code) and is_list(opts) do
    with :ok <- validate_owner(owner),
         :ok <- require_lifecycle_capability(opts),
         :ok <- validate_code(code, opts),
         {:ok, context} <- execution_context(owner, opts),
         {:ok, dispatcher} <- dispatcher(opts),
         {:ok, supervisor} <- ResourceRegistry.worker_supervisor(registry),
         {:ok, worker} <-
           DynamicSupervisor.start_child(
             supervisor,
             {__MODULE__.Worker, worker_opts(code, context, dispatcher, opts)}
           ),
         {:ok, os_identity} <- __MODULE__.Worker.os_identity(worker),
         {:ok, handle} <-
           ResourceRegistry.register(registry, owner, :continuation, worker,
             incarnation: Keyword.get(opts, :incarnation, 1),
             owner_pid: Keyword.get(opts, :owner_pid) || self(),
             cleanup: fn -> safe_stop(worker, os_identity) end
           ),
         :ok <- __MODULE__.Worker.adopt(worker),
         result <- begin_worker(worker),
         {:ok, result} <- settle_execution(registry, owner, handle, result) do
      {:ok, result}
    end
  end

  @spec resume(pid(), map(), term(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def resume(registry, handle, value, opts \\ []) when is_pid(registry) and is_map(handle) do
    owner = Keyword.get(opts, :owner)

    with {:ok, owner} <- validate_resume_owner(owner),
         {:ok, worker} <- ResourceRegistry.fetch(registry, handle, owner) do
      case resume_worker(worker, value, opts) do
        {:ok, result} ->
          settle_resume(registry, handle, owner, result, opts)

        {:error, %Error{class: class} = error}
        when class in [:budget_exceeded, :resource_conflict] ->
          {:error, error}

        {:error, %Error{} = error} ->
          case ResourceRegistry.release(registry, handle, owner) do
            {:ok, _} -> {:error, error}
            {:error, %Error{} = cleanup_error} -> {:error, cleanup_error}
          end
      end
    end
  end

  @spec cancel(pid(), map(), String.t()) :: {:ok, term()} | {:error, Error.t()}
  def cancel(registry, handle, owner) when is_pid(registry) and is_map(handle) do
    ResourceRegistry.release(registry, handle, owner)
  end

  defp resume_worker(worker, value, opts) do
    try do
      __MODULE__.Worker.resume(
        worker,
        value,
        Keyword.get(opts, :dispatcher),
        Keyword.get(opts, :execution_context)
      )
    catch
      :exit, reason ->
        {:error,
         Error.new(:unknown_outcome, "code mode worker stopped before continuation settled",
           cause: reason
         )}
    end
  end

  defp begin_worker(worker) do
    try do
      __MODULE__.Worker.begin(worker)
    catch
      :exit, reason ->
        {:error,
         Error.new(:unknown_outcome, "code mode worker stopped before execution settled",
           cause: reason
         )}
    end
  end

  defp settle_execution(_registry, _owner, handle, {:ok, %{status: :yielded} = result}),
    do: {:ok, Map.put(result, :handle, handle)}

  defp settle_execution(registry, owner, handle, {:ok, result}) do
    with {:ok, _} <- ResourceRegistry.release(registry, handle, owner), do: {:ok, result}
  end

  defp settle_execution(registry, owner, handle, {:error, %Error{} = error}) do
    case ResourceRegistry.release(registry, handle, owner) do
      {:ok, _} -> {:error, error}
      {:error, %Error{} = cleanup_error} -> {:error, cleanup_error}
    end
  end

  defp settle_execution(registry, owner, handle, result) do
    _ = ResourceRegistry.release(registry, handle, owner)

    {:error,
     Error.new(:malformed_result, "code mode worker returned an invalid result", cause: result)}
  end

  defp safe_stop(worker, os_identity) do
    worker_result =
      if Process.alive?(worker) do
        ref = Process.monitor(worker)

        _result =
          try do
            __MODULE__.Worker.stop(worker)
          catch
            :exit, _ -> {:uncertain, :worker_stop_failed}
          end

        worker_down =
          receive do
            {:DOWN, ^ref, :process, ^worker, _} -> :ok
          after
            2_000 ->
              Process.demonitor(ref, [:flush])
              {:uncertain, :worker_still_alive}
          end

        if worker_down == :ok, do: :ok, else: worker_down
      else
        :ok
      end

    os_result = __MODULE__.Worker.cleanup_identity(os_identity)

    case {worker_result, os_result} do
      {:ok, :ok} -> :ok
      {{:uncertain, reason}, _} -> {:uncertain, reason}
      {_, {:uncertain, reason}} -> {:uncertain, reason}
    end
  end

  defp settle_resume(registry, handle, owner, %{status: :completed} = result, _opts) do
    with {:ok, _cleanup} <- ResourceRegistry.release(registry, handle, owner), do: {:ok, result}
  end

  defp settle_resume(_registry, _handle, _owner, result, _opts), do: {:ok, result}

  defp worker_opts(code, context, dispatcher, opts) do
    [
      code: code,
      context: context,
      dispatcher: dispatcher,
      timeout: Keyword.get(opts, :timeout, @default_timeout),
      output_limit: Keyword.get(opts, :output_limit, @default_output_limit),
      tool_limit: Keyword.get(opts, :tool_limit, @default_tool_limit),
      code_limit: Keyword.get(opts, :code_limit, @default_code_limit),
      deno_path: Keyword.get(opts, :deno_path),
      creator_pid: self()
    ]
  end

  defp execution_context(owner, opts) do
    context = Keyword.get(opts, :execution_context, %{})

    if is_map(context) and Map.get(context, :run_id, owner) == owner,
      do: {:ok, Map.put_new(context, :run_id, owner) |> Map.put_new(:owner_id, owner)},
      else: {:error, Error.new(:forbidden, "code mode execution context is not owner-bound")}
  end

  defp dispatcher(opts) do
    case Keyword.get(opts, :dispatcher) do
      fun when is_function(fun, 2) ->
        {:ok, fun}

      _ ->
        {:error,
         Error.new(:unsupported_capability, "code mode requires an admitted tool dispatcher")}
    end
  end

  defp validate_owner(owner) when owner != "", do: :ok
  defp validate_owner(_), do: {:error, Error.new(:validation, "code mode owner is required")}

  defp require_lifecycle_capability(opts) do
    context = Keyword.get(opts, :host_context, %{})

    case lifecycle_capability(context) do
      :verified ->
        :ok

      {:unsupported, reason} ->
        {:error,
         Error.new(
           :unsupported_capability,
           "Code Mode process lifecycle verification is unavailable",
           details: %{reason: reason}
         )}
    end
  end

  defp detect_lifecycle_capability do
    cond do
      :os.type() != {:unix, :linux} -> {:unsupported, :linux_process_identity_required}
      not is_binary(System.find_executable("kill")) -> {:unsupported, :kill_unavailable}
      not File.dir?("/proc") -> {:unsupported, :proc_unavailable}
      true -> :verified
    end
  end

  defp validate_code(code, opts) do
    limit = Keyword.get(opts, :code_limit, @default_code_limit)

    if byte_size(code) <= limit,
      do: :ok,
      else: {:error, Error.new(:budget_exceeded, "code mode source exceeds the configured bound")}
  end

  defp validate_resume_owner(owner) when is_binary(owner) and owner != "", do: {:ok, owner}
  defp validate_resume_owner(_), do: {:error, Error.new(:validation, "resume owner is required")}

  defp backend_context(%{backend_context: %{context: context}}) when is_map(context),
    do: {:ok, context}

  defp backend_context(_),
    do: {:error, Error.new(:unsupported_capability, "Code Mode context is unavailable")}

  defp required_registry(%{resource_registry: registry}) when is_pid(registry),
    do: {:ok, registry}

  defp required_registry(_),
    do: {:error, Error.new(:unsupported_capability, "Code Mode resource registry is unavailable")}

  defp nested_dispatch(%{backend_context: %{nested_dispatch: dispatch}})
       when is_function(dispatch, 1),
       do: {:ok, dispatch}

  defp nested_dispatch(_),
    do: {:error, Error.new(:unsupported_capability, "Code Mode nested dispatch is unavailable")}

  defp code_options(context, required) do
    required ++
      [
        timeout: Map.get(context, :timeout, @default_timeout),
        output_limit: Map.get(context, :output_limit, @default_output_limit),
        tool_limit: Map.get(context, :tool_limit, @default_tool_limit),
        code_limit: Map.get(context, :code_limit, @default_code_limit),
        deno_path: Map.get(context, :deno_path),
        host_context: context
      ]
  end

  defp public_result(%{handle: %{resource_id: cell_id}} = result) do
    result |> Map.delete(:handle) |> Map.put(:cell_id, cell_id)
  end

  defp public_result(result), do: result

  defp public_handle(cell_id, owner, incarnation)
       when is_binary(cell_id) and cell_id != "" and is_integer(incarnation) do
    {:ok, %{resource_id: cell_id, owner_id: owner, incarnation: incarnation, kind: :continuation}}
  end

  defp public_handle(_, _, _), do: {:error, Error.new(:validation, "cell_id is required")}

  defp wait_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["cell_id"],
      "properties" => %{
        "cell_id" => %{"type" => "string"},
        "yield_time_ms" => %{"type" => "integer", "minimum" => 0},
        "max_tokens" => %{"type" => "integer", "minimum" => 1},
        "terminate" => %{"type" => "boolean"}
      }
    }
  end

  defmodule Worker do
    use GenServer

    def child_spec(opts) do
      %{
        id: __MODULE__,
        start: {__MODULE__, :start_link, [opts]},
        restart: :temporary,
        shutdown: 5_000,
        type: :worker
      }
    end

    @max_line 1_048_576
    @term_wait_ms 150
    @kill_wait_ms 350

    alias Backplane.AgentRuntime.Error

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def begin(pid), do: GenServer.call(pid, :begin, :infinity)

    def resume(pid, value, dispatcher, context),
      do: GenServer.call(pid, {:resume, value, dispatcher, context}, :infinity)

    def stop(pid), do: GenServer.call(pid, :stop, 3_000)
    def adopt(pid), do: GenServer.call(pid, :adopt)
    def os_identity(pid), do: GenServer.call(pid, :os_identity)

    @impl true
    def init(opts) do
      Process.flag(:trap_exit, true)

      with {:ok, deno} <- deno_path(Keyword.get(opts, :deno_path)),
           {:ok, task_supervisor} <- Task.Supervisor.start_link(),
           {:ok, port} <- open_port(deno, opts),
           {:ok, identity} <- capture_os_identity(port) do
        {:ok,
         %{
           port: port,
           os_identity: identity,
           os_cleanup_status: nil,
           task_supervisor: task_supervisor,
           creator_ref:
             case Keyword.get(opts, :creator_pid) do
               pid when is_pid(pid) -> Process.monitor(pid)
               _ -> nil
             end,
           code: Keyword.fetch!(opts, :code),
           context: Keyword.fetch!(opts, :context),
           dispatcher: Keyword.fetch!(opts, :dispatcher),
           timeout: Keyword.fetch!(opts, :timeout),
           output_limit: Keyword.fetch!(opts, :output_limit),
           tool_limit: Keyword.fetch!(opts, :tool_limit),
           timer: nil,
           from: nil,
           awaiting_resume: false,
           active_tool: nil,
           tool_count: 0,
           buffer: ""
         }}
      else
        {:error, %Error{} = error} -> {:stop, error}
      end
    end

    @impl true
    def handle_call(:os_identity, _from, state),
      do: {:reply, {:ok, state.os_identity}, state}

    def handle_call(:stop, _from, state) do
      status = cleanup_os(state)
      {:stop, :normal, status, %{state | os_cleanup_status: status}}
    end

    def handle_call(:adopt, _from, state) do
      if state.creator_ref, do: Process.demonitor(state.creator_ref, [:flush])
      {:reply, :ok, %{state | creator_ref: nil}}
    end

    def handle_call(:begin, from, state) do
      send_command(state.port, %{type: "execute", code: state.code})
      {:noreply, arm(state, from)}
    end

    def handle_call(
          {:resume, value, dispatcher, context},
          from,
          %{from: nil, awaiting_resume: true} = state
        ) do
      if bounded_term?(value, state.output_limit) do
        state = rebind(state, dispatcher, context)
        send_command(state.port, %{type: "resume", value: value})
        {:noreply, arm(%{state | from: from, awaiting_resume: false}, from)}
      else
        {:reply,
         {:error, Error.new(:budget_exceeded, "continuation value exceeds the configured bound")},
         state}
      end
    end

    def handle_call({:resume, _value, _dispatcher, _context}, _from, state),
      do:
        {:reply,
         {:error, Error.new(:resource_conflict, "code mode is not awaiting a continuation")},
         state}

    defp rebind(state, nil, nil), do: state

    defp rebind(state, dispatcher, context) when is_function(dispatcher, 2) and is_map(context),
      do: %{state | dispatcher: dispatcher, context: context}

    @impl true
    def handle_info({:DOWN, ref, :process, _pid, _reason}, %{creator_ref: ref} = state),
      do: {:stop, :normal, state}

    def handle_info({port, {:data, chunk}}, %{port: port} = state) when is_binary(chunk) do
      consume_data(state, state.buffer <> chunk)
    end

    def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
      error =
        if state.buffer == "" do
          Error.new(:execution_failure, "code mode worker exited",
            details: %{exit_status: status}
          )
        else
          Error.new(:malformed_result, "incomplete code mode record at EOF")
        end

      fail(state, error)
    end

    def handle_info({ref, result}, %{active_tool: %{ref: ref}} = state) do
      Process.demonitor(ref, [:flush])

      case normalize_dispatch_result(result, state.context) do
        {:ok, value, context} ->
          send_command(state.port, %{
            type: "tool_result",
            id: state.active_tool.id,
            ok: true,
            value: value
          })

          {:noreply, %{state | active_tool: nil, context: context}}

        {:error, %Error{} = error} ->
          send_command(state.port, %{
            type: "tool_result",
            id: state.active_tool.id,
            ok: false,
            error: Error.to_map(error)
          })

          {:noreply, %{state | active_tool: nil}}
      end
    end

    def handle_info({:DOWN, ref, :process, _pid, reason}, %{active_tool: %{ref: ref}} = state) do
      handle_info(
        {ref,
         {:error, Error.new(:execution_failure, "nested tool dispatcher stopped", cause: reason)}},
        state
      )
    end

    def handle_info(:deadline, state),
      do: fail(state, Error.new(:timeout, "code mode execution timed out"))

    def handle_info({:EXIT, port, reason}, %{port: port} = state) do
      fail(state, Error.new(:execution_failure, "code mode worker exited", cause: reason))
    end

    def handle_info(_message, state), do: {:noreply, state}

    @impl true
    def terminate(_reason, state) do
      if state.os_cleanup_status != :ok, do: cleanup_os(state)

      if is_pid(state.task_supervisor), do: Supervisor.stop(state.task_supervisor, :shutdown)
      :ok
    end

    defp handle_line(line, state) do
      case JSON.decode(line) do
        {:ok, %{"type" => "tool_call"} = message} ->
          tool_call(message, state)

        {:ok, %{"type" => "yield"} = message} ->
          deliver_value(state, :yielded, message["value"])

        {:ok, %{"type" => "complete"} = message} ->
          deliver_value(state, :completed, message["value"])

        {:ok, %{"type" => "error", "error" => error}} ->
          finish(state, {:error, decode_error(error)})

        _ ->
          fail(state, Error.new(:malformed_result, "invalid code mode worker response"))
      end
    end

    defp deliver_value(state, status, value) do
      if bounded_term?(value, state.output_limit) do
        result = {:ok, %{status: status, value: value}}

        case status do
          :yielded -> pause(state, result)
          :completed -> finish(state, result)
        end
      else
        fail(state, Error.new(:budget_exceeded, "code mode result exceeds the configured bound"))
      end
    end

    defp tool_call(%{"id" => id, "name" => name} = message, %{active_tool: nil} = state)
         when is_binary(id) and is_binary(name) do
      if state.tool_count >= state.tool_limit do
        fail(state, Error.new(:budget_exceeded, "code mode nested tool limit exceeded"))
      else
        request = %{
          tool_name: name,
          input_kind: if(is_binary(message["rawInput"]), do: :custom, else: :function),
          arguments: message["arguments"],
          raw_input: message["rawInput"]
        }

        task =
          Task.Supervisor.async_nolink(state.task_supervisor, fn ->
            state.dispatcher.(request, state.context)
          end)

        {:noreply,
         %{state | active_tool: %{id: id, ref: task.ref}, tool_count: state.tool_count + 1}}
      end
    end

    defp tool_call(%{"id" => id}, state) when is_binary(id) do
      send_command(state.port, %{
        type: "tool_result",
        id: id,
        ok: false,
        error: Error.to_map(Error.new(:resource_conflict, "concurrent nested calls are rejected"))
      })

      {:noreply, state}
    end

    defp tool_call(_message, state),
      do: fail(state, Error.new(:validation, "invalid nested tool call"))

    defp normalize_dispatch_result({:ok, value}, context), do: {:ok, value, context}

    defp normalize_dispatch_result({:ok, value, next_context}, _context)
         when is_map(next_context),
         do: {:ok, value, next_context}

    defp normalize_dispatch_result({:error, %Error{} = error}, _context), do: {:error, error}

    defp normalize_dispatch_result(other, _context),
      do:
        {:error,
         Error.new(:malformed_result, "nested dispatcher returned an invalid result",
           cause: other
         )}

    defp finish(%{from: nil} = state, _result), do: {:stop, :normal, state}

    defp finish(state, result) do
      if state.timer, do: Process.cancel_timer(state.timer)
      status = cleanup_os(state)

      result =
        if status == :ok,
          do: result,
          else:
            {:error,
             Error.new(:unknown_outcome, "code mode OS worker cleanup is unconfirmed",
               cause: status
             )}

      GenServer.reply(state.from, result)
      {:stop, :normal, %{state | from: nil, awaiting_resume: false, os_cleanup_status: status}}
    end

    defp pause(%{from: nil} = state, _result),
      do: fail(state, Error.new(:resource_conflict, "unexpected code mode yield"))

    defp pause(state, result) do
      if state.timer, do: Process.cancel_timer(state.timer)
      GenServer.reply(state.from, result)
      {:noreply, %{state | from: nil, timer: nil, awaiting_resume: true}}
    end

    defp fail(state, error), do: finish(state, {:error, error})

    defp arm(state, from),
      do: %{
        state
        | from: from,
          awaiting_resume: false,
          timer: Process.send_after(self(), :deadline, state.timeout)
      }

    defp capture_os_identity(port) do
      case Port.info(port, :os_pid) do
        {:os_pid, pid} when is_integer(pid) and pid > 0 ->
          case proc_identity(pid) do
            {:ok, %{starttime: starttime}} -> {:ok, %{pid: pid, starttime: starttime}}
            _ -> {:ok, nil}
          end

        _ ->
          {:ok, nil}
      end
    end

    defp cleanup_os(state) do
      close_port(state.port)
      cleanup_identity(state.os_identity)
    end

    def cleanup_identity(nil), do: {:uncertain, :os_process_identity_unavailable}

    def cleanup_identity(%{pid: pid, starttime: starttime} = identity)
        when is_integer(pid) and is_binary(starttime) do
      case probe_identity(identity) do
        :gone ->
          :ok

        :running ->
          case signal_and_wait(identity, "-TERM", @term_wait_ms) do
            :ok ->
              :ok

            {:uncertain, :still_running} ->
              signal_and_wait(identity, "-KILL", @kill_wait_ms)

            other ->
              other
          end

        {:uncertain, reason} ->
          {:uncertain, reason}
      end
    end

    defp signal_and_wait(%{pid: pid} = identity, signal, wait_ms) do
      case signal_pid(pid, signal) do
        :ok ->
          await_absence(identity, wait_ms)

        {:uncertain, _} = error ->
          if probe_identity(identity) == :gone, do: :ok, else: error
      end
    end

    defp close_port(port) when is_port(port) do
      try do
        Port.close(port)
      catch
        :error, :badarg -> :ok
      end
    end

    defp signal_pid(pid, signal) do
      case System.find_executable("kill") do
        nil ->
          {:uncertain, :kill_executable_unavailable}

        executable ->
          case System.cmd(executable, [signal, "--", Integer.to_string(pid)],
                 stderr_to_stdout: true
               ) do
            {_output, 0} -> :ok
            {_output, _status} -> {:uncertain, :os_signal_failed}
          end
      end
    rescue
      _ -> {:uncertain, :os_signal_failed}
    end

    defp await_absence(identity, wait_ms) do
      deadline = System.monotonic_time(:millisecond) + wait_ms
      await_absence_until(identity, deadline)
    end

    defp await_absence_until(identity, deadline) do
      case probe_identity(identity) do
        :gone ->
          :ok

        :running ->
          if System.monotonic_time(:millisecond) >= deadline do
            {:uncertain, :still_running}
          else
            Process.sleep(10)
            await_absence_until(identity, deadline)
          end

        {:uncertain, reason} ->
          {:uncertain, reason}
      end
    end

    defp probe_identity(%{pid: pid, starttime: starttime}) do
      case proc_identity(pid) do
        {:ok, %{starttime: ^starttime, state: state}} when state in ["Z", "X"] -> :gone
        {:ok, %{starttime: ^starttime}} -> :running
        {:ok, _other} -> :gone
        {:error, :enoent} -> :gone
        {:error, reason} -> {:uncertain, {:proc_probe_failed, reason}}
      end
    end

    defp proc_identity(pid) do
      with {:ok, stat} <- File.read("/proc/#{pid}/stat"),
           [_, fields] <- Regex.run(~r/^\d+ \(.*\) (.+)$/s, stat),
           parts <- String.split(fields),
           state when is_binary(state) <- Enum.at(parts, 0),
           starttime when is_binary(starttime) <- Enum.at(parts, 19) do
        {:ok, %{state: state, starttime: starttime}}
      else
        {:error, reason} -> {:error, reason}
        _ -> {:error, :malformed_proc_stat}
      end
    end

    defp send_command(port, command), do: Port.command(port, JSON.encode!(command) <> "\n")

    defp open_port(deno, _opts) do
      args = [
        "run",
        "--no-config",
        "--quiet",
        "--deny-read",
        "--deny-write",
        "--deny-net",
        "--deny-env",
        "--deny-run",
        "--deny-sys",
        "--deny-ffi",
        "--deny-import",
        "--ext=js",
        "data:application/javascript;base64," <> Base.encode64(wrapper())
      ]

      port =
        Port.open({:spawn_executable, deno}, [
          :binary,
          :exit_status,
          {:args, args}
        ])

      {:ok, port}
    rescue
      exception ->
        {:error,
         Error.new(:unsupported_capability, "unable to start Deno code mode", cause: exception)}
    end

    defp deno_path(nil), do: deno_path(System.find_executable("deno"))
    defp deno_path(path) when is_binary(path), do: {:ok, path}
    defp deno_path(_), do: {:error, Error.new(:unsupported_capability, "Deno is not installed")}

    defp bounded_term?(value, limit), do: :erlang.external_size(value) <= limit

    defp consume_data(state, data) do
      case :binary.match(data, "\n") do
        :nomatch when byte_size(data) <= @max_line ->
          {:noreply, %{state | buffer: data}}

        {length, 1} when length <= @max_line ->
          <<line::binary-size(^length), _newline, rest::binary>> = data

          case handle_line(String.trim_trailing(line, "\r"), %{state | buffer: ""}) do
            {:noreply, next_state} -> consume_data(next_state, rest)
            other -> other
          end

        _ ->
          fail(
            state,
            Error.new(:budget_exceeded, "code mode protocol line exceeds the configured bound")
          )
      end
    end

    defp decode_error(%{"class" => class, "message" => message}) when is_binary(class) do
      allowed =
        ~w(validation forbidden approval_required not_found timeout cancelled transient_transport resource_conflict execution_failure malformed_result budget_exceeded unsupported_capability unknown_outcome overloaded)a

      normalized =
        if class in Enum.map(allowed, &Atom.to_string/1),
          do: String.to_existing_atom(class),
          else: :execution_failure

      Error.new(normalized, message)
    end

    defp decode_error(_), do: Error.new(:execution_failure, "JavaScript execution failed")

    @external_resource Path.expand("../../../../priv/codex/code_mode_worker.js", __DIR__)
    @worker_source File.read!(@external_resource)
    defp wrapper, do: @worker_source
  end
end

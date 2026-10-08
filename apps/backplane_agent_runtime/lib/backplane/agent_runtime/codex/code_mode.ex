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

  @default_timeout 30_000
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
            "Execute isolated JavaScript with tools, ALL_TOOLS, text/image/audio, generatedImage, store/load, notify, exit and yield_control. A first-line // @exec: JSON pragma sets yield_time_ms and max_output_tokens. Wait only on returned cell_id; each wait returns new output and uses current admitted authority.",
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
  def call(%{tool_name: "exec", arguments: code, run_id: run_id} = operation)
      when is_binary(code) and is_binary(run_id) do
    with {:ok, context} <- backend_context(operation),
         {:ok, registry} <- required_registry(context),
         resource_owner = resource_owner(operation),
         owner = resource_owner.owner_id,
         {:ok, nested_dispatch} <- nested_dispatch(operation),
         {:ok, slice} <- source_options(code),
         opts =
           code_options(context,
             yield_time_ms: slice.yield_time_ms,
             max_tokens: slice.max_output_tokens,
             tools: tool_metadata(operation),
             dispatcher: fn request, execution_context ->
               suspend = Map.get(execution_context, :suspend)
               if is_function(suspend, 0), do: suspend.()

               try do
                 nested_dispatch.(request)
               after
                 resume = Map.get(execution_context, :resume)
                 if is_function(resume, 0), do: resume.()
               end
             end,
             execution_context: %{
               emit: operation.backend_context[:emit],
               run_id: run_id,
               owner_id: owner,
               authority: operation.effective_authority,
               catalog_revision: operation.catalog_revision
             },
             incarnation: resource_owner.incarnation,
             owner_pid: resource_owner.owner_pid
           ),
         {:ok, result} <- execute(registry, owner, code, opts) do
      {:ok, public_result(result)}
    end
  end

  def call(%{tool_name: "wait", arguments: arguments, run_id: run_id} = operation)
      when is_map(arguments) and is_binary(run_id) do
    with {:ok, context} <- backend_context(operation),
         {:ok, registry} <- required_registry(context),
         resource_owner = resource_owner(operation),
         owner = resource_owner.owner_id,
         {:ok, handle} <- public_handle(arguments["cell_id"], owner, resource_owner.incarnation) do
      if arguments["terminate"] == true do
        with {:ok, _} <- cancel(registry, handle, owner),
             do: {:ok, %{cell_id: arguments["cell_id"], status: :terminated}}
      else
        with {:ok, nested_dispatch} <- nested_dispatch(operation),
             {:ok, result} <-
               resume(registry, handle, nil,
                 owner: owner,
                 tools: tool_metadata(operation),
                 yield_time_ms: arguments["yield_time_ms"] || 10_000,
                 max_tokens: arguments["max_tokens"] || 10_000,
                 dispatcher: fn request, execution_context ->
                   suspend = Map.get(execution_context, :suspend)
                   if is_function(suspend, 0), do: suspend.()

                   try do
                     nested_dispatch.(request)
                   after
                     resume = Map.get(execution_context, :resume)
                     if is_function(resume, 0), do: resume.()
                   end
                 end,
                 execution_context: %{
                   emit: operation.backend_context[:emit],
                   run_id: run_id,
                   owner_id: owner,
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
         stored when is_map(stored) <-
           ResourceRegistry.code_state(registry, owner, Keyword.get(opts, :incarnation, 1)),
         {:ok, dispatcher} <- dispatcher(opts),
         {:ok, supervisor} <- ResourceRegistry.worker_supervisor(registry),
         {:ok, worker} <-
           DynamicSupervisor.start_child(
             supervisor,
             {__MODULE__.Worker,
              worker_opts(code, context, dispatcher, Keyword.put(opts, :registry, registry))}
           ),
         {:ok, os_identity} <- __MODULE__.Worker.os_identity(worker),
         {:ok, handle} <-
           register_worker(registry, owner, worker, os_identity, opts),
         :ok <- __MODULE__.Worker.adopt(worker, handle),
         result <- begin_worker(worker),
         {:ok, result} <- settle_execution(registry, owner, handle, result) do
      {:ok, result}
    end
  end

  defp register_worker(registry, owner, worker, identity, opts) do
    result =
      ResourceRegistry.register(registry, owner, :continuation, worker,
        incarnation: Keyword.get(opts, :incarnation, 1),
        owner_pid: Keyword.get(opts, :owner_pid) || self(),
        cleanup: fn -> safe_stop(worker, identity) end
      )

    case result do
      {:ok, _} ->
        result

      {:error, error} ->
        case safe_stop(worker, identity) do
          :ok ->
            {:error, error}

          evidence ->
            {:error,
             Error.new(:unknown_outcome, "unregistered Code Mode worker cleanup is unconfirmed",
               cause: evidence
             )}
        end
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

        {:rejected, %Error{} = error} ->
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
        Keyword.get(opts, :execution_context),
        Keyword.get(opts, :yield_time_ms),
        Keyword.get(opts, :max_tokens, 10_000),
        Keyword.get(opts, :tools)
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
      creator_pid: self(),
      registry: Keyword.fetch!(opts, :registry),
      tools: Keyword.get(opts, :tools, []),
      yield_time_ms: Keyword.get(opts, :yield_time_ms),
      max_tokens: Keyword.get(opts, :max_tokens, 10_000),
      incarnation: Keyword.get(opts, :incarnation, 1)
    ]
  end

  defp execution_context(owner, opts) do
    context = Keyword.get(opts, :execution_context, %{})

    if is_map(context) and Map.get(context, :owner_id, Map.get(context, :run_id, owner)) == owner,
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

  defp resource_owner(operation) do
    Map.get(operation.backend_context, :resource_owner, %{
      owner_id: operation.run_id,
      incarnation: operation.incarnation,
      owner_pid: operation.backend_context[:resource_owner_pid]
    })
  end

  defp source_options(code) do
    case String.split(code, "\n", parts: 2) do
      [line, source] ->
        case String.trim_leading(line) do
          "// @exec:" <> json ->
            with false <- String.trim(source) == "",
                 {:ok, map} when is_map(map) <- JSON.decode(String.trim(json)),
                 true <-
                   Enum.all?(Map.keys(map), &(&1 in ["yield_time_ms", "max_output_tokens"])),
                 time when is_integer(time) and time >= 0 and time <= 300_000 <-
                   Map.get(map, "yield_time_ms") || 10_000,
                 tokens when is_integer(tokens) and tokens >= 0 and tokens <= 262_144 <-
                   Map.get(map, "max_output_tokens") || 10_000 do
              {:ok, %{yield_time_ms: time, max_output_tokens: tokens}}
            else
              _ -> {:error, Error.new(:validation, "invalid Code Mode pragma")}
            end

          _ ->
            default_source_options(code)
        end

      [line] ->
        if String.starts_with?(String.trim_leading(line), "// @exec:"),
          do: {:error, Error.new(:validation, "Code Mode pragma requires following source")},
          else: default_source_options(code)
    end
  end

  defp default_source_options(code) do
    if String.trim(code) == "",
      do: {:error, Error.new(:validation, "Code Mode source must not be empty")},
      else: {:ok, %{yield_time_ms: 10_000, max_output_tokens: 10_000}}
  end

  defp tool_metadata(operation) do
    case operation.backend_context[:catalog_snapshot] do
      %{registry: %{tools: tools}} ->
        tools
        |> Map.values()
        |> Enum.reject(&(&1.tool_name in ["exec", "wait"]))
        |> Enum.filter(&(&1.tool_name in operation.effective_authority.grants))
        |> Enum.map(fn tool ->
          %{
            name: String.replace(tool.tool_name, "::", "__"),
            tool_name: tool.tool_name,
            description: Map.get(tool, :description, ""),
            input_kind: Map.get(tool, :codex_input_kind, :function)
          }
        end)

      _ ->
        []
    end
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

    def resume(
          pid,
          value,
          dispatcher,
          context,
          yield_time_ms \\ nil,
          max_tokens \\ 10_000,
          tools \\ nil
        ),
        do:
          GenServer.call(
            pid,
            {:resume, value, dispatcher, context, yield_time_ms, max_tokens, tools},
            :infinity
          )

    def ready_for_detach(pid), do: GenServer.call(pid, :ready_for_detach)

    def stop(pid), do: GenServer.call(pid, :stop, 3_000)
    def adopt(pid, handle \\ nil), do: GenServer.call(pid, {:adopt, handle})
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
           handle: nil,
           code: Keyword.fetch!(opts, :code),
           context: Keyword.fetch!(opts, :context),
           dispatcher: Keyword.fetch!(opts, :dispatcher),
           timeout: Keyword.fetch!(opts, :timeout),
           output_limit: Keyword.fetch!(opts, :output_limit),
           tool_limit: Keyword.fetch!(opts, :tool_limit),
           registry: Keyword.get(opts, :registry),
           stored:
             case Keyword.get(opts, :registry) do
               registry when is_pid(registry) ->
                 ResourceRegistry.code_state(
                   registry,
                   Keyword.fetch!(opts, :context).owner_id,
                   Keyword.get(opts, :incarnation, 1)
                 )

               _ ->
                 %{}
             end,
           tools: Keyword.get(opts, :tools, []),
           yield_time_ms: Keyword.get(opts, :yield_time_ms),
           max_tokens: Keyword.get(opts, :max_tokens, 10_000),
           outputs: [],
           output_bytes: 0,
           slice_timer: nil,
           slice_generation: nil,
           timer_generation: nil,
           continuation_kind: nil,
           pending_tool: nil,
           pending_yield: nil,
           terminal_result: nil,
           timer: nil,
           from: nil,
           awaiting_resume: false,
           timer_deadline: nil,
           paused_remaining: nil,
           active_tool: nil,
           tool_count: 0,
           buffer: ""
         }}
      else
        {:error, %Error{} = error} -> {:stop, error}
      end
    end

    @impl true
    def handle_call(:ready_for_detach, _from, state),
      do:
        {:reply,
         is_nil(state.from) and is_nil(state.active_tool) and
           not match?({:error, %Error{}}, state.terminal_result), state}

    def handle_call(:os_identity, _from, state),
      do: {:reply, {:ok, state.os_identity}, state}

    def handle_call(:stop, _from, state) do
      status = cleanup_os(state)
      {:stop, :normal, status, %{state | os_cleanup_status: status}}
    end

    def handle_call({:adopt, handle}, _from, state) do
      if state.creator_ref, do: Process.demonitor(state.creator_ref, [:flush])
      {:reply, :ok, %{state | creator_ref: nil, handle: handle}}
    end

    def handle_call(:begin, from, state) do
      send_command(state.port, %{
        type: "execute",
        code: state.code,
        tools: state.tools,
        stored: state.stored
      })

      {:noreply, arm(state, from)}
    end

    def handle_call(:suspend_timer, _from, state) do
      remaining =
        case state.timer_deadline do
          deadline when is_integer(deadline) ->
            max(0, deadline - System.monotonic_time(:millisecond))

          _ ->
            nil
        end

      if state.timer, do: Process.cancel_timer(state.timer)
      {:reply, :ok, %{state | timer: nil, timer_deadline: nil, paused_remaining: remaining}}
    end

    def handle_call(:resume_timer, _from, state) do
      remaining = state.paused_remaining

      if is_integer(remaining) do
        generation = make_ref()
        timer = Process.send_after(self(), {:deadline, generation}, remaining)

        {:reply, :ok,
         %{
           state
           | timer: timer,
             timer_generation: generation,
             timer_deadline: System.monotonic_time(:millisecond) + remaining,
             paused_remaining: nil
         }}
      else
        {:reply, :ok, state}
      end
    end

    def handle_call(
          {:resume, value, dispatcher, context, slice, tokens, tools},
          from,
          %{from: nil} = state
        ) do
      with true <- bounded_term?(value, state.output_limit),
           stored when is_map(stored) <- refreshed_store(state) do
        state = rebind(state, dispatcher, context)

        if state.terminal_result == nil do
          send_command(state.port, %{
            type: "configure",
            tools: tools || state.tools,
            stored: stored
          })
        end

        state = %{state | yield_time_ms: slice, max_tokens: tokens, tools: tools || state.tools}

        cond do
          state.terminal_result != nil ->
            finish(%{state | from: from}, state.terminal_result)

          state.awaiting_resume ->
            send_command(state.port, %{type: "resume", value: value})
            {:noreply, arm(%{state | awaiting_resume: false}, from)}

          true ->
            state = arm(state, from)

            case state.pending_tool do
              nil -> {:noreply, state}
              message -> tool_call(message, %{state | pending_tool: nil})
            end
        end
      else
        false ->
          {:reply,
           {:rejected,
            Error.new(:budget_exceeded, "continuation value exceeds the configured bound")},
           state}

        {:error, %Error{} = error} ->
          fail(%{state | from: from}, error)
      end
    end

    def handle_call({:resume, _, _, _, _, _, _}, _from, state),
      do:
        {:reply, {:rejected, Error.new(:resource_conflict, "Code Mode already has a waiter")},
         state}

    defp refreshed_store(%{terminal_result: result}) when not is_nil(result), do: %{}

    defp refreshed_store(state),
      do:
        ResourceRegistry.code_state(
          state.registry,
          state.context.owner_id,
          state.handle.incarnation
        )

    defp rebind(state, nil, nil), do: state

    defp rebind(state, dispatcher, context) when is_function(dispatcher, 2) and is_map(context),
      do: %{state | dispatcher: dispatcher, context: context}

    @impl true
    def handle_info({:DOWN, ref, :process, _pid, _reason}, %{creator_ref: ref} = state),
      do: {:stop, :normal, state}

    def handle_info({port, _event}, %{port: port, terminal_result: result} = state)
        when not is_nil(result),
        do: {:noreply, state}

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

          complete_tool(%{state | active_tool: nil, context: context})

        {:error, %Error{class: :unknown_outcome} = error} ->
          fail(%{state | active_tool: nil}, error)

        {:error, %Error{} = error} ->
          send_command(state.port, %{
            type: "tool_result",
            id: state.active_tool.id,
            ok: false,
            error: Error.to_map(error)
          })

          complete_tool(%{state | active_tool: nil})
      end
    end

    def handle_info({:DOWN, ref, :process, _pid, reason}, %{active_tool: %{ref: ref}} = state) do
      handle_info(
        {ref,
         {:error,
          Error.new(:unknown_outcome, "nested tool dispatcher stopped before settlement",
            cause: reason
          )}},
        state
      )
    end

    def handle_info(
          {:deadline, generation},
          %{timer_generation: generation, timer: timer} = state
        )
        when is_reference(timer),
        do: fail(state, Error.new(:timeout, "code mode execution timed out"))

    def handle_info({:deadline, _generation}, state), do: {:noreply, state}
    def handle_info(:deadline, state), do: {:noreply, state}

    def handle_info(
          {:slice, generation},
          %{slice_generation: generation, from: from, active_tool: nil} = state
        )
        when not is_nil(from),
        do: running_yield(state)

    def handle_info({:slice, generation}, %{slice_generation: generation, from: from} = state)
        when not is_nil(from) do
      timer = Process.send_after(self(), {:slice, generation}, 10)
      {:noreply, %{state | slice_timer: timer}}
    end

    def handle_info({:slice, _}, state), do: {:noreply, state}

    def handle_info({:EXIT, port, _reason}, %{port: port, terminal_result: result} = state)
        when not is_nil(result),
        do: {:noreply, state}

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

    defp handle_line(_line, %{terminal_result: result} = state) when not is_nil(result),
      do: {:noreply, state}

    defp handle_line(line, state) do
      case JSON.decode(line) do
        {:ok, %{"type" => "output", "item" => item}} ->
          bytes = Map.get(state, :output_bytes, 0) + byte_size(JSON.encode!(item))

          if bytes <= state.output_limit,
            do: {:noreply, %{state | outputs: state.outputs ++ [item], output_bytes: bytes}},
            else: fail(state, Error.new(:budget_exceeded, "Code Mode output exceeds its bound"))

        {:ok, %{"type" => "store", "key" => key, "value" => value}} when is_binary(key) ->
          case ResourceRegistry.store_code_state(
                 state.registry,
                 state.handle,
                 state.context.owner_id,
                 key,
                 value
               ) do
            :ok -> {:noreply, state}
            {:error, error} -> fail(state, error)
          end

        {:ok, %{"type" => "notify", "value" => value}} ->
          item = %{"type" => "notification", "text" => value}
          bytes = state.output_bytes + byte_size(JSON.encode!(item))

          if bytes <= state.output_limit do
            state = %{state | output_bytes: bytes}
            event = %{type: :custom_tool_call_output, output: value}
            callback = state.context[:emit]

            if state.from && is_function(callback, 1) do
              case callback.(event) do
                :ok -> {:noreply, state}
                {:error, error} -> fail(state, error)
              end
            else
              {:noreply, %{state | outputs: state.outputs ++ [item]}}
            end
          else
            fail(
              state,
              Error.new(:budget_exceeded, "Code Mode notification output exceeds its bound")
            )
          end

        {:ok, %{"type" => "control_yield"}} ->
          cond do
            is_nil(state.from) -> {:noreply, state}
            state.active_tool != nil -> {:noreply, %{state | pending_yield: :running}}
            true -> running_yield(state)
          end

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
          :yielded when state.active_tool != nil ->
            {:noreply, %{state | pending_yield: {:generator, result}}}

          :yielded ->
            pause(state, result)

          :completed ->
            finish(state, result)
        end
      else
        fail(state, Error.new(:budget_exceeded, "code mode result exceeds the configured bound"))
      end
    end

    defp complete_tool(%{pending_yield: :running} = state),
      do: running_yield(%{state | pending_yield: nil})

    defp complete_tool(%{pending_yield: {:generator, result}} = state),
      do: pause(%{state | pending_yield: nil}, result)

    defp complete_tool(state), do: {:noreply, state}

    defp tool_call(message, %{from: nil, active_tool: nil, pending_tool: nil} = state),
      do: {:noreply, %{state | pending_tool: message}}

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

        worker = self()

        execution_context =
          state.context
          |> Map.put(:suspend, fn -> GenServer.call(worker, :suspend_timer, :infinity) end)
          |> Map.put(:resume, fn -> GenServer.call(worker, :resume_timer, :infinity) end)

        task =
          Task.Supervisor.async_nolink(state.task_supervisor, fn ->
            state.dispatcher.(request, execution_context)
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

    defp finish(%{active_tool: tool} = state, _result) when not is_nil(tool),
      do:
        finish(
          %{state | active_tool: nil},
          {:error, Error.new(:unknown_outcome, "Code Mode ended with an unsettled nested tool")}
        )

    defp finish(%{from: nil, terminal_result: result} = state, _result) when not is_nil(result),
      do: {:noreply, state}

    defp finish(%{from: nil} = state, result) do
      status = cleanup_os(state)

      result =
        if status == :ok,
          do: result,
          else:
            {:error, Error.new(:unknown_outcome, "Code Mode cleanup unconfirmed", cause: status)}

      if state.timer, do: Process.cancel_timer(state.timer)

      {:noreply,
       %{
         state
         | terminal_result: result,
           os_cleanup_status: status,
           timer: nil,
           timer_generation: nil
       }}
    end

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

      GenServer.reply(state.from, with_output(state, result))
      {:stop, :normal, %{state | from: nil, awaiting_resume: false, os_cleanup_status: status}}
    end

    defp pause(%{from: nil} = state, _result),
      do: fail(state, Error.new(:resource_conflict, "unexpected code mode yield"))

    defp pause(state, result) do
      if state.timer, do: Process.cancel_timer(state.timer)
      GenServer.reply(state.from, with_output(state, result))

      {:noreply,
       %{
         state
         | from: nil,
           timer: nil,
           timer_deadline: nil,
           paused_remaining: nil,
           timer_generation: nil,
           slice_generation: nil,
           awaiting_resume: true,
           outputs: []
       }}
    end

    defp fail(state, error), do: finish(state, {:error, error})

    defp running_yield(state) do
      GenServer.reply(state.from, with_output(state, {:ok, %{status: :yielded}}))
      {:noreply, %{state | from: nil, outputs: [], slice_timer: nil, slice_generation: nil}}
    end

    defp with_output(state, {:ok, result}) do
      outputs = Map.get(state, :outputs, [])
      # Return whole media records; the host hard output bound remains independent.
      limit = Map.get(state, :max_tokens, 10_000) * 4

      {kept, _} =
        Enum.reduce(outputs, {[], 0}, fn item, {items, bytes} ->
          size = byte_size(JSON.encode!(item))
          if bytes + size <= limit, do: {items ++ [item], bytes + size}, else: {items, bytes}
        end)

      {:ok, Map.merge(result, %{output: kept, output_truncated: length(kept) != length(outputs)})}
    end

    defp with_output(_state, error), do: error

    defp arm(state, from) do
      state =
        if state.timer do
          state
        else
          generation = make_ref()
          timer = Process.send_after(self(), {:deadline, generation}, state.timeout)

          %{
            state
            | timer: timer,
              timer_generation: generation,
              timer_deadline: System.monotonic_time(:millisecond) + state.timeout,
              paused_remaining: nil
          }
        end

      if state.slice_timer, do: Process.cancel_timer(state.slice_timer)
      generation = make_ref()

      timer =
        if is_integer(state.yield_time_ms),
          do: Process.send_after(self(), {:slice, generation}, state.yield_time_ms),
          else: nil

      %{
        state
        | from: from,
          awaiting_resume: false,
          slice_timer: timer,
          slice_generation: generation
      }
    end

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
        {:error, reason} when reason in [:enoent, :esrch] -> :gone
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
        "--v8-flags=--max-old-space-size=64",
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

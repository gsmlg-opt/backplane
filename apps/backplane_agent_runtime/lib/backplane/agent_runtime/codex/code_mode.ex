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
    if is_binary(Map.get(context, :deno_path, System.find_executable("deno"))) do
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
             incarnation: operation.incarnation
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
        with {:ok, result} <- resume(registry, handle, nil, owner: owner),
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
         :ok <- validate_code(code, opts),
         {:ok, context} <- execution_context(owner, opts),
         {:ok, dispatcher} <- dispatcher(opts),
         {:ok, worker} <-
           __MODULE__.Worker.start_link(worker_opts(code, context, dispatcher, opts)),
         result <- __MODULE__.Worker.begin(worker),
         {:ok, result} <- register_or_stop(registry, owner, worker, result, opts) do
      {:ok, result}
    end
  end

  @spec resume(pid(), map(), term(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def resume(registry, handle, value, opts \\ []) when is_pid(registry) and is_map(handle) do
    owner = Keyword.get(opts, :owner)

    with {:ok, owner} <- validate_resume_owner(owner),
         {:ok, worker} <- ResourceRegistry.fetch(registry, handle, owner),
         {:ok, result} <- __MODULE__.Worker.resume(worker, value),
         {:ok, result} <- settle_resume(registry, handle, owner, result, opts) do
      {:ok, result}
    end
  end

  @spec cancel(pid(), map(), String.t()) :: {:ok, term()} | {:error, Error.t()}
  def cancel(registry, handle, owner) when is_pid(registry) and is_map(handle) do
    ResourceRegistry.release(registry, handle, owner)
  end

  defp register_or_stop(registry, owner, worker, {:ok, %{status: :yielded} = result}, opts) do
    case ResourceRegistry.register(registry, owner, :continuation, worker,
           incarnation: Keyword.get(opts, :incarnation, 1),
           owner_pid: self(),
           cleanup: fn -> safe_stop(worker) end
         ) do
      {:ok, handle} ->
        {:ok, Map.put(result, :handle, handle)}

      {:error, %Error{} = error} ->
        safe_stop(worker)
        {:error, error}
    end
  end

  defp register_or_stop(_registry, _owner, _worker, {:error, %Error{} = error}, _opts) do
    {:error, error}
  end

  defp register_or_stop(_registry, _owner, _worker, {:ok, result}, _opts) do
    {:ok, result}
  end

  defp register_or_stop(_registry, _owner, worker, result, _opts) do
    safe_stop(worker)

    {:error,
     Error.new(:malformed_result, "code mode worker returned an invalid result", cause: result)}
  end

  defp safe_stop(worker) do
    Process.unlink(worker)

    try do
      __MODULE__.Worker.stop(worker)
    catch
      :exit, _ -> :ok
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
      deno_path: Keyword.get(opts, :deno_path)
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
        deno_path: Map.get(context, :deno_path)
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

    @max_line 1_048_576

    alias Backplane.AgentRuntime.Error

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def begin(pid), do: GenServer.call(pid, :begin, :infinity)
    def resume(pid, value), do: GenServer.call(pid, {:resume, value}, :infinity)
    def stop(pid), do: GenServer.stop(pid, :shutdown)

    @impl true
    def init(opts) do
      Process.flag(:trap_exit, true)

      with {:ok, deno} <- deno_path(Keyword.get(opts, :deno_path)),
           {:ok, task_supervisor} <- Task.Supervisor.start_link(),
           {:ok, port} <- open_port(deno, opts) do
        {:ok,
         %{
           port: port,
           task_supervisor: task_supervisor,
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
    def handle_call(:begin, from, state) do
      send_command(state.port, %{type: "execute", code: state.code})
      {:noreply, arm(state, from)}
    end

    def handle_call({:resume, _value}, _from, %{from: nil, awaiting_resume: false} = state),
      do:
        {:reply,
         {:error, Error.new(:resource_conflict, "code mode is not awaiting a continuation")},
         state}

    def handle_call({:resume, value}, from, state) do
      if bounded_term?(value, state.output_limit) do
        send_command(state.port, %{type: "resume", value: value})
        {:noreply, arm(%{state | from: from, awaiting_resume: false}, from)}
      else
        {:reply,
         {:error, Error.new(:budget_exceeded, "continuation value exceeds the configured bound")},
         state}
      end
    end

    @impl true
    def handle_info({port, {:data, chunk}}, %{port: port} = state) when is_binary(chunk) do
      consume_data(state, state.buffer <> chunk)
    end

    def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state),
      do: handle_line(line, state)

    def handle_info({port, {:data, {:noeol, chunk}}}, %{port: port} = state),
      do: consume_data(state, state.buffer <> chunk)

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
      if is_port(state.port) do
        try do
          Port.close(state.port)
        catch
          :error, :badarg -> :ok
        end
      end

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
         when is_map(next_context), do: {:ok, value, next_context}

    defp normalize_dispatch_result({:error, %Error{} = error}, _context), do: {:error, error}

    defp normalize_dispatch_result(other, _context),
      do:
        {:error,
         Error.new(:malformed_result, "nested dispatcher returned an invalid result",
           cause: other
         )}

    defp finish(%{from: nil} = state, _result),
      do: fail(state, Error.new(:resource_conflict, "unexpected code mode completion"))

    defp finish(state, result) do
      if state.timer, do: Process.cancel_timer(state.timer)
      GenServer.reply(state.from, result)
      {:stop, :normal, %{state | from: nil, awaiting_resume: false}}
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

    defp send_command(port, command), do: Port.command(port, JSON.encode!(command) <> "\n")

    defp open_port(deno, _opts) do
      args = [
        "eval",
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
        wrapper()
      ]

      port =
        Port.open({:spawn_executable, deno}, [
          :binary,
          :exit_status,
          {:line, @max_line},
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

    defp consume_data(state, data) when byte_size(data) > @max_line,
      do:
        fail(
          state,
          Error.new(:budget_exceeded, "code mode protocol line exceeds the configured bound")
        )

    defp consume_data(state, data) do
      case String.split(data, "\n", parts: 2) do
        [line] ->
          {:noreply, %{state | buffer: line}}

        [line, rest] ->
          next = handle_line(String.trim_trailing(line, "\r"), %{state | buffer: ""})

          case next do
            {:noreply, next_state} -> consume_data(next_state, rest)
            other -> other
          end
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

    defp wrapper do
      ~S"""
      const D = Deno;
      const enc = new TextEncoder();
      const out = value => D.stdout.writeSync(enc.encode(JSON.stringify(value) + "\n"));
      const pending = new Map();
      let iterator = null, nextId = 0, waiting = false;
      const fail = message => { throw new Error(message); };
      const call = (name, value, rawInput) => {
        if (typeof name !== "string" || name.length === 0) return Promise.reject(new Error("tool name is required"));
        if (pending.size > 0) return Promise.reject(new Error("concurrent nested calls are rejected"));
        const id = String(++nextId);
        out({type:"tool_call", id, name, arguments: rawInput === undefined ? value : undefined, rawInput});
        return new Promise((resolve, reject) => pending.set(id, {resolve, reject}));
      };
      const codex = Object.freeze({tool: (name, args) => call(name, args), custom: (name, raw) => call(name, undefined, raw)});
      globalThis.console = Object.freeze({log:()=>{}, info:()=>{}, warn:()=>{}, error:()=>{}, debug:()=>{}});
      globalThis.fetch = () => Promise.reject(new Error("network access is disabled"));
      try { Object.defineProperty(globalThis, "Deno", {value: undefined, configurable: false}); } catch (_) {}
      const advance = async value => {
        try {
          const result = await iterator.next(value);
          if (result.done) out({type:"complete", value: result.value});
          else out({type:"yield", value: result.value});
        } catch (error) { out({type:"error", error:{class:"execution_failure", message:String(error && error.message || error)}}); }
      };
      const lines = D.stdin.readable.pipeThrough(new TextDecoderStream()).pipeThrough(new TransformStream({
        transform(chunk, controller) { for (const line of chunk.split("\n")) if (line.trim()) controller.enqueue(line); }
      }));
      for await (const line of lines) {
        let command;
        try { command = JSON.parse(line); } catch (_) { out({type:"error", error:{class:"malformed_result", message:"invalid command"}}); continue; }
        if (command.type === "execute") {
          try { const F = Object.getPrototypeOf(async function*(){}).constructor; iterator = new F("codex", command.code)(codex); advance(undefined); }
          catch (error) { out({type:"error", error:{class:"execution_failure", message:String(error && error.message || error)}}); }
        } else if (command.type === "resume" && iterator) advance(command.value);
        else if (command.type === "tool_result") {
          const item = pending.get(command.id); if (!item) continue; pending.delete(command.id);
          command.ok ? item.resolve(command.value) : item.reject(new Error(command.error && command.error.message || "nested tool failed"));
        }
      }
      """
    end
  end
end

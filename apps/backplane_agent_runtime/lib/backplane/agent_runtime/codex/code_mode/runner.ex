defmodule Backplane.AgentRuntime.Codex.CodeMode.Runner do
  @moduledoc false
  use GenServer

  @protocol_version 1
  @frame_limit 1_048_576
  @result_limit 2_148_532_223
  @pending_limit 1_024
  @timer_limit 2_147_483_647
  @error_flush_timeout 250

  def protocol_version, do: @protocol_version

  # The parent transport owns this VM. Exit without waiting for an active NIF,
  # evaluation, callback, or output flush after the control process goes away.
  def main do
    case GenServer.start(__MODULE__, []) do
      {:ok, runner} ->
        ref = Process.monitor(runner)

        receive do
          {:DOWN, ^ref, :process, ^runner, :normal} -> :erlang.halt(0, flush: false)
          {:DOWN, ^ref, :process, ^runner, _reason} -> :erlang.halt(1, flush: false)
        end

      {:error, reason} ->
        IO.puts(:stderr, "Code Mode runner boot failed: #{inspect(reason)}")
        :erlang.halt(1, flush: false)
    end
  end

  @impl true
  def init([]) do
    Process.flag(:trap_exit, true)
    # The fd driver can defer EOF until its output queue drains. Keep stdin
    # independent so closing the control channel always stops the runner.
    stdin = Port.open({:fd, 0, 1}, [:binary, :eof, :in])
    stdout = Port.open({:fd, 0, 1}, [:binary, :out])
    controller = self()
    entrypoint_token = :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)

    handlers = %{
      "host.event" => fn [sequence, json] -> bridge(controller, {:event, sequence, json}) end,
      "host.control" => fn [json] -> bridge(controller, {:control, json}) end,
      "host.start_timer" => fn [id, delay] -> bridge(controller, {:start_timer, id, delay}) end,
      "host.timer" => fn [id] -> bridge(controller, {:timer, id}) end,
      "host.clear_timer" => fn [id] -> bridge(controller, {:clear_timer, id}) end
    }

    with {:ok, runtime} <-
           QuickBEAM.start(sandbox: :strict, handlers: handlers, memory_limit: 64 * 1024 * 1024),
         {:ok, source} <-
           File.read(
             Application.app_dir(:backplane_agent_runtime, "priv/codex/code_mode_quickbeam.js")
           ) do
      state = %{
        stdin: stdin,
        stdout: stdout,
        runtime: runtime,
        runtime_ref: Process.monitor(runtime),
        entrypoint_token: entrypoint_token,
        evaluation: nil,
        phase: :booting,
        next_resume: nil,
        input: [],
        input_bytes: 0,
        allowance: nil,
        next_event: 1,
        events: %{},
        event_bytes: 0,
        tools: %{},
        revision: 0,
        control: nil,
        configuration: nil,
        timers: %{}
      }

      script = source <> "(" <> JSON.encode!(entrypoint_token) <> ");"
      {:ok, evaluate(state, :boot, fn -> QuickBEAM.eval(runtime, script) end)}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp bridge(controller, request) do
    case GenServer.call(controller, request, :infinity) do
      {:error, message} -> raise message
      result -> result
    end
  catch
    :exit, _reason -> raise "Code Mode runner control channel closed"
  end

  @impl true
  def handle_call({:event, sequence, json}, from, state)
      when is_integer(sequence) and is_binary(json) do
    bytes = byte_size(json)

    cond do
      bytes > @frame_limit or state.event_bytes + bytes > @frame_limit ->
        stop_protocol(state, "budget_exceeded", "Code Mode event buffer exceeds its bound")

      sequence < state.next_event or sequence >= state.next_event + @pending_limit or
          Map.has_key?(state.events, sequence) ->
        stop_protocol(state, "malformed_result", "invalid Code Mode event sequence")

      true ->
        next = %{
          state
          | events: Map.put(state.events, sequence, {json, from}),
            event_bytes: state.event_bytes + bytes
        }

        case drain_events(next) do
          {:ok, next} -> {:noreply, next}
          {:error, class, message} -> stop_protocol(next, class, message)
        end
    end
  end

  def handle_call({:control, json}, from, %{control: nil} = state)
      when is_binary(json) and byte_size(json) <= 128 do
    case JSON.decode(json) do
      {:ok, %{"revision" => revision}} when revision == state.revision ->
        {:noreply, send_configuration(%{state | control: from})}

      {:ok, %{"revision" => revision}}
      when revision == state.revision + 1 and not is_nil(state.configuration) ->
        %{"revision" => ^revision} = state.configuration
        write(state, %{"type" => "configured", "revision" => revision})
        {:noreply, %{state | control: from, configuration: nil, revision: revision}}

      _ ->
        stop_protocol(
          state,
          "malformed_result",
          "invalid Code Mode configuration acknowledgement"
        )
    end
  end

  def handle_call({:start_timer, id, delay}, _from, state)
      when is_integer(id) and id > 0 and is_integer(delay) and delay >= 0 and
             delay <= @timer_limit do
    if map_size(state.timers) < @pending_limit and not Map.has_key?(state.timers, id) do
      generation = make_ref()
      timer = Process.send_after(self(), {:timer, id, generation}, delay)
      {:reply, true, put_timer(state, id, {generation, timer, nil})}
    else
      {:reply, {:error, "Code Mode timer limit exceeded"}, state}
    end
  end

  def handle_call({:timer, id}, from, state) do
    case Map.get(state.timers, id) do
      {:settled, fired?} ->
        {:reply, fired?, delete_timer(state, id)}

      {generation, timer, nil} ->
        {:noreply, put_timer(state, id, {generation, timer, from})}

      _ ->
        {:reply, {:error, "invalid Code Mode timer waiter"}, state}
    end
  end

  def handle_call({:clear_timer, id}, _from, state) when is_integer(id) and id > 0 do
    case Map.get(state.timers, id) do
      {_generation, timer, from} ->
        Process.cancel_timer(timer)
        {:reply, true, settle_timer(state, id, from, false)}

      {:settled, _fired?} ->
        {:reply, true, put_timer(state, id, {:settled, false})}

      nil ->
        {:reply, true, state}
    end
  end

  def handle_call(_request, _from, state),
    do: {:reply, {:error, "invalid Code Mode bridge request"}, state}

  @impl true
  def handle_info({stdin, {:data, bytes}}, %{stdin: stdin} = state) do
    case read_frames(bytes, state) do
      {:ok, state} -> {:noreply, state}
      {:error, class, message} -> stop_protocol(state, class, message)
    end
  end

  def handle_info({stdin, :eof}, %{stdin: stdin, input_bytes: 0} = state),
    do: {:stop, :normal, state}

  def handle_info({stdin, :eof}, %{stdin: stdin} = state),
    do: stop_protocol(state, "malformed_result", "incomplete Code Mode command at EOF")

  def handle_info({:EXIT, port, _reason}, %{stdin: stdin, stdout: stdout} = state)
      when port == stdin or port == stdout,
      do: {:stop, :normal, state}

  def handle_info({:evaluation, pid, result}, %{evaluation: {pid, ref, kind}} = state) do
    Process.demonitor(ref, [:flush])
    settle_evaluation(%{state | evaluation: nil}, kind, result)
  end

  def handle_info({:DOWN, ref, :process, _, reason}, %{runtime_ref: ref} = state),
    do: {:stop, {:engine_exit, reason}, state}

  def handle_info({:DOWN, ref, :process, _, reason}, %{evaluation: {_, ref, _}} = state),
    do: {:stop, {:evaluation_exit, reason}, state}

  def handle_info({:timer, id, generation}, state) do
    case Map.get(state.timers, id) do
      {^generation, _timer, from} ->
        {:noreply, settle_timer(state, id, from, true)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp settle_timer(state, id, nil, fired?), do: put_timer(state, id, {:settled, fired?})

  defp settle_timer(state, id, from, fired?) do
    GenServer.reply(from, fired?)
    delete_timer(state, id)
  end

  defp put_timer(state, id, timer), do: %{state | timers: Map.put(state.timers, id, timer)}
  defp delete_timer(state, id), do: %{state | timers: Map.delete(state.timers, id)}

  defp read_frames(bytes, state) do
    limit = if state.allowance, do: elem(state.allowance, 1), else: @frame_limit

    case :binary.match(bytes, "\n") do
      :nomatch when byte_size(bytes) + state.input_bytes <= limit ->
        {:ok,
         %{
           state
           | input: [bytes | state.input],
             input_bytes: state.input_bytes + byte_size(bytes)
         }}

      {length, 1} when length + state.input_bytes <= limit ->
        <<last::binary-size(^length), _newline, rest::binary>> = bytes
        frame = [last | state.input] |> Enum.reverse() |> IO.iodata_to_binary()

        with {:ok, state} <- read_frame(frame, %{state | input: [], input_bytes: 0}) do
          if rest == "", do: {:ok, state}, else: read_frames(rest, state)
        end

      _ ->
        {:error, "budget_exceeded", "Code Mode command record exceeds byte limit"}
    end
  end

  defp read_frame(frame, state) do
    cond do
      not String.valid?(frame) ->
        {:error, "malformed_result", "invalid UTF-8 in Code Mode command"}

      String.trim(frame) == "" ->
        {:ok, state}

      true ->
        case JSON.decode(frame) do
          {:ok, command} -> command(state, command, frame)
          {:error, _} -> {:error, "malformed_result", "invalid Code Mode command"}
        end
    end
  end

  defp command(
         %{allowance: {id, _}} = state,
         %{"type" => "tool_result", "id" => id} = command,
         json
       ),
       do: command(%{state | allowance: nil}, command, json)

  defp command(%{allowance: {_id, _}} = _state, _command, _json),
    do: {:error, "malformed_result", "Code Mode result allowance identity mismatch"}

  defp command(
         %{phase: :ready, evaluation: nil} = state,
         %{"type" => "execute", "code" => code},
         json
       )
       when is_binary(code) do
    next = evaluate_js(%{state | phase: :running}, {:execute, code}, "__backplaneExecute", json)
    {:ok, next}
  end

  defp command(%{phase: :yielded, evaluation: nil} = state, %{"type" => "resume"} = command, _) do
    {:ok, resume(state, Map.get(command, "value"))}
  end

  defp command(%{phase: :yielded, next_resume: nil} = state, %{"type" => "resume"} = command, _) do
    {:ok, %{state | next_resume: {:resume, Map.get(command, "value")}}}
  end

  defp command(
         %{configuration: nil} = state,
         %{"type" => "configure", "revision" => revision} = config,
         _
       )
       when revision == state.revision + 1 do
    configuration = Map.take(config, ["revision", "tools", "stored"])
    {:ok, send_configuration(%{state | configuration: configuration})}
  end

  defp command(state, %{"type" => "tool_result_allowance", "id" => id, "bytes" => bytes}, _)
       when is_integer(bytes) and bytes > 0 and bytes <= @result_limit do
    if Map.has_key?(state.tools, id) do
      {:ok, %{state | allowance: {id, bytes}}}
    else
      {:error, "malformed_result", "invalid Code Mode result allowance"}
    end
  end

  defp command(state, %{"type" => "tool_result", "id" => id, "ok" => ok}, json)
       when is_binary(id) and is_boolean(ok) do
    case Map.pop(state.tools, id) do
      {nil, _} ->
        {:ok, state}

      {from, tools} ->
        GenServer.reply(from, json)
        {:ok, %{state | tools: tools}}
    end
  end

  defp command(_state, _command, _json),
    do: {:error, "malformed_result", "invalid Code Mode command type"}

  defp send_configuration(%{configuration: config, control: from} = state)
       when not is_nil(config) and not is_nil(from) do
    GenServer.reply(from, JSON.encode!(config))
    %{state | control: nil}
  end

  defp send_configuration(state), do: state

  defp drain_events(state) do
    case Map.pop(state.events, state.next_event) do
      {nil, _} ->
        {:ok, state}

      {{json, from}, rest} ->
        next = %{
          state
          | events: rest,
            event_bytes: state.event_bytes - byte_size(json),
            next_event: state.next_event + 1
        }

        with {:ok, next} <- forward_event(next, JSON.decode(json), json, from) do
          drain_events(next)
        end
    end
  end

  defp forward_event(state, {:ok, %{"type" => "tool_call", "id" => id}}, json, from)
       when is_binary(id) and map_size(state.tools) < @pending_limit do
    if Map.has_key?(state.tools, id) do
      {:error, "malformed_result", "duplicate Code Mode tool request"}
    else
      write_line(state, json)
      {:ok, %{state | tools: Map.put(state.tools, id, from)}}
    end
  end

  defp forward_event(state, {:ok, %{"type" => type}}, json, from)
       when type in ~w(output notify store control_yield yield complete error) do
    write_line(state, json)
    GenServer.reply(from, "ok")

    case type do
      "yield" -> {:ok, %{state | phase: :yielded}}
      terminal when terminal in ["complete", "error"] -> {:ok, %{state | phase: :finished}}
      _ -> {:ok, state}
    end
  end

  defp forward_event(_state, _event, _json, _from),
    do: {:error, "malformed_result", "invalid Code Mode event"}

  defp evaluate(state, kind, callback) do
    parent = self()
    {pid, ref} = spawn_monitor(fn -> send(parent, {:evaluation, self(), callback.()}) end)
    %{state | evaluation: {pid, ref, kind}}
  end

  defp evaluate_js(state, kind, function, json) do
    # Parse the JSON on the JS side to keep argument representation identical to
    # the wire. Encode it as a JS string literal to preserve "__proto__" keys.
    token = JSON.encode!(state.entrypoint_token)
    script = function <> "(" <> token <> "," <> JSON.encode!(json) <> ")"
    evaluate(state, kind, fn -> QuickBEAM.eval(state.runtime, script) end)
  end

  defp resume(state, value) do
    evaluate_js(
      %{state | phase: :running, next_resume: nil},
      :resume,
      "__backplaneResume",
      JSON.encode!(value)
    )
  end

  defp settle_evaluation(state, :boot, {:ok, _}) do
    write(state, %{
      "type" => "ready",
      "protocol" => @protocol_version,
      "engine" => to_string(Application.spec(:duskmoon_quickbeam, :vsn))
    })

    {:noreply, %{state | phase: :ready}}
  end

  # credo:disable-for-next-line Credo.Check.Design.TagTODO
  # TODO(upstream): duskmoon-dev/duskmoon-bundler#47
  # Adopt host-owned Promise timing for module evaluation and generator resumes.
  defp settle_evaluation(state, {:execute, code}, {:ok, "module"}) do
    {:noreply,
     evaluate(state, :module, fn -> QuickBEAM.load_module(state.runtime, "code-mode", code) end)}
  end

  defp settle_evaluation(state, :module, result) do
    error = if result == :ok, do: nil, else: evaluation_error(result)
    {:noreply, evaluate_js(state, :module_finish, "__backplaneFinishModule", JSON.encode!(error))}
  end

  defp settle_evaluation(%{next_resume: {:resume, value}} = state, _kind, {:ok, _}),
    do: {:noreply, resume(state, value)}

  defp settle_evaluation(state, _kind, {:ok, _}), do: {:noreply, state}

  defp settle_evaluation(state, _kind, error),
    do: stop_protocol(state, "execution_failure", evaluation_error(error))

  defp evaluation_error({:error, %{message: message}}) when is_binary(message), do: message
  defp evaluation_error({:error, message}) when is_binary(message), do: message
  defp evaluation_error(_), do: "QuickBEAM evaluation failed"

  defp write(state, event), do: write_line(state, JSON.encode!(event))

  defp write_line(%{stdin: stdin, stdout: stdout}, json, timeout \\ :infinity) do
    line = [json, "\n"]

    unless port_command(stdout, line, [:nosuspend]) do
      # Keep a single write outstanding in stream order. The write may suspend
      # until stdout drains, while this process can still observe stdin EOF.
      {writer, monitor} = spawn_monitor(fn -> port_command(stdout, line, []) end)

      receive do
        {:DOWN, ^monitor, :process, ^writer, :normal} ->
          :ok

        {:DOWN, ^monitor, :process, ^writer, reason} ->
          exit(reason)

        {^stdin, :eof} ->
          exit(:normal)

        {:EXIT, port, _reason} when port == stdin or port == stdout ->
          exit(:normal)
      after
        timeout -> :erlang.halt(1, flush: false)
      end
    end
  end

  defp port_command(port, line, opts) do
    Port.command(port, line, opts)
  rescue
    ArgumentError -> exit(:stdout_closed)
  end

  defp stop_protocol(state, class, message) do
    deadline = System.monotonic_time(:millisecond) + @error_flush_timeout
    error = %{"type" => "error", "error" => %{"class" => class, "message" => message}}
    write_line(state, JSON.encode!(error), @error_flush_timeout)
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    # Keep the port owned until the VM flushes the failure frame. The bound
    # also covers an unresponsive reader or a native runtime still in flight.
    :erlang.halt(1, flush: true, flush_timeout: remaining)
  end
end

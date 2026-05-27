defmodule BackplaneTelemetry.TelemetryLogger do
  @moduledoc """
  A unified telemetry logging service that collects, sanitizes, and logs events for:
  - LLM API requests
  - MCP requests & tool calls
  - Memory database access & host agent memory calls
  - Skills context operations
  - Host agent WebSocket connection status changes

  It runs as a GenServer to perform file writing and JSON encoding asynchronously
  in its own process, avoiding blocking the request path.
  """

  use GenServer
  require Logger

  @handler_id "backplane-telemetry-logger-handler"

  @events [
    [:backplane, :llm, :request],
    [:backplane, :mcp_request, :start],
    [:backplane, :tool_call, :stop],
    [:backplane, :tool_call, :exception],
    [:backplane, :memory, :access, :stop],
    [:backplane, :memory, :access, :exception],
    [:backplane, :host_agent, :memory, :call, :stop],
    [:backplane, :host_agent, :memory, :call, :exception],
    [:backplane, :skills, :access, :stop],
    [:backplane, :skills, :access, :exception],
    [:backplane, :host_agent, :connect],
    [:backplane, :host_agent, :disconnect]
  ]

  # ── Client API ──────────────────────────────────────────────────────────────

  @doc "Start the telemetry logger GenServer."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # ── Telemetry Callback ──────────────────────────────────────────────────────

  @doc """
  Synchronous callback invoked by :telemetry when an event fires.
  Dispatches a cast to the TelemetryLogger GenServer to process asynchronously.
  """
  def handle_event(event_name, measurements, metadata, _config) do
    # Capture timestamp in caller process for accuracy
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

    event = %{
      "timestamp" => timestamp,
      "event" => Enum.join(event_name, "."),
      "measurements" => measurements,
      "metadata" => metadata
    }

    # Asynchronously dispatch to GenServer
    if Process.whereis(__MODULE__) do
      GenServer.cast(__MODULE__, {:log_event, event})
    end
  end

  # ── GenServer Callbacks ──────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    config = Application.get_env(:backplane_telemetry, __MODULE__, [])
    log_to_logger = Keyword.get(config, :log_to_logger, true)
    log_to_console = Keyword.get(config, :log_to_console, false)
    log_to_file = Keyword.get(config, :log_to_file, nil)

    # Ensure log file directory exists if log_to_file is configured
    file_device =
      if log_to_file do
        File.mkdir_p!(Path.dirname(log_to_file))

        case File.open(log_to_file, [:write, :append, :utf8]) do
          {:ok, io_device} ->
            io_device

          {:error, reason} ->
            Logger.error(
              "TelemetryLogger: Failed to open log file #{log_to_file}: #{inspect(reason)}"
            )

            nil
        end
      else
        nil
      end

    # Attach telemetry handler
    attach_telemetry()

    state = %{
      log_to_logger: log_to_logger,
      log_to_console: log_to_console,
      log_to_file: log_to_file,
      file_device: file_device
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:log_event, event}, state) do
    sanitized_event = sanitize(event)

    # 1. Save to JSONL file if enabled
    state =
      if state.file_device do
        case Jason.encode(sanitized_event) do
          {:ok, json_line} ->
            IO.write(state.file_device, json_line <> "\n")
            # Flush immediately to avoid losing buffer on crashes
            :file.datasync(state.file_device)
            state

          {:error, reason} ->
            Logger.warning("TelemetryLogger: Failed to JSON encode event: #{inspect(reason)}")
            state
        end
      else
        state
      end

    # 2. Print JSON to console if enabled
    if state.log_to_console do
      case Jason.encode(sanitized_event) do
        {:ok, json_line} -> IO.puts(json_line)
        _ -> :ok
      end
    end

    # 3. Log human-readable format via Logger if enabled
    if state.log_to_logger do
      msg = format_message(sanitized_event["event"], sanitized_event["measurements"], sanitized_event["metadata"])

      if String.contains?(sanitized_event["event"], "exception") do
        Logger.error(msg)
      else
        Logger.info(msg)
      end
    end

    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    detach_telemetry()

    if state.file_device do
      File.close(state.file_device)
    end

    :ok
  end

  # ── Internal Helpers ────────────────────────────────────────────────────────

  defp attach_telemetry do
    detach_telemetry()
    :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, nil)
  end

  defp detach_telemetry do
    case :telemetry.detach(@handler_id) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end

  # Format human readable logger outputs
  defp format_message(event, measurements, metadata) do
    case event do
      "backplane.llm.request" ->
        "LLM proxy request: model=#{metadata["model"]} provider=#{metadata["provider_id"]} latency=#{measurements["latency_ms"]}ms status=#{metadata["status"]} tokens=#{metadata["input_tokens"]}/#{metadata["output_tokens"]}"

      "backplane.mcp_request.start" ->
        "MCP request started: method=#{metadata["method"]}"

      "backplane.tool_call.stop" ->
        "Tool call: tool=#{metadata["tool"]} duration=#{duration_ms(measurements)}ms result=#{metadata["result"]}"

      "backplane.tool_call.exception" ->
        "Tool call exception: tool=#{metadata["tool"]} duration=#{duration_ms(measurements)}ms reason=#{inspect(metadata["reason"])}"

      "backplane.memory.access.stop" ->
        "Memory access: action=#{metadata["action"]} duration=#{duration_ms(measurements)}ms status=#{metadata["status"]}"

      "backplane.memory.access.exception" ->
        "Memory access exception: action=#{metadata["action"]} duration=#{duration_ms(measurements)}ms reason=#{inspect(metadata["reason"])}"

      "backplane.host_agent.memory.call.stop" ->
        "Host agent memory call: method=#{metadata["method"]} agent=#{metadata["agent_id"]} duration=#{duration_ms(measurements)}ms result=#{metadata["result"]}"

      "backplane.host_agent.memory.call.exception" ->
        "Host agent memory call exception: method=#{metadata["method"]} agent=#{metadata["agent_id"]} duration=#{duration_ms(measurements)}ms reason=#{inspect(metadata["reason"])}"

      "backplane.skills.access.stop" ->
        "Skills access: action=#{metadata["action"]} duration=#{duration_ms(measurements)}ms status=#{metadata["status"]}"

      "backplane.skills.access.exception" ->
        "Skills access exception: action=#{metadata["action"]} duration=#{duration_ms(measurements)}ms reason=#{inspect(metadata["reason"])}"

      "backplane.host_agent.connect" ->
        "Host agent connected: name=#{metadata["host_name"]} id=#{metadata["host_id"]} token=#{metadata["auth_token_id"]}"

      "backplane.host_agent.disconnect" ->
        "Host agent disconnected: name=#{metadata["host_name"]} id=#{metadata["host_id"]} reason=#{inspect(metadata["reason"])}"

      other ->
        "Telemetry event #{other}: measurements=#{inspect(measurements)} metadata=#{inspect(metadata)}"
    end
  end

  defp duration_ms(%{"duration" => dur}) when is_integer(dur),
    do: System.convert_time_unit(dur, :native, :millisecond)

  defp duration_ms(_), do: 0

  # Recursively sanitize payload for JSON compatibility
  def sanitize(val) when is_struct(val) do
    if is_exception(val) do
      Exception.message(val)
    else
      val
      |> Map.from_struct()
      |> sanitize()
    end
  end

  def sanitize(val) when is_map(val) do
    Map.new(val, fn {k, v} -> {to_string(k), sanitize(v)} end)
  end

  def sanitize(val) when is_list(val) do
    Enum.map(val, &sanitize/1)
  end

  def sanitize(val) when is_tuple(val) do
    val
    |> Tuple.to_list()
    |> sanitize()
  end

  def sanitize(val) when is_pid(val) or is_reference(val) do
    inspect(val)
  end

  def sanitize(val) when is_atom(val) do
    Atom.to_string(val)
  end

  def sanitize(val), do: val
end

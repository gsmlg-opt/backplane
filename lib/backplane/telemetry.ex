defmodule Backplane.Telemetry do
  @moduledoc """
  Telemetry event definitions and helpers for Backplane.

  Events:
    - [:backplane, :tool_call, :start]
    - [:backplane, :tool_call, :stop]
    - [:backplane, :tool_call, :exception]
    - [:backplane, :mcp_request, :start]
    - [:backplane, :mcp_request, :stop]
    - [:backplane, :sse_stream, :start]
    - [:backplane, :sse_stream, :stop]
  """

  require Logger

  @doc "Execute a tool call with telemetry instrumentation."
  def span_tool_call(tool_name, fun) do
    request_id = Logger.metadata()[:request_id]
    metadata = %{tool: tool_name, request_id: request_id}
    start_time = System.monotonic_time()

    :telemetry.execute(
      [:backplane, :tool_call, :start],
      %{system_time: System.system_time()},
      metadata
    )

    try do
      result = fun.()
      duration = System.monotonic_time() - start_time

      result_status =
        case result do
          {:ok, _} -> :ok
          {:error, _} -> :error
          _ -> :ok
        end

      :telemetry.execute(
        [:backplane, :tool_call, :stop],
        %{duration: duration},
        Map.put(metadata, :result, result_status)
      )

      duration_ms = System.convert_time_unit(duration, :native, :millisecond)

      Logger.info("Tool call completed",
        tool: tool_name,
        result: result_status,
        duration_ms: duration_ms,
        request_id: request_id
      )

      result
    rescue
      e ->
        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          [:backplane, :tool_call, :exception],
          %{duration: duration},
          Map.merge(metadata, %{kind: :error, reason: e})
        )

        duration_ms = System.convert_time_unit(duration, :native, :millisecond)

        Logger.error("Tool call exception",
          tool: tool_name,
          error: Exception.message(e),
          duration_ms: duration_ms,
          request_id: request_id
        )

        reraise e, __STACKTRACE__
    end
  end

  @doc "Emit an MCP request telemetry event."
  def emit_mcp_request(method, metadata \\ %{}) do
    :telemetry.execute(
      [:backplane, :mcp_request, :start],
      %{system_time: System.system_time()},
      Map.put(metadata, :method, method)
    )

    Logger.info("MCP request", method: method, request_id: Logger.metadata()[:request_id])
  end

  @doc "Emit an SSE stream start event."
  def emit_sse_start(tool_name) do
    :telemetry.execute(
      [:backplane, :sse_stream, :start],
      %{system_time: System.system_time()},
      %{tool: tool_name}
    )
  end

  @doc "Emit an SSE stream stop event."
  def emit_sse_stop(tool_name, duration) do
    :telemetry.execute(
      [:backplane, :sse_stream, :stop],
      %{duration: duration},
      %{tool: tool_name}
    )
  end
end

defmodule Backplane.Telemetry do
  @moduledoc """
  Telemetry event definitions and helpers for Backplane.

  Events:
    - [:backplane, :tool_call, :start]
    - [:backplane, :tool_call, :stop]
    - [:backplane, :tool_call, :exception]
    - [:backplane, :mcp_request, :start]
    - [:backplane, :sse_stream, :start]
    - [:backplane, :sse_stream, :stop]
  """

  require Logger

  @doc "Execute a tool call with telemetry instrumentation."
  @spec span_tool_call(String.t(), (-> term())) :: term()
  @spec span_tool_call(String.t(), map(), (-> term())) :: term()
  def span_tool_call(tool_name, fun), do: span_tool_call(tool_name, %{}, fun)

  def span_tool_call(tool_name, args, fun) when is_map(args) and is_function(fun, 0) do
    request_id = Logger.metadata()[:request_id]
    metadata = %{tool: tool_name, request_id: request_id}
    start_time = System.monotonic_time()
    v2_enabled = Application.get_env(:backplane_telemetry, :observability_v2_enabled, false)
    arguments_hash = Backplane.Audit.hash_arguments(args)

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

      maybe_log_legacy_tool_audit(tool_name, args, request_id, duration, result_status, arguments_hash)

      unless v2_enabled do
        duration_ms = System.convert_time_unit(duration, :native, :millisecond)

        Logger.info("Tool call completed",
          tool: tool_name,
          result: result_status,
          duration_ms: duration_ms,
          request_id: request_id
        )
      end

      result
    rescue
      e ->
        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          [:backplane, :tool_call, :exception],
          %{duration: duration},
          Map.merge(metadata, %{kind: :error, reason: e})
        )

        maybe_log_legacy_tool_audit(
          tool_name,
          args,
          request_id,
          duration,
          :error,
          arguments_hash,
          Exception.message(e)
        )

        unless v2_enabled do
          duration_ms = System.convert_time_unit(duration, :native, :millisecond)

          Logger.error("Tool call exception",
            tool: tool_name,
            error: Exception.message(e),
            duration_ms: duration_ms,
            request_id: request_id
          )
        end

        reraise e, __STACKTRACE__
    end
  end

  defp maybe_log_legacy_tool_audit(tool_name, _args, request_id, duration, result_status, arguments_hash, error_message \\ nil) do
    status =
      case result_status do
        :ok -> "ok"
        :error -> "error"
        _ -> "ok"
      end

    duration_us = System.convert_time_unit(duration, :native, :microsecond)

    Backplane.Audit.log_tool_call(%{
      tool_name: tool_name,
      request_id: request_id,
      duration_us: duration_us,
      status: status,
      error_message: error_message,
      arguments_hash: arguments_hash
    })
  end

  @doc "Emit an MCP request telemetry event."
  @spec emit_mcp_request(String.t(), map()) :: :ok
  def emit_mcp_request(method, metadata \\ %{}) do
    :telemetry.execute(
      [:backplane, :mcp_request, :start],
      %{system_time: System.system_time()},
      Map.put(metadata, :method, method)
    )

    unless Application.get_env(:backplane_telemetry, :observability_v2_enabled, false) do
      Logger.info("MCP request", method: method, request_id: Logger.metadata()[:request_id])
    end

    :ok
  end

  @doc "Emit an SSE stream start event."
  @spec emit_sse_start(String.t()) :: :ok
  def emit_sse_start(tool_name) do
    :telemetry.execute(
      [:backplane, :sse_stream, :start],
      %{system_time: System.system_time()},
      %{tool: tool_name}
    )
  end

  @doc "Emit an SSE stream stop event."
  @spec emit_sse_stop(String.t(), integer()) :: :ok
  def emit_sse_stop(tool_name, duration) do
    :telemetry.execute(
      [:backplane, :sse_stream, :stop],
      %{duration: duration},
      %{tool: tool_name}
    )
  end
end

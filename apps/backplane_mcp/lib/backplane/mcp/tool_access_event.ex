defmodule Backplane.MCP.ToolAccessEvent do
  @moduledoc false

  require Logger

  alias Backplane.Audit
  alias Backplane.Observability
  alias Backplane.Observability.{Context, Error, Event, Id}

  @type execution_meta :: %{
          optional(:execution_kind) => String.t() | nil,
          optional(:original_tool_name) => String.t() | nil,
          optional(:cache_status) => String.t() | nil,
          optional(:timeout_ms) => pos_integer() | nil,
          optional(:upstream_name) => String.t() | nil,
          optional(:upstream_prefix) => String.t() | nil,
          optional(:upstream_transport) => String.t() | nil,
          optional(:upstream_protocol_version) => String.t() | nil,
          optional(:attempt_count) => pos_integer() | nil
        }

  @doc """
  Executes a tool call with Observability v2 instrumentation.

  The callback receives the tool child context and must return
  `{:ok, result, meta}`, `{:error, reason, meta}`, or raise.
  """
  @spec span(String.t(), map(), map(), (Context.t() -> term())) :: term()
  def span(tool_name, args, %{context: %Context{}} = observability, fun)
      when is_binary(tool_name) and is_function(fun, 1) do
    parent_context = observability.context
    tool_context = Context.child(parent_context)
    event_id = Id.generator().event_id()
    started_mono = System.monotonic_time(:millisecond)
    {namespace, _} = split_tool(tool_name)
    arguments_hash = Audit.hash_arguments(args)

    emit_legacy_start(tool_name, parent_context)

    try do
      case fun.(tool_context) do
        {:ok, result, %{} = meta} ->
          finalize(
            tool_name,
            namespace,
            arguments_hash,
            observability,
            tool_context,
            event_id,
            started_mono,
            meta,
            :success,
            result,
            nil
          )

          {:ok, result}

        {:error, reason, %{} = meta} ->
          finalize(
            tool_name,
            namespace,
            arguments_hash,
            observability,
            tool_context,
            event_id,
            started_mono,
            meta,
            :error,
            reason,
            reason
          )

          {:error, reason}

        other ->
          other
      end
    rescue
      exception ->
        meta = %{execution_kind: "unknown"}

        finalize(
          tool_name,
          namespace,
          arguments_hash,
          observability,
          tool_context,
          event_id,
          started_mono,
          meta,
          :error,
          exception,
          exception
        )

        reraise exception, __STACKTRACE__
    end
  end

  defp finalize(
         tool_name,
         namespace,
         arguments_hash,
         observability,
         tool_context,
         event_id,
         started_mono,
         meta,
         outcome,
         result,
         error_reason
       ) do
    duration_ms = System.monotonic_time(:millisecond) - started_mono
    record = build_record(tool_name, namespace, arguments_hash, observability, tool_context, event_id, duration_ms, meta, outcome, result, error_reason)
    measurements = %{duration_ms: duration_ms, system_time: System.system_time()}
    error = build_error(record, error_reason)

    Event.emit_stop(:mcp_proxy, "tool_call", tool_context,
      event_id: event_id,
      measurements: measurements,
      attributes: compact_record(record),
      error: error
    )

    maybe_log_tool_audit(record, observability, outcome, error_reason)
    emit_legacy_stop(tool_name, parent_context(observability), outcome, duration_ms, result)
    :ok
  end

  defp maybe_log_tool_audit(record, observability, outcome, _error_reason) do
    status =
      case outcome do
        :success -> "ok"
        :error -> "error"
      end

    attrs =
      %{
        event_id: record.event_id,
        request_id: observability.context.request_id,
        trace_id: record.trace_id,
        mcp_request_id: record.mcp_request_id,
        tool_name: record.tool_name,
        duration_us: record.duration_ms * 1_000,
        status: status,
        error_message: record.error_message,
        arguments_hash: record.arguments_hash
      }
      |> maybe_put_client(observability[:client])

    Audit.log_tool_call(attrs)
  end

  defp maybe_put_client(attrs, %{id: id, name: name}) do
    attrs
    |> Map.put(:client_id, id)
    |> Map.put(:client_name, name)
  end

  defp maybe_put_client(attrs, _client), do: attrs

  defp build_record(
         tool_name,
         namespace,
         arguments_hash,
         observability,
         tool_context,
         event_id,
         duration_ms,
         meta,
         outcome,
         result,
         error_reason
       ) do
    outcome_string = outcome_string(outcome, result, error_reason)

    %{
      event_id: event_id,
      mcp_request_id: observability.mcp_request_id,
      trace_id: tool_context.trace_id,
      span_id: tool_context.span_id,
      parent_span_id: tool_context.parent_span_id,
      tool_name: tool_name,
      tool_namespace: meta[:tool_namespace] || namespace,
      original_tool_name: meta[:original_tool_name],
      execution_kind: meta[:execution_kind],
      upstream_name: meta[:upstream_name],
      upstream_prefix: meta[:upstream_prefix],
      upstream_transport: meta[:upstream_transport],
      upstream_protocol_version: meta[:upstream_protocol_version],
      arguments_hash: arguments_hash,
      cache_status: meta[:cache_status],
      timeout_ms: meta[:timeout_ms],
      attempt_count: meta[:attempt_count] || 1,
      duration_ms: duration_ms,
      outcome: outcome_string,
      error_kind: error_kind(outcome_string, error_reason),
      error_code: error_code(outcome_string, error_reason),
      error_message: error_message(outcome_string, error_reason),
      metadata: %{}
    }
  end

  defp build_error(%{outcome: "success"}, _reason), do: nil

  defp build_error(record, reason) do
    Error.normalize(reason,
      kind: record.error_kind,
      code: record.error_code,
      source: "mcp_tool"
    )
  end

  defp compact_record(record) do
    record
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp split_tool(tool_name) do
    case String.split(tool_name, "::", parts: 2) do
      [namespace, _rest] -> {namespace, tool_name}
      _other -> {tool_name, tool_name}
    end
  end

  defp outcome_string(:success, _result, _reason), do: "success"
  defp outcome_string(:error, _result, _reason), do: "error"

  defp error_kind("success", _reason), do: nil
  defp error_kind("error", reason) when is_binary(reason), do: classify_error_kind(reason)
  defp error_kind("error", reason), do: classify_error_kind(inspect(reason))

  defp classify_error_kind(reason) do
    cond do
      String.contains?(reason, "timeout") -> "timeout"
      String.contains?(reason, "connection") -> "upstream"
      String.contains?(reason, "Unknown tool") -> "not_found"
      true -> "internal"
    end
  end

  defp error_code("success", _reason), do: nil
  defp error_code("error", reason) when is_binary(reason), do: "tool_error"
  defp error_code("error", _reason), do: "tool_error"

  defp error_message("success", _reason), do: nil

  defp error_message("error", reason) when is_binary(reason), do: reason

  defp error_message("error", exception) when is_exception(exception),
    do: Exception.message(exception)

  defp error_message("error", reason), do: inspect(reason)

  defp parent_context(%{context: context}), do: context

  defp emit_legacy_start(tool_name, parent_context) do
    if Observability.enabled?() do
      :ok
    else
      :telemetry.execute(
        [:backplane, :tool_call, :start],
        %{system_time: System.system_time()},
        %{tool: tool_name, request_id: parent_context.request_id}
      )
    end
  end

  defp emit_legacy_stop(tool_name, parent_context, outcome, duration_ms, _result) do
    if Observability.enabled?() do
      :ok
    else
      result_status =
        case outcome do
          :success -> :ok
          :error -> :error
        end

      duration_native = duration_ms * 1_000_000

      :telemetry.execute(
        [:backplane, :tool_call, :stop],
        %{duration: duration_native},
        %{tool: tool_name, request_id: parent_context.request_id, result: result_status}
      )

      level = if outcome == :error, do: :error, else: :info

      Logger.log(level, fn ->
        "Tool call completed tool=#{tool_name} result=#{result_status} duration_ms=#{duration_ms}"
      end,
        tool: tool_name,
        result: result_status,
        duration_ms: duration_ms,
        request_id: parent_context.request_id
      )
    end

    :ok
  end
end

defmodule Backplane.HostAgent.Telemetry do
  @moduledoc """
  Telemetry helpers for host-agent runtime actions.
  """

  @memory_call_prefix [:backplane, :host_agent, :memory, :call]
  @capture_prefix [:backplane, :host_agent, :memory, :capture]

  @doc "Wrap a memory call with telemetry instrumentation."
  @spec span_memory_call(String.t(), String.t(), map(), (-> term())) :: term()
  def span_memory_call(method, agent_id, args, fun)
      when is_binary(method) and is_map(args) and is_function(fun, 0) do
    metadata = %{
      agent_id: agent_id,
      argument_keys: argument_keys(args),
      method: method
    }

    :telemetry.span(@memory_call_prefix, metadata, fn ->
      result = fun.()
      {result, Map.merge(metadata, result_metadata(result))}
    end)
  end

  def capture_event(privacy) when is_map(privacy) do
    redacted =
      if (privacy["redaction_count"] || privacy[:redaction_count] || 0) > 0, do: 1, else: 0

    :telemetry.execute(@capture_prefix ++ [:captured], %{count: 1, redacted_count: redacted}, %{})
  end

  def capture_rejection(permanent?) when is_boolean(permanent?) do
    :telemetry.execute(@capture_prefix ++ [:rejected], %{count: 1}, %{permanent: permanent?})
  end

  def capture_connection(connected?) when is_boolean(connected?) do
    state = if connected?, do: :connected, else: :disconnected

    :telemetry.execute(
      @capture_prefix ++ [:connection],
      %{connected: if(connected?, do: 1, else: 0)},
      %{state: state}
    )
  end

  def capture_spool(stats) when is_map(stats) do
    measurements = %{
      spool_depth: stats[:pending_depth] || 0,
      spool_bytes: stats[:pending_bytes] || 0,
      oldest_event_age_ms: oldest_age_ms(stats[:oldest_occurred_at]),
      age_warning: if(stats[:age_warning], do: 1, else: 0),
      captured_count: stats[:captured_count] || 0,
      redacted_count: stats[:redacted_count] || 0,
      rejected_count: stats[:rejected_count] || 0,
      retry_count: stats[:retry_count] || 0,
      dead_letter_count: stats[:dead_letter_count] || 0
    }

    :telemetry.execute(@capture_prefix ++ [:spool], measurements, %{})
  end

  def capture_upload(result, duration) when is_integer(duration) do
    :telemetry.execute(
      @capture_prefix ++ [:upload],
      %{duration: duration, count: selected_count(result)},
      %{result: result_status(result)}
    )
  end

  def capture_ack(result, duration) when is_integer(duration) do
    :telemetry.execute(@capture_prefix ++ [:ack], %{duration: duration}, %{
      result: if(match?({:ok, _}, result), do: :ok, else: :error)
    })
  end

  def duration_ms(duration), do: System.convert_time_unit(duration, :native, :millisecond)

  def oldest_age_ms(nil), do: 0

  def oldest_age_ms(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, datetime, _offset} ->
        max(DateTime.diff(DateTime.utc_now(), datetime, :millisecond), 0)

      _ ->
        0
    end
  end

  def oldest_age_ms(_timestamp), do: 0

  defp selected_count({:ok, %{"selected" => count}}) when is_integer(count), do: count
  defp selected_count(_result), do: 0

  defp result_status({:ok, %{"status" => status}}), do: status
  defp result_status({:error, _reason}), do: :error
  defp result_status(_result), do: :unknown

  defp argument_keys(args) do
    args
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.sort()
  end

  defp result_metadata({:ok, _result}), do: %{result: :ok}
  defp result_metadata({:error, reason}), do: %{result: :error, error: inspect(reason)}
  defp result_metadata(_result), do: %{result: :ok}
end

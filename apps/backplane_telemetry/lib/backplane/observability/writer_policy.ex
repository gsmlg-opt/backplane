defmodule Backplane.Observability.WriterPolicy do
  @moduledoc false

  alias Backplane.Observability.Settings

  @writer_keys [
    "observability.writer.batch_size",
    "observability.writer.flush_interval_ms",
    "observability.writer.queue_capacity"
  ]

  @doc "Subscribes the caller to validated observability writer policy changes."
  @spec subscribe() :: :ok
  def subscribe do
    Settings.subscribe()
  end

  @doc "Initial writer GenServer state derived from settings and startup opts."
  @spec init_state(atom(), keyword()) :: map()
  def init_state(domain, opts) do
    %{
      domain: domain,
      batch_size: Keyword.get(opts, :batch_size, Settings.writer_batch_size(domain)),
      flush_interval_ms: Keyword.get(opts, :flush_interval_ms, Settings.writer_flush_interval_ms()),
      flush_timer: nil,
      inserted_total: 0,
      dropped_total: 0,
      failed_total: 0,
      duplicate_total: 0,
      last_error: nil,
      last_flush_at: nil
    }
  end

  @doc "Applies a settings change message to writer state when relevant."
  @spec apply_settings_change(map(), term()) :: map()
  def apply_settings_change(state, {:observability_setting_changed, key, value})
      when key in @writer_keys do
    case key do
      "observability.writer.batch_size" ->
        %{state | batch_size: value || Settings.writer_batch_size(state.domain)}

      "observability.writer.flush_interval_ms" ->
        state
        |> Map.put(:flush_interval_ms, value)
        |> schedule_flush()

      "observability.writer.queue_capacity" ->
        if buffer = buffer_name(state.domain) do
          _ = Backplane.Observability.Buffer.update_capacity(buffer, Settings.queue_capacity(buffer))
        end

        state

      _ ->
        state
    end
  end

  def apply_settings_change(state, {:setting_changed, key, _value}) when key in @writer_keys do
    apply_settings_change(state, {:observability_setting_changed, key, refreshed_value(key, state.domain)})
  end

  def apply_settings_change(state, _message), do: state

  @doc "Emits accepted telemetry for a queued writer row."
  @spec emit_accepted(atom(), map()) :: :ok
  def emit_accepted(domain, row) do
    :telemetry.execute(
      [:backplane, :observability, :events, :accepted],
      %{count: 1},
      %{domain: domain, event_id: row[:event_id]}
    )
  end

  @doc "Emits writer persistence telemetry."
  @spec emit_persisted(atom(), non_neg_integer(), non_neg_integer(), keyword()) :: :ok
  def emit_persisted(domain, inserted, duplicate, opts \\ []) do
    lag_ms = Keyword.get(opts, :persistence_lag_ms, 0)

    if inserted > 0 do
      :telemetry.execute(
        [:backplane, :observability, :events, :persisted],
        %{count: inserted, persistence_lag_ms: lag_ms},
        %{domain: domain}
      )
    end

    if duplicate > 0 do
      :telemetry.execute(
        [:backplane, :observability, :events, :duplicate],
        %{count: duplicate},
        %{domain: domain}
      )
    end

    :ok
  end

  @doc "Emits writer drop telemetry."
  @spec emit_dropped(atom(), term()) :: :ok
  def emit_dropped(domain, reason) do
    :telemetry.execute(
      [:backplane, :observability, :events, :dropped],
      %{count: 1},
      %{domain: domain, reason: reason}
    )
  end

  @doc "Emits writer failure telemetry."
  @spec emit_failure(atom(), non_neg_integer(), term()) :: :ok
  def emit_failure(domain, count, reason) do
    :telemetry.execute(
      [:backplane, :observability, :writer, :failure],
      %{count: count},
      %{domain: domain, reason: inspect(reason)}
    )
  end

  @doc "Builds a health snapshot map for a writer GenServer state."
  @spec health_snapshot(map(), atom()) :: map()
  def health_snapshot(state, buffer_name) do
    %{
      status: :ok,
      batch_size: state.batch_size,
      flush_interval_ms: state.flush_interval_ms,
      buffer: Backplane.Observability.Buffer.health(buffer_name),
      inserted_total: state.inserted_total,
      dropped_total: state.dropped_total,
      failed_total: state.failed_total,
      duplicate_total: state.duplicate_total,
      last_error: state.last_error,
      last_flush_at: state.last_flush_at
    }
  end

  @doc "Schedules the next flush timer and stores its reference in state."
  @spec schedule_flush(map()) :: map()
  def schedule_flush(%{flush_timer: ref} = state) when is_reference(ref) do
    Process.cancel_timer(ref)
    do_schedule_flush(state)
  end

  def schedule_flush(state), do: do_schedule_flush(state)

  defp do_schedule_flush(%{flush_interval_ms: interval_ms} = state) when interval_ms > 0 do
    ref = Process.send_after(self(), :flush, interval_ms)
    %{state | flush_timer: ref}
  end

  defp do_schedule_flush(state), do: %{state | flush_timer: nil}

  defp refreshed_value("observability.writer.batch_size", domain),
    do: Settings.writer_batch_size(domain)

  defp refreshed_value("observability.writer.flush_interval_ms", _domain),
    do: Settings.writer_flush_interval_ms()

  defp refreshed_value("observability.writer.queue_capacity", _domain),
    do: Settings.writer_queue_capacity()

  defp buffer_name(:llm_proxy), do: :llm_proxy
  defp buffer_name(:mcp_proxy_root), do: :mcp_proxy_root
  defp buffer_name(:mcp_tool_calls), do: :mcp_tool_calls
  defp buffer_name(_), do: nil
end

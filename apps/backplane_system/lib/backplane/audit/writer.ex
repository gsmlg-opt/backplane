defmodule Backplane.Audit.Writer do
  @moduledoc """
  Supervised, bounded, batched writer for audit tables.

  Persists tool-call and skill-load audit rows without blocking request
  processes. Duplicate `event_id` values are ignored for idempotency.
  """

  use GenServer

  require Logger

  alias Backplane.Audit.{Buffer, SkillLoadLog, ToolCallLog}
  alias Backplane.Repo

  @buffer_name :audit
  @domain :audit

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Enqueues an audit event for batched persistence."
  @spec enqueue(map()) :: :ok | {:error, :full | :unavailable}
  def enqueue(%{type: type} = event) when type in [:tool_call, :skill_load] do
    row = Map.put(event, :_enqueued_at_mono, System.monotonic_time(:millisecond))

    case Buffer.try_enqueue(@buffer_name, row) do
      :ok ->
        emit_accepted(row)
        :ok

      {:error, reason} = error ->
        GenServer.cast(__MODULE__, {:dropped, reason})
        error
    end
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @doc "Returns bounded health information for admin and diagnostics."
  @spec health() :: map()
  def health do
    GenServer.call(__MODULE__, :health)
  catch
    :exit, _ ->
      %{
        status: :unavailable,
        buffer: Buffer.health(@buffer_name),
        inserted_total: 0,
        dropped_total: 0,
        failed_total: 0,
        duplicate_total: 0,
        last_error: nil
      }
  end

  @doc "Forces a buffer drain (primarily for tests)."
  @spec flush() :: :ok
  def flush do
    GenServer.call(__MODULE__, :flush)
  catch
    :exit, _ -> :ok
  end

  @doc "Drains queued audit events during controlled shutdown."
  @spec drain() :: :ok
  def drain do
    GenServer.call(__MODULE__, :drain, 5_000)
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init(opts) do
    if Keyword.get(opts, :subscribe_settings, true) do
      subscribe_settings()
    end

    state =
      init_state(opts)
      |> schedule_flush()

    {:ok, state}
  end

  @impl true
  def terminate(_reason, state) do
    _ = persist_batch(state)
    :ok
  end

  @impl true
  def handle_info(:flush, state) do
    state =
      state
      |> persist_batch()
      |> Map.put(:last_flush_at, DateTime.utc_now())
      |> schedule_flush()

    {:noreply, state}
  end

  def handle_info(message, state) do
    {:noreply, apply_settings_change(state, message)}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    state = persist_batch(state)
    {:reply, :ok, %{state | last_flush_at: DateTime.utc_now()}}
  end

  @impl true
  def handle_call(:drain, _from, state) do
    state = drain_all(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:health, _from, state) do
    {:reply, health_snapshot(state), state}
  end

  @impl true
  def handle_cast({:dropped, reason}, state) do
    emit_dropped(reason)

    {:noreply,
     %{
       state
       | dropped_total: state.dropped_total + 1,
         last_error: inspect(reason)
     }}
  end

  defp init_state(opts) do
    %{
      batch_size: Keyword.get(opts, :batch_size, writer_batch_size()),
      flush_interval_ms: Keyword.get(opts, :flush_interval_ms, writer_flush_interval_ms()),
      flush_timer: nil,
      inserted_total: 0,
      dropped_total: 0,
      failed_total: 0,
      duplicate_total: 0,
      last_error: nil,
      last_flush_at: nil
    }
  end

  defp drain_all(state) do
    if buffer_pending?() do
      state |> persist_batch() |> drain_all()
    else
      state
    end
  end

  defp buffer_pending? do
    case Buffer.health(@buffer_name) do
      %{reserved: reserved, queued: queued} when reserved > 0 or queued > 0 -> true
      _ -> false
    end
  end

  defp persist_batch(state) do
    events = Buffer.drain(@buffer_name, state.batch_size)

    if events == [] do
      state
    else
      now_mono = System.monotonic_time(:millisecond)

      case insert_rows(events) do
        {:ok, inserted, duplicate} ->
          Buffer.release(@buffer_name, length(events))

          lag_ms =
            events
            |> Enum.map(&Map.get(&1, :_enqueued_at_mono, now_mono))
            |> Enum.max()
            |> then(&max(now_mono - &1, 0))

          emit_persisted(inserted, duplicate, lag_ms)

          %{
            state
            | inserted_total: state.inserted_total + inserted,
              duplicate_total: state.duplicate_total + duplicate
          }

        {:error, reason} ->
          Buffer.release(@buffer_name, length(events))
          emit_failure(length(events), reason)

          Logger.warning("Audit Writer batch insert failed: #{inspect(reason)}")

          %{
            state
            | failed_total: state.failed_total + length(events),
              last_error: inspect(reason)
          }
      end
    end
  end

  defp insert_rows(rows) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {tool_rows, skill_rows} =
      Enum.split_with(rows, fn row -> row[:type] == :tool_call end)

    with {:ok, tool_inserted, tool_duplicate} <- insert_tool_rows(tool_rows, now),
         {:ok, skill_inserted, skill_duplicate} <- insert_skill_rows(skill_rows, now) do
      {:ok, tool_inserted + skill_inserted, tool_duplicate + skill_duplicate}
    end
  rescue
    exception ->
      {:error, exception}
  end

  defp insert_tool_rows(rows, now) do
    entries =
      Enum.map(rows, fn row ->
        row
        |> Map.drop([:type, :_enqueued_at_mono])
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()
        |> Map.put_new(:inserted_at, now)
      end)

    attempted = length(entries)

    if attempted == 0 do
      {:ok, 0, 0}
    else
      {count, _} =
        Repo.insert_all(ToolCallLog, entries,
          on_conflict: :nothing,
          conflict_target: [:event_id]
        )

      {:ok, count, attempted - count}
    end
  end

  defp insert_skill_rows(rows, now) do
    entries =
      Enum.map(rows, fn row ->
        row
        |> Map.drop([:type, :_enqueued_at_mono])
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()
        |> Map.put_new(:inserted_at, now)
      end)

    attempted = length(entries)

    if attempted == 0 do
      {:ok, 0, 0}
    else
      {count, _} =
        Repo.insert_all(SkillLoadLog, entries,
          on_conflict: :nothing,
          conflict_target: [:event_id]
        )

      {:ok, count, attempted - count}
    end
  end

  defp health_snapshot(state) do
    %{
      status: :ok,
      batch_size: state.batch_size,
      flush_interval_ms: state.flush_interval_ms,
      buffer: Buffer.health(@buffer_name),
      inserted_total: state.inserted_total,
      dropped_total: state.dropped_total,
      failed_total: state.failed_total,
      duplicate_total: state.duplicate_total,
      last_error: state.last_error,
      last_flush_at: state.last_flush_at
    }
  end

  defp schedule_flush(%{flush_timer: ref} = state) when is_reference(ref) do
    Process.cancel_timer(ref)
    do_schedule_flush(state)
  end

  defp schedule_flush(state), do: do_schedule_flush(state)

  defp do_schedule_flush(%{flush_interval_ms: interval_ms} = state) when interval_ms > 0 do
    ref = Process.send_after(self(), :flush, interval_ms)
    %{state | flush_timer: ref}
  end

  defp do_schedule_flush(state), do: %{state | flush_timer: nil}

  defp subscribe_settings do
    if settings_available?() and pubsub_available?() do
      apply(Backplane.Observability.Settings, :subscribe, [])
    end
  end

  defp pubsub_available? do
    Process.whereis(Backplane.PubSub) != nil
  end

  defp apply_settings_change(state, {:observability_setting_changed, key, value}) do
    case key do
      "observability.writer.batch_size" ->
        %{state | batch_size: value || writer_batch_size()}

      "observability.writer.flush_interval_ms" ->
        state
        |> Map.put(:flush_interval_ms, value || writer_flush_interval_ms())
        |> schedule_flush()

      "observability.writer.queue_capacity" ->
        _ = Buffer.update_capacity(@buffer_name, queue_capacity())
        state

      _ ->
        state
    end
  end

  defp apply_settings_change(state, {:setting_changed, key, _value})
       when key in [
              "observability.writer.batch_size",
              "observability.writer.flush_interval_ms",
              "observability.writer.queue_capacity"
            ] do
    apply_settings_change(state, {:observability_setting_changed, key, refreshed_value(key)})
  end

  defp apply_settings_change(state, _message), do: state

  defp refreshed_value("observability.writer.batch_size"), do: writer_batch_size()
  defp refreshed_value("observability.writer.flush_interval_ms"), do: writer_flush_interval_ms()
  defp refreshed_value("observability.writer.queue_capacity"), do: queue_capacity()

  defp writer_batch_size do
    if settings_available?() do
      apply(Backplane.Observability.Settings, :writer_batch_size, [:audit])
    else
      200
    end
  end

  defp writer_flush_interval_ms do
    if settings_available?() do
      apply(Backplane.Observability.Settings, :writer_flush_interval_ms, [])
    else
      250
    end
  end

  defp queue_capacity do
    if settings_available?() do
      apply(Backplane.Observability.Settings, :queue_capacity, [:audit])
    else
      Buffer.default_capacity()
    end
  end

  defp settings_available? do
    Code.ensure_loaded?(Backplane.Observability.Settings) and
      Process.whereis(Backplane.Observability.Settings) != nil
  end

  defp emit_accepted(row) do
    :telemetry.execute(
      [:backplane, :observability, :events, :accepted],
      %{count: 1},
      %{domain: @domain, event_id: row[:event_id]}
    )
  end

  defp emit_persisted(inserted, duplicate, lag_ms) do
    if inserted > 0 do
      :telemetry.execute(
        [:backplane, :observability, :events, :persisted],
        %{count: inserted, persistence_lag_ms: lag_ms},
        %{domain: @domain}
      )
    end

    if duplicate > 0 do
      :telemetry.execute(
        [:backplane, :observability, :events, :duplicate],
        %{count: duplicate},
        %{domain: @domain}
      )
    end

    :ok
  end

  defp emit_dropped(reason) do
    :telemetry.execute(
      [:backplane, :observability, :events, :dropped],
      %{count: 1},
      %{domain: @domain, reason: reason}
    )
  end

  defp emit_failure(count, reason) do
    :telemetry.execute(
      [:backplane, :observability, :writer, :failure],
      %{count: count},
      %{domain: @domain, reason: inspect(reason)}
    )
  end
end

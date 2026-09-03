defmodule Backplane.MCP.ToolLogWriter do
  @moduledoc """
  Bounded, batched writer for MCP tool-call child access records.

  Listens for terminal Observability v2 MCP tool events and persists sanitized
  rows into `mcp_tool_calls` without blocking request processes.
  """

  use GenServer

  require Logger

  alias Backplane.MCP.ToolCall
  alias Backplane.Observability.{Buffer, WriterPolicy}
  alias Backplane.Repo

  @telemetry_event [:backplane, :mcp_proxy, :tool_call, :stop]
  @domain :mcp_tool_calls
  @buffer_name :mcp_tool_calls

  @handler_id "backplane-mcp-tool-log-writer"

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
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

  @doc false
  @spec attach() :: :ok
  def attach do
    :telemetry.attach(
      @handler_id,
      @telemetry_event,
      &__MODULE__.handle_event/4,
      nil
    )
  end

  @doc false
  @spec detach() :: :ok
  def detach do
    :telemetry.detach(@handler_id)
  end

  @doc false
  def handle_event(_event, _measurements, metadata, _config) do
    row =
      metadata
      |> row_from_metadata()
      |> Map.put(:_enqueued_at_mono, System.monotonic_time(:millisecond))

    case Buffer.try_enqueue(@buffer_name, row) do
      :ok ->
        WriterPolicy.emit_accepted(@domain, row)
        :ok

      {:error, reason} ->
        GenServer.cast(__MODULE__, {:dropped, reason})
        :ok
    end
  end

  @impl true
  def init(opts) do
    _ = attach()
    WriterPolicy.subscribe()

    state =
      WriterPolicy.init_state(@domain, opts)
      |> WriterPolicy.schedule_flush()

    {:ok, state}
  end

  @impl true
  def handle_info(:flush, state) do
    state =
      state
      |> persist_batch()
      |> Map.put(:last_flush_at, DateTime.utc_now())
      |> WriterPolicy.schedule_flush()

    {:noreply, state}
  end

  def handle_info(message, state) do
    {:noreply, WriterPolicy.apply_settings_change(state, message)}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    state = persist_batch(state)
    {:reply, :ok, %{state | last_flush_at: DateTime.utc_now()}}
  end

  @impl true
  def handle_call(:health, _from, state) do
    {:reply, WriterPolicy.health_snapshot(state, @buffer_name), state}
  end

  @impl true
  def handle_cast({:dropped, reason}, state) do
    WriterPolicy.emit_dropped(@domain, reason)

    {:noreply,
     %{
       state
       | dropped_total: state.dropped_total + 1,
         last_error: inspect(reason)
     }}
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

          WriterPolicy.emit_persisted(@domain, inserted, duplicate, persistence_lag_ms: lag_ms)

          %{
            state
            | inserted_total: state.inserted_total + inserted,
              duplicate_total: state.duplicate_total + duplicate
          }

        {:error, reason} ->
          Buffer.release(@buffer_name, length(events))
          WriterPolicy.emit_failure(@domain, length(events), reason)

          Logger.warning("MCP ToolLogWriter batch insert failed: #{inspect(reason)}")

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

    entries =
      Enum.map(rows, fn row ->
        row
        |> atomize_keys()
        |> Map.drop([:_enqueued_at_mono])
        |> cast_field_types()
        |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "nil" end)
        |> Map.new()
        |> Map.put_new(:inserted_at, now)
      end)

    attempted = length(entries)

    {count, _} =
      Repo.insert_all(ToolCall, entries,
        on_conflict: :nothing,
        conflict_target: [:event_id]
      )

    {:ok, count, attempted - count}
  rescue
    exception ->
      {:error, exception}
  end

  @row_fields ~w(
    event_id mcp_request_id trace_id span_id parent_span_id
    tool_name tool_namespace original_tool_name execution_kind
    upstream_name upstream_prefix upstream_transport upstream_protocol_version
    arguments_hash cache_status timeout_ms attempt_count duration_ms
    outcome error_kind error_code error_message metadata
  )a

  defp row_from_metadata(metadata) do
    attrs = metadata |> Map.get(:attributes, %{}) |> atomize_keys()

    attrs
    |> Map.take(@row_fields)
    |> Map.put(:event_id, metadata[:event_id] || attrs[:event_id])
    |> Map.put(:trace_id, get_in(metadata, [:context, :trace_id]) || attrs[:trace_id])
    |> Map.put(:span_id, get_in(metadata, [:context, :span_id]) || attrs[:span_id])
    |> Map.put(:parent_span_id, get_in(metadata, [:context, :parent_span_id]) || attrs[:parent_span_id])
    |> ensure_required_fields()
  end

  defp ensure_required_fields(row) do
    row
    |> Map.put_new(:outcome, "success")
    |> Map.put_new(:metadata, %{})
  end

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {key, value}
      {key, value} when is_binary(key) -> {String.to_existing_atom(key), value}
    end)
  rescue
    ArgumentError ->
      Map.new(map, fn {key, value} -> {String.to_atom(key), value} end)
  end

  defp cast_field_types(row) do
    row
    |> cast_integer(:timeout_ms)
    |> cast_integer(:attempt_count)
    |> cast_integer(:duration_ms)
  end

  defp cast_integer(row, key) do
    case Map.get(row, key) do
      value when is_integer(value) ->
        row

      value when is_binary(value) ->
        case Integer.parse(value) do
          {int, _} -> Map.put(row, key, int)
          _ -> Map.delete(row, key)
        end

      _ ->
        row
    end
  end
end

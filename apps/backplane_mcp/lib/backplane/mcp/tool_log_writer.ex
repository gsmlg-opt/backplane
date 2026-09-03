defmodule Backplane.MCP.ToolLogWriter do
  @moduledoc """
  Bounded, batched writer for MCP tool-call child access records.

  Listens for terminal Observability v2 MCP tool events and persists sanitized
  rows into `mcp_tool_calls` without blocking request processes.
  """

  use GenServer

  require Logger

  alias Backplane.MCP.ToolCall
  alias Backplane.Observability.Buffer
  alias Backplane.Repo

  @telemetry_event [:backplane, :mcp_proxy, :tool_call, :stop]
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
    row = row_from_metadata(metadata)

    case Buffer.try_enqueue(@buffer_name, row) do
      :ok ->
        :ok

      {:error, reason} ->
        GenServer.cast(__MODULE__, {:dropped, reason})
        :ok
    end
  end

  @impl true
  def init(opts) do
    _ = attach()

    state = %{
      batch_size: Keyword.get(opts, :batch_size, config(:batch_size, 500)),
      flush_interval_ms: Keyword.get(opts, :flush_interval_ms, config(:flush_interval_ms, 250)),
      inserted_total: 0,
      dropped_total: 0,
      failed_total: 0,
      last_error: nil
    }

    schedule_flush(state.flush_interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:flush, state) do
    state = persist_batch(state)
    schedule_flush(state.flush_interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    state = persist_batch(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:health, _from, state) do
    {:reply, health_snapshot(state), state}
  end

  @impl true
  def handle_cast({:dropped, reason}, state) do
    {:noreply, %{state | dropped_total: state.dropped_total + 1, last_error: inspect(reason)}}
  end

  defp persist_batch(state) do
    events = Buffer.drain(@buffer_name, state.batch_size)

    if events == [] do
      state
    else
      case insert_rows(events) do
        {:ok, count} ->
          Buffer.release(@buffer_name, length(events))

          %{state | inserted_total: state.inserted_total + count}

        {:error, reason} ->
          Buffer.release(@buffer_name, length(events))

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
        |> cast_field_types()
        |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "nil" end)
        |> Map.new()
        |> Map.put_new(:inserted_at, now)
      end)

    {count, _} =
      Repo.insert_all(ToolCall, entries,
        on_conflict: :nothing,
        conflict_target: [:event_id]
      )

    {:ok, count}
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

  defp health_snapshot(state) do
    %{
      status: :ok,
      buffer: Buffer.health(@buffer_name),
      inserted_total: state.inserted_total,
      dropped_total: state.dropped_total,
      failed_total: state.failed_total,
      last_error: state.last_error
    }
  end

  defp schedule_flush(interval_ms) when interval_ms > 0 do
    Process.send_after(self(), :flush, interval_ms)
  end

  defp config(key, default) do
    Application.get_env(:backplane_mcp, :mcp_tool_log_writer, [])
    |> Keyword.get(key, default)
  end
end

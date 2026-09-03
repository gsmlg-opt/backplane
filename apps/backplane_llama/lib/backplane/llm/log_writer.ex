defmodule Backplane.LLM.LogWriter do
  @moduledoc """
  Bounded, batched writer for LLM proxy access records.

  Listens for terminal Observability v2 LLM events and persists sanitized rows
  into `llm_logs` without blocking request processes.
  """

  use GenServer

  require Logger

  alias Backplane.LLM.ProxyRequest
  alias Backplane.Observability.Buffer
  alias Backplane.Repo

  @telemetry_event [:backplane, :llm_proxy, :request, :stop]

  @handler_id "backplane-llm-log-writer"

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
        buffer: Buffer.health(:llm_proxy),
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

    case Buffer.try_enqueue(:llm_proxy, row) do
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
      batch_size: Keyword.get(opts, :batch_size, config(:batch_size, 100)),
      flush_interval_ms: Keyword.get(opts, :flush_interval_ms, config(:flush_interval_ms, 1_000)),
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
    events = Buffer.drain(:llm_proxy, state.batch_size)

    if events == [] do
      state
    else
      case insert_rows(events) do
        {:ok, count} ->
          Buffer.release(:llm_proxy, length(events))

          %{state | inserted_total: state.inserted_total + count}

        {:error, reason} ->
          Buffer.release(:llm_proxy, length(events))

          Logger.warning("LLM LogWriter batch insert failed: #{inspect(reason)}")

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
      Repo.insert_all(ProxyRequest, entries,
        on_conflict: :nothing,
        conflict_target: [:event_id]
      )

    {:ok, count}
  rescue
    exception ->
      {:error, exception}
  end

  @row_fields ~w(
    event_id request_id trace_id client_id client_ip operation api_surface
    http_method path provider_id provider_name provider_api_id provider_model_id
    provider_model_surface_id requested_model resolved_model status outcome
    error_kind error_code error_reason stream duration_ms upstream_duration_ms
    ttft_ms stream_duration_ms stream_chunks request_bytes response_bytes
    input_tokens output_tokens total_tokens cached_tokens reasoning_tokens
    finish_reason provider_request_id attempt_count metadata
  )a

  defp row_from_metadata(metadata) do
    attrs = metadata |> Map.get(:attributes, %{}) |> atomize_keys()

    attrs
    |> Map.take(@row_fields)
    |> Map.put(:event_id, metadata[:event_id] || attrs[:event_id])
    |> Map.put(:request_id, get_in(metadata, [:context, :request_id]) || attrs[:request_id])
    |> Map.put(:trace_id, get_in(metadata, [:context, :trace_id]) || attrs[:trace_id])
    |> ensure_required_fields()
  end

  defp ensure_required_fields(row) do
    row
    |> Map.put_new(:operation, "request")
    |> Map.put_new(:outcome, "success")
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
    |> cast_boolean(:stream)
    |> cast_integer(:status)
    |> cast_integer(:duration_ms)
    |> cast_integer(:upstream_duration_ms)
    |> cast_integer(:ttft_ms)
    |> cast_integer(:stream_duration_ms)
    |> cast_integer(:stream_chunks)
    |> cast_integer(:request_bytes)
    |> cast_integer(:response_bytes)
    |> cast_integer(:input_tokens)
    |> cast_integer(:output_tokens)
    |> cast_integer(:total_tokens)
    |> cast_integer(:cached_tokens)
    |> cast_integer(:reasoning_tokens)
    |> cast_integer(:attempt_count)
  end

  defp cast_boolean(row, key) do
    case Map.get(row, key) do
      "true" -> Map.put(row, key, true)
      "false" -> Map.put(row, key, false)
      _ -> row
    end
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
      buffer: Buffer.health(:llm_proxy),
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
    Application.get_env(:backplane_llama, :llm_log_writer, [])
    |> Keyword.get(key, default)
  end
end

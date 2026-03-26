defmodule Backplane.Metrics do
  @moduledoc """
  Lightweight ETS-based metrics collector for Backplane telemetry events.

  Attaches to telemetry events and maintains counters and timing summaries
  in an ETS table. Exposed via `GET /metrics` as JSON.
  """

  use GenServer

  require Logger

  alias Backplane.Proxy.Pool

  @table __MODULE__

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Return all metrics as a map."
  @spec snapshot() :: map()
  def snapshot do
    base =
      @table
      |> :ets.tab2list()
      |> Enum.reduce(%{}, fn
        {{:counter, name}, count}, acc ->
          put_in(acc, [Access.key(:counters, %{}), name], count)

        {{:timing, name}, count, total_us}, acc ->
          avg_us = if count > 0, do: div(total_us, count), else: 0

          put_in(acc, [Access.key(:timings, %{}), name], %{
            count: count,
            total_us: total_us,
            avg_us: avg_us
          })

        {{:last_called, _name}, _timestamp}, acc ->
          # Per-tool call timestamps are read via last_called_at/1, not included in snapshot
          acc
      end)

    Map.put(base, :upstreams, upstream_status())
  end

  defp upstream_status do
    Pool.list_upstreams()
    |> Enum.map(fn u ->
      %{
        name: u.name,
        status: u.status,
        tool_count: u.tool_count,
        consecutive_ping_failures: u[:consecutive_ping_failures] || 0
      }
    end)
  rescue
    e ->
      Logger.warning("Failed to get upstream status: #{Exception.message(e)}")
      []
  end

  @doc "Increment a named counter."
  @spec inc(String.t(), integer()) :: integer() | :ok
  def inc(name, amount \\ 1) do
    :ets.update_counter(@table, {:counter, name}, {2, amount}, {{:counter, name}, 0})
  catch
    :error, :badarg -> :ok
  end

  @doc "Record a per-tool last-called timestamp."
  @spec record_tool_call(String.t()) :: true | :ok
  def record_tool_call(tool_name) do
    :ets.insert(@table, {{:last_called, tool_name}, DateTime.utc_now()})
  catch
    :error, :badarg -> :ok
  end

  @doc "Get the last-called timestamp for a tool, or nil."
  @spec last_called_at(String.t()) :: DateTime.t() | nil
  def last_called_at(tool_name) do
    case :ets.lookup(@table, {:last_called, tool_name}) do
      [{{:last_called, ^tool_name}, timestamp}] -> timestamp
      [] -> nil
    end
  catch
    :error, :badarg -> nil
  end

  @doc "Record a timing measurement in microseconds."
  @spec record_timing(String.t(), non_neg_integer()) :: [integer()] | :ok
  def record_timing(name, duration_us) do
    :ets.update_counter(
      @table,
      {:timing, name},
      [{2, 1}, {3, duration_us}],
      {{:timing, name}, 0, 0}
    )
  catch
    :error, :badarg -> :ok
  end

  # Server

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, write_concurrency: true])
    attach_telemetry_handlers()
    {:ok, %{}}
  end

  defp attach_telemetry_handlers do
    :telemetry.attach_many(
      "backplane-metrics",
      [
        [:backplane, :mcp_request, :start],
        [:backplane, :tool_call, :start],
        [:backplane, :tool_call, :stop],
        [:backplane, :tool_call, :exception],
        [:backplane, :sse_stream, :start],
        [:backplane, :sse_stream, :stop],
        [:oban, :job, :stop],
        [:oban, :job, :exception]
      ],
      &handle_event/4,
      nil
    )
  end

  @doc false
  def handle_event([:backplane, :mcp_request, :start], _measurements, metadata, _config) do
    inc("mcp_requests_total")
    inc("mcp_requests.#{metadata.method}")
  end

  def handle_event([:backplane, :tool_call, :start], _measurements, metadata, _config) do
    inc("tool_calls_total")
    if tool = metadata[:tool], do: record_tool_call(tool)
  end

  def handle_event([:backplane, :tool_call, :stop], measurements, metadata, _config) do
    duration_us = System.convert_time_unit(measurements.duration, :native, :microsecond)
    record_timing("tool_call_duration", duration_us)

    if tool = metadata[:tool] do
      record_timing("tool.#{tool}", duration_us)
    end

    case metadata[:result] do
      :error -> inc("tool_calls_errors")
      _ -> inc("tool_calls_success")
    end
  end

  def handle_event([:backplane, :tool_call, :exception], _measurements, _metadata, _config) do
    inc("tool_calls_exceptions")
  end

  def handle_event([:backplane, :sse_stream, :start], _measurements, _metadata, _config) do
    inc("sse_streams_started")
  end

  def handle_event([:backplane, :sse_stream, :stop], measurements, _metadata, _config) do
    duration_us = System.convert_time_unit(measurements.duration, :native, :microsecond)
    record_timing("sse_stream_duration", duration_us)
  end

  def handle_event([:oban, :job, :stop], measurements, metadata, _config) do
    queue = to_string(metadata.queue)
    worker = to_string(metadata.worker)
    inc("oban_jobs_completed")
    inc("oban_jobs.#{queue}")
    inc("oban_workers.#{worker}")
    duration_us = System.convert_time_unit(measurements.duration, :native, :microsecond)
    record_timing("oban_job_duration", duration_us)
  end

  def handle_event([:oban, :job, :exception], _measurements, metadata, _config) do
    queue = to_string(metadata.queue)
    inc("oban_jobs_failed")
    inc("oban_jobs_failed.#{queue}")
  end
end

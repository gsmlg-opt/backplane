defmodule Backplane.Metrics do
  @moduledoc """
  Lightweight ETS-based metrics collector for Backplane telemetry events.

  Attaches to telemetry events and maintains counters and timing summaries
  in an ETS table. Exposed via `GET /metrics` as JSON.
  """

  use GenServer

  require Logger

  @table __MODULE__
  @upstream_pool Backplane.Proxy.Pool

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

    base
    |> Map.put(:upstreams, upstream_status())
    |> Map.put(:system, system_info())
  end

  defp system_info do
    memory = :erlang.memory()

    %{
      memory_total_mb: div(memory[:total], 1_048_576),
      memory_processes_mb: div(memory[:processes], 1_048_576),
      memory_ets_mb: div(memory[:ets], 1_048_576),
      process_count: :erlang.system_info(:process_count),
      schedulers_online: :erlang.system_info(:schedulers_online),
      uptime_seconds: div(:erlang.statistics(:wall_clock) |> elem(0), 1000)
    }
  end

  defp upstream_status do
    apply(@upstream_pool, :list_upstreams, [])
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
        [:backplane, :memory, :event, :append],
        [:backplane, :memory, :event, :duplicate],
        [:backplane, :memory, :event, :error],
        [:backplane, :llm_proxy, :request, :stop],
        [:backplane, :mcp_proxy, :request, :stop],
        [:backplane, :mcp_proxy, :tool_call, :stop],
        [:backplane, :observability, :events, :accepted],
        [:backplane, :observability, :events, :persisted],
        [:backplane, :observability, :events, :duplicate],
        [:backplane, :observability, :events, :dropped],
        [:backplane, :observability, :writer, :failure],
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

  def handle_event(
        [:backplane, :memory, :event, :append],
        measurements,
        _metadata,
        _config
      ) do
    inc("memory_events_appended")

    record_timing(
      "memory_event_append_duration",
      native_to_microseconds(measurements[:duration])
    )
  end

  def handle_event(
        [:backplane, :memory, :event, :duplicate],
        _measurements,
        _metadata,
        _config
      ) do
    inc("memory_events_duplicates")
  end

  def handle_event(
        [:backplane, :memory, :event, :error],
        _measurements,
        _metadata,
        _config
      ) do
    inc("memory_events_errors")
  end

  def handle_event([:backplane, :llm_proxy, :request, :stop], measurements, metadata, _config) do
    inc("llm_proxy.requests.total")

    case metadata[:outcome] || get_in(metadata, [:attributes, :outcome]) do
      "success" -> inc("llm_proxy.requests.success")
      "error" -> inc("llm_proxy.requests.error")
      _ -> :ok
    end

    case metadata[:provider_name] || get_in(metadata, [:attributes, :provider_name]) do
      nil -> :ok
      provider -> inc("llm_proxy.requests.#{provider}")
    end

    record_timing("llm_proxy.duration", milliseconds_to_microseconds(measurements[:duration_ms]))

    case measurements[:ttft_ms] do
      nil -> :ok
      ttft -> record_timing("llm_proxy.ttft", milliseconds_to_microseconds(ttft))
    end

    inc("llm_proxy.tokens.input", measurements[:input_tokens] || 0)
    inc("llm_proxy.tokens.output", measurements[:output_tokens] || 0)
  end

  def handle_event([:backplane, :mcp_proxy, :request, :stop], measurements, metadata, _config) do
    inc("mcp_proxy.requests.total")

    case metadata[:rpc_method] || get_in(metadata, [:attributes, :rpc_method]) do
      nil -> :ok
      method -> inc("mcp_proxy.requests.#{method}")
    end

    if (metadata[:outcome] || get_in(metadata, [:attributes, :outcome])) == "error" do
      inc("mcp_proxy.requests.error")
    end

    record_timing(
      "mcp_proxy.duration",
      milliseconds_to_microseconds(measurements[:duration_ms])
    )
  end

  def handle_event([:backplane, :mcp_proxy, :tool_call, :stop], measurements, metadata, _config) do
    inc("mcp_proxy.tool_calls.total")

    case metadata[:tool_name] || get_in(metadata, [:attributes, :tool_name]) do
      nil -> :ok
      tool -> inc("mcp_proxy.tool_calls.#{tool}")
    end

    if (metadata[:outcome] || get_in(metadata, [:attributes, :outcome])) == "error" do
      inc("mcp_proxy.tool_calls.error")
    end

    record_timing(
      "mcp_proxy.upstream.duration",
      milliseconds_to_microseconds(measurements[:duration_ms])
    )
  end

  def handle_event(
        [:backplane, :observability, :events, :accepted],
        measurements,
        metadata,
        _config
      ) do
    inc("observability.events.accepted.#{metadata.domain}", measurements[:count] || 1)
  end

  def handle_event(
        [:backplane, :observability, :events, :persisted],
        measurements,
        metadata,
        _config
      ) do
    inc("observability.events.persisted.#{metadata.domain}", measurements[:count] || 1)

    if lag_ms = measurements[:persistence_lag_ms] do
      record_timing("observability.writer.persistence_lag_ms.#{metadata.domain}", lag_ms * 1_000)
    end
  end

  def handle_event(
        [:backplane, :observability, :events, :duplicate],
        measurements,
        metadata,
        _config
      ) do
    inc("observability.events.duplicate.#{metadata.domain}", measurements[:count] || 1)
  end

  def handle_event(
        [:backplane, :observability, :events, :dropped],
        measurements,
        metadata,
        _config
      ) do
    inc("observability.events.dropped.#{metadata.domain}", measurements[:count] || 1)
  end

  def handle_event(
        [:backplane, :observability, :writer, :failure],
        measurements,
        metadata,
        _config
      ) do
    inc("observability.writer.failures.#{metadata.domain}", measurements[:count] || 1)
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

  defp native_to_microseconds(duration) when is_integer(duration) and duration >= 0,
    do: System.convert_time_unit(duration, :native, :microsecond)

  defp native_to_microseconds(_duration), do: 0

  defp milliseconds_to_microseconds(duration) when is_integer(duration) and duration >= 0,
    do: duration * 1_000

  defp milliseconds_to_microseconds(_duration), do: 0
end

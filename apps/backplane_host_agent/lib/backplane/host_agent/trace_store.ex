defmodule Backplane.HostAgent.TraceStore do
  @moduledoc """
  Appends host-agent telemetry events to local JSONL trace files.
  """

  use GenServer

  alias Backplane.HostAgent.Trace

  @handler_id "backplane-host-agent-trace-store"
  @events [
    [:backplane, :host_agent, :memory, :call, :stop],
    [:backplane, :host_agent, :memory, :call, :exception],
    [:backplane, :host_agent, :memory_pruner, :run],
    [:backplane, :host_agent, :mcp, :request, :start],
    [:backplane, :host_agent, :mcp, :request, :stop],
    [:backplane, :host_agent, :mcp, :request, :exception]
  ]
  @default_retention_days 14
  @daily_ms 86_400_000

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    if name do
      GenServer.start_link(__MODULE__, opts, name: name)
    else
      GenServer.start_link(__MODULE__, opts)
    end
  end

  @doc "Records one trace item without going through telemetry."
  def record(pid \\ __MODULE__, event, measurements, metadata) do
    GenServer.cast(pid, {:record, event, measurements, metadata, Trace.current()})
  end

  @doc "Attaches telemetry handlers that append trace events to `server`."
  def attach(server \\ __MODULE__, handler_id \\ @handler_id) do
    detach(handler_id)

    :telemetry.attach_many(
      handler_id,
      @events,
      &__MODULE__.handle_event/4,
      server
    )

    :ok
  end

  @doc "Detaches telemetry handlers."
  def detach(handler_id \\ @handler_id) do
    case :telemetry.detach(handler_id) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end

  @doc false
  def handle_event(event, measurements, metadata, server) do
    GenServer.cast(server, {:record, event, measurements, metadata, Trace.current()})
  end

  @impl true
  def init(opts) do
    telemetry_dir = Keyword.fetch!(opts, :dir)
    retention_days = Keyword.get(opts, :retention_days, @default_retention_days)
    handler_id = Keyword.get(opts, :handler_id, @handler_id)

    File.mkdir_p!(telemetry_dir)

    state = %{
      dir: telemetry_dir,
      seq: load_seq(telemetry_dir),
      retention_days: retention_days,
      handler_id: handler_id
    }

    prune_old_files(state)
    attach(self(), handler_id)
    schedule_prune()

    {:ok, state}
  end

  @impl true
  def terminate(_reason, %{handler_id: handler_id}) do
    detach(handler_id)
  end

  @impl true
  def handle_cast({:record, event, measurements, metadata, ctx}, state) do
    next_state = append_trace(state, event, measurements, metadata, ctx)
    {:noreply, next_state}
  end

  @impl true
  def handle_info(:prune, state) do
    prune_old_files(state)
    schedule_prune()
    {:noreply, state}
  end

  defp append_trace(state, event, measurements, metadata, ctx) do
    ctx = ctx || Trace.new_ctx()
    seq = state.seq + 1
    occurred_at = timestamp()

    item =
      %{
        "seq" => seq,
        "trace_id" => trace_id(ctx),
        "span_id" => span_id(ctx),
        "parent_id" => parent_id(ctx),
        "event" => Enum.join(event, "."),
        "measurements" => sanitize(measurements),
        "metadata" => sanitize(metadata),
        "occurred_at" => occurred_at
      }

    path = trace_file(state.dir, occurred_at)
    File.write!(path, Jason.encode!(item) <> "\n", [:append])
    persist_seq(state.dir, seq)

    %{state | seq: seq}
  rescue
    _error -> state
  end

  defp trace_id(%{trace_id: trace_id}), do: trace_id
  defp trace_id(_ctx), do: nil

  defp span_id(%{span_id: span_id}), do: span_id
  defp span_id(_ctx), do: nil

  defp parent_id(%{parent_id: parent_id}), do: parent_id
  defp parent_id(_ctx), do: nil

  defp load_seq(dir) do
    case File.read(counter_file(dir)) do
      {:ok, raw} ->
        raw
        |> String.trim()
        |> Integer.parse()
        |> case do
          {seq, ""} when seq >= 0 -> seq
          _ -> max_seq_from_files(dir)
        end

      {:error, _reason} ->
        max_seq_from_files(dir)
    end
  end

  defp max_seq_from_files(dir) do
    dir
    |> trace_files()
    |> Enum.reduce(0, fn path, max_seq ->
      path
      |> File.stream!(:line, [])
      |> Enum.reduce(max_seq, fn line, acc ->
        case Jason.decode(line) do
          {:ok, %{"seq" => seq}} when is_integer(seq) and seq > acc -> seq
          _ -> acc
        end
      end)
    end)
  rescue
    _error -> 0
  end

  defp persist_seq(dir, seq), do: File.write!(counter_file(dir), Integer.to_string(seq))

  defp counter_file(dir), do: Path.join(dir, "counter.txt")

  defp trace_file(dir, occurred_at) do
    date = occurred_at |> String.slice(0, 10)
    Path.join(dir, "traces-#{date}.jsonl")
  end

  defp trace_files(dir) do
    dir
    |> Path.join("traces-*.jsonl")
    |> Path.wildcard()
    |> Enum.sort()
  end

  defp prune_old_files(%{retention_days: retention_days}) when retention_days <= 0, do: :ok

  defp prune_old_files(%{dir: dir, retention_days: retention_days}) do
    cutoff = Date.utc_today() |> Date.add(-retention_days)

    dir
    |> trace_files()
    |> Enum.each(fn path ->
      with {:ok, date} <- date_from_trace_file(path),
           true <- Date.compare(date, cutoff) == :lt do
        File.rm(path)
      end
    end)
  end

  defp date_from_trace_file(path) do
    path
    |> Path.basename()
    |> case do
      "traces-" <> rest -> Date.from_iso8601(String.trim_trailing(rest, ".jsonl"))
      _ -> {:error, :invalid_name}
    end
  end

  defp schedule_prune, do: Process.send_after(self(), :prune, @daily_ms)

  defp sanitize(value) when is_map(value) do
    Map.new(value, fn {key, val} -> {sanitize_key(key), sanitize(val)} end)
  end

  defp sanitize(value) when is_list(value), do: Enum.map(value, &sanitize/1)
  defp sanitize(value) when is_binary(value), do: value
  defp sanitize(value) when is_boolean(value), do: value
  defp sanitize(value) when is_integer(value), do: value
  defp sanitize(value) when is_float(value), do: value
  defp sanitize(nil), do: nil
  defp sanitize(value) when is_atom(value), do: Atom.to_string(value)
  defp sanitize(value), do: inspect(value)

  defp sanitize_key(key) when is_binary(key), do: key
  defp sanitize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp sanitize_key(key), do: inspect(key)

  defp timestamp do
    DateTime.utc_now()
    |> DateTime.truncate(:microsecond)
    |> DateTime.to_iso8601()
  end
end

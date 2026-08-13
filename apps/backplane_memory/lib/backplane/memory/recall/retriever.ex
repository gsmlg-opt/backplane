defmodule Backplane.Memory.Recall.Retriever do
  @moduledoc "Parallel, failure-isolated Recall V2 retrieval and weighted RRF fusion."

  alias Backplane.Memory.Config
  alias Backplane.Memory.Recall.{Channels, Fusion, QueryPlan}

  @channels [:fts, :vector, :graph]
  @options [:timeout_ms, :channel_limits, :channel_fns, :embed_fn]
  @default_timeout_ms 1_000
  @max_timeout_ms 60_000

  def retrieve(plan, opts \\ [])

  def retrieve(%QueryPlan{} = plan, opts) do
    with :ok <- validate_options(opts) do
      timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
      limits = Keyword.get(opts, :channel_limits, Config.recall_channel_limits())
      overrides = Keyword.get(opts, :channel_fns, %{})

      tasks =
        Map.new(@channels, fn channel ->
          if plan.channel_weights[channel] > 0.0 do
            fun = Map.get(overrides, channel, default_fun(channel, opts))
            started = System.monotonic_time()

            case start_task(task_supervisor(), fn ->
                   invoke(fun, plan, limit(limits, channel), started)
                 end) do
              {:ok, task} -> {channel, {task, started}}
              :error -> {channel, {:unavailable, started}}
            end
          else
            {channel, :disabled}
          end
        end)

      outcomes = await_channels(tasks, timeout)

      case Fusion.fuse(outcomes, plan.channel_weights, Config.recall_rrf_k()) do
        {:ok, fused} ->
          {:ok, %{fused: fused, channels: outcomes, trace: trace(outcomes)}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def retrieve(_plan, _opts), do: {:error, :invalid_query_plan}

  def validate_options(opts) do
    with true <- Keyword.keyword?(opts),
         keys = Keyword.keys(opts),
         true <- keys == Enum.uniq(keys) and keys -- @options == [],
         timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms),
         true <- is_integer(timeout) and timeout in 1..@max_timeout_ms,
         limits = Keyword.get(opts, :channel_limits, Config.recall_channel_limits()),
         true <- valid_channel_limits?(limits),
         overrides = Keyword.get(opts, :channel_fns, %{}),
         true <- valid_channel_fns?(overrides),
         embed_fn = Keyword.get(opts, :embed_fn),
         true <- is_nil(embed_fn) or is_function(embed_fn, 3) do
      :ok
    else
      _invalid -> {:error, :invalid_options}
    end
  end

  defp valid_channel_limits?(limits) when is_map(limits) do
    Enum.all?(limits, fn
      {channel, limit} when channel in @channels ->
        is_integer(limit) and limit in 1..500

      {channel, limit} when channel in ["fts", "vector", "graph"] ->
        is_integer(limit) and limit in 1..500

      _unknown ->
        false
    end)
  end

  defp valid_channel_limits?(_limits), do: false

  defp valid_channel_fns?(overrides) when is_map(overrides) do
    Enum.all?(overrides, fn
      {channel, provider} when channel in @channels -> is_function(provider, 2)
      _unknown -> false
    end)
  end

  defp valid_channel_fns?(_overrides), do: false

  defp default_fun(:fts, _opts), do: &Channels.fts/2
  defp default_fun(:graph, _opts), do: &Channels.graph/2

  defp default_fun(:vector, opts) do
    embed_fn = Keyword.get(opts, :embed_fn)
    fn plan, limit -> Channels.vector(plan, limit, embed_fn) end
  end

  defp invoke(fun, plan, limit, started) do
    result =
      try do
        fun.(plan, limit)
      rescue
        _exception -> {:error, :channel_exception}
      catch
        :exit, _reason -> {:error, :channel_exit}
        _kind, _reason -> {:error, :channel_failure}
      end

    duration = duration_us(started)

    case result do
      {:ok, candidates} when is_list(candidates) ->
        %{status: :ok, candidates: candidates, error: nil, duration_us: duration}

      {:unavailable, _reason} ->
        %{status: :unavailable, candidates: [], error: "unavailable", duration_us: duration}

      {:error, reason} ->
        %{status: :error, candidates: [], error: error_class(reason), duration_us: duration}

      _invalid ->
        %{status: :error, candidates: [], error: "invalid_channel_result", duration_us: duration}
    end
  end

  defp await_channels(tasks, timeout) do
    active = for {channel, {%Task{} = task, started}} <- tasks, do: {channel, task, started}
    replies = Task.yield_many(Enum.map(active, &elem(&1, 1)), timeout)
    reply_by_ref = Map.new(replies, fn {task, result} -> {task.ref, result} end)

    Map.new(tasks, fn
      {channel, :disabled} ->
        {channel, %{status: :unavailable, candidates: [], error: nil, duration_us: 0}}

      {channel, {:unavailable, started}} ->
        {channel,
         %{
           status: :unavailable,
           candidates: [],
           error: "task_supervisor_unavailable",
           duration_us: duration_us(started)
         }}

      {channel, {task, started}} ->
        case reply_by_ref[task.ref] do
          {:ok, outcome} ->
            {channel, outcome}

          nil ->
            Task.shutdown(task, :brutal_kill)

            {channel,
             %{
               status: :timeout,
               candidates: [],
               error: "timeout",
               duration_us: duration_us(started)
             }}

          {:exit, _reason} ->
            {channel,
             %{
               status: :error,
               candidates: [],
               error: "channel_exit",
               duration_us: duration_us(started)
             }}
        end
    end)
  end

  defp trace(outcomes) do
    availability = Map.new(@channels, &{Atom.to_string(&1), outcomes[&1].status == :ok})

    errors =
      outcomes
      |> Enum.flat_map(fn {channel, outcome} ->
        if outcome.error, do: [{Atom.to_string(channel), outcome.error}], else: []
      end)
      |> Map.new()

    timings = Map.new(@channels, &{Atom.to_string(&1), outcomes[&1].duration_us})
    %{channel_availability: availability, channel_errors: errors, channel_timings_us: timings}
  end

  defp error_class(reason) when reason in [:channel_exit, :channel_exception, :channel_failure],
    do: Atom.to_string(reason)

  defp error_class(_reason), do: "provider_error"

  defp limit(limits, channel),
    do: Map.get(limits, channel, Map.get(limits, Atom.to_string(channel), 50))

  defp duration_us(started),
    do: System.convert_time_unit(System.monotonic_time() - started, :native, :microsecond)

  defp start_task(supervisor, fun) do
    {:ok, Task.Supervisor.async_nolink(supervisor, fun)}
  catch
    :exit, _reason -> :error
  end

  defp task_supervisor,
    do:
      Application.get_env(
        :backplane_memory,
        :recall_task_supervisor,
        Backplane.Memory.Recall.TaskSupervisor
      )
end

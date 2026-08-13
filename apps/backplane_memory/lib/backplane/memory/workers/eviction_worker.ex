defmodule Backplane.Memory.Workers.EvictionWorker do
  @moduledoc "Nightly Oban cron: decay strength and evict weak memories."
  use Oban.Worker, queue: :memory, max_attempts: 3

  import Ecto.Query
  alias Backplane.Memory.Audit
  alias Backplane.Memory.Memories.Memory

  @default_batch_size 100
  @max_batch_size 500

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)

  @impl Oban.Worker
  def perform(%Oban.Job{} = job) do
    Backplane.Memory.PipelineTelemetry.span("eviction", job.args, fn ->
      do_perform(job)
    end)
  end

  defp do_perform(%Oban.Job{args: args}) do
    decay_period = parse_setting("memory.decay_period_days", 30)
    threshold = parse_float_setting("memory.eviction_threshold", 0.1)
    now = DateTime.utc_now()
    batch_size = parse_batch_size(args)

    {:ok, evicted} =
      repo().transaction(fn ->
        now
        |> candidate_ids(decay_period, threshold, batch_size)
        |> evict_candidates(now, decay_period, threshold)
      end)

    {:ok, %{evicted: evicted}}
  end

  @doc false
  def candidate_ids(now, decay_period_days, threshold, batch_size) do
    predicate = eligible(now, decay_period_days, threshold)

    repo().all(
      from(m in Memory,
        where: ^predicate,
        order_by: [asc: m.inserted_at, asc: m.id],
        limit: ^batch_size,
        select: m.id
      )
    )
  end

  @doc false
  def evict_candidates([], _now, _decay_period_days, _threshold), do: 0

  def evict_candidates(ids, now, decay_period_days, threshold) do
    predicate = eligible(now, decay_period_days, threshold)

    {affected, archived} =
      repo().update_all(
        from(m in Memory,
          where: m.id in ^ids,
          where: ^predicate,
          select: %{
            id: m.id,
            host_id: m.host_id,
            client_id: m.client_id,
            scope: m.scope,
            namespace: m.namespace
          }
        ),
        set: [deleted_at: nil, lifecycle_state: "archived", superseded_by: nil]
      )

    Enum.each(archived, fn memory ->
      Audit.log("memory.archive", "system", [memory.id], %{
        reason: "retention",
        decay_period_days: decay_period_days,
        threshold: threshold,
        host_id: memory.host_id,
        client_id: memory.client_id,
        scope: memory.scope,
        namespace: memory.namespace,
        result: "archived"
      })
    end)

    affected
  end

  defp eligible(now, decay_period_days, threshold) do
    dynamic(
      [m],
      is_nil(m.deleted_at) and
        m.lifecycle_state not in ["archived", "superseded", "tombstoned"] and
        fragment(
          "COALESCE((?->>'strength')::double precision, 1.0) * power(0.9::double precision, floor(GREATEST(EXTRACT(EPOCH FROM (? - COALESCE(?, ?))), 0) / 86400)::integer / ?) * ? < ?",
          m.metadata,
          ^now,
          m.accessed_at,
          m.inserted_at,
          ^decay_period_days,
          m.confidence,
          ^threshold
        )
    )
  end

  defp parse_setting(key, default) do
    case Backplane.Settings.get(key) do
      v when is_binary(v) -> String.to_integer(v)
      v when is_integer(v) -> v
      _ -> default
    end
  end

  defp parse_float_setting(key, default) do
    case Backplane.Settings.get(key) do
      v when is_binary(v) -> String.to_float(v)
      v when is_float(v) -> v
      _ -> default
    end
  end

  defp parse_batch_size(args) do
    case Map.get(args, "batch_size", @default_batch_size) do
      value when is_integer(value) -> value
      value when is_binary(value) -> String.to_integer(value)
      _ -> @default_batch_size
    end
    |> max(1)
    |> min(@max_batch_size)
  end
end

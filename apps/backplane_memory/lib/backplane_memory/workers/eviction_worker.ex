defmodule BackplaneMemory.Workers.EvictionWorker do
  @moduledoc "Nightly Oban cron: decay strength and evict weak memories."
  use Oban.Worker, queue: :memory, max_attempts: 3

  import Ecto.Query
  alias BackplaneMemory.Memories.Memory

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    decay_period = parse_setting("memory.decay_period_days", 30)
    threshold = parse_float_setting("memory.eviction_threshold", 0.1)

    now = DateTime.utc_now()

    memories =
      repo().all(
        from(m in Memory,
          where: is_nil(m.deleted_at),
          select: %{
            id: m.id,
            confidence: m.confidence,
            access_count: m.access_count,
            accessed_at: m.accessed_at,
            inserted_at: m.inserted_at,
            metadata: m.metadata
          }
        )
      )

    evict_ids =
      memories
      |> Enum.filter(fn m ->
        strength = compute_strength(m, now, decay_period)
        strength * m.confidence < threshold
      end)
      |> Enum.map(& &1.id)

    if evict_ids != [] do
      repo().update_all(
        from(m in Memory, where: m.id in ^evict_ids),
        set: [deleted_at: now]
      )
    end

    {:ok, %{evicted: length(evict_ids)}}
  end

  defp compute_strength(memory, now, decay_period_days) do
    initial_strength = get_in(memory.metadata, ["strength"]) || 1.0
    last_access = memory.accessed_at || memory.inserted_at

    days_since_access =
      case last_access do
        nil ->
          0

        dt ->
          max(0, DateTime.diff(now, dt, :second) |> div(86_400))
      end

    decay_steps = div(days_since_access, decay_period_days)
    initial_strength * :math.pow(0.9, decay_steps)
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
end

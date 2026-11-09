defmodule Backplane.Memory.Workers.DistillSchedulerWorker do
  @moduledoc "Cron entry point: claims due session distillations and enqueues one worker each."

  use Styx.Worker, queue: :memory, max_attempts: 1

  alias Backplane.Memory.{Config, Distillations}
  alias Backplane.Memory.Workers.DistillWorker

  @stale_running_seconds 900
  @blocked_reason "memory.llm_model not configured"

  @impl Styx.Worker
  def perform(%Styx.Job{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    Distillations.reset_stale_running(DateTime.add(now, -@stale_running_seconds, :second))

    if Config.llm_model() do
      Distillations.unblock_all()
      slots = max(Config.distill_max_concurrency() - Distillations.running_count(), 0)

      now
      |> Distillations.claim_due(slots)
      |> Enum.each(&enqueue/1)
    else
      Distillations.block_due(now, @blocked_reason)
    end

    :ok
  end

  defp enqueue(row) do
    %{"subject_id" => row.subject_id}
    |> DistillWorker.new(unique: [period: 900, keys: [:subject_id]])
    |> Styx.insert()
  end
end

defmodule Backplane.Memory.Workers.DistillWorker do
  @moduledoc "Runs the memory agent over one claimed session; failures are recorded, never silent."

  use Styx.Worker, queue: :llm, max_attempts: 1

  alias Backplane.Memory.{Distill, Distillations}

  @impl Styx.Worker
  def perform(%Styx.Job{args: %{"subject_id" => subject_id}}) do
    Distill.run(subject_id)
  rescue
    exception -> Distillations.fail(subject_id, Exception.message(exception))
  end
end

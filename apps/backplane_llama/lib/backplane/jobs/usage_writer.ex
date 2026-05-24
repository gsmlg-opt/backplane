defmodule Backplane.Jobs.UsageWriter do
  @moduledoc """
  Oban worker that inserts a UsageLog record from job args.
  Enqueued by the UsageCollector telemetry handler on each LLM request.
  """

  use Oban.Worker, queue: :llm

  alias Backplane.LLM.UsageLog
  alias Backplane.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    %UsageLog{}
    |> UsageLog.changeset(args)
    |> Repo.insert()
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end

defmodule Backplane.Jobs.UsageWriter do
  @moduledoc """
  Legacy Oban worker for per-request LLM usage inserts (deprecated).

  Replaced by `Backplane.LLM.LogWriter` when Observability v2 LLM persistence is
  enabled. Retained for installations that have not yet switched writers.
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

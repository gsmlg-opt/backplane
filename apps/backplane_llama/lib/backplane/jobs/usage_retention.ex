defmodule Backplane.Jobs.UsageRetention do
  @moduledoc """
  Oban worker that deletes usage logs older than configured retention days.
  Should be scheduled as a cron job (e.g., daily).

  Retention period defaults to 90 days and can be configured via:
      config :backplane, :llm_usage_retention_days, 90
  """

  use Oban.Worker, queue: :llm

  import Ecto.Query

  alias Backplane.LLM.UsageLog
  alias Backplane.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    retention_days = Application.get_env(:backplane, :llm_usage_retention_days, 90)
    cutoff = DateTime.add(DateTime.utc_now(), -retention_days * 86_400, :second)

    from(l in UsageLog, where: l.inserted_at < ^cutoff)
    |> Repo.delete_all()

    :ok
  end
end

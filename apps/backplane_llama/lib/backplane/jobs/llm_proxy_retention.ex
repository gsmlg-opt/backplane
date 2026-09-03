defmodule Backplane.Jobs.LlmProxyRetention do
  @moduledoc """
  Oban worker that deletes LLM proxy access records older than configured retention.
  """

  use Oban.Worker, queue: :llm

  import Ecto.Query

  alias Backplane.LLM.ProxyRequest
  alias Backplane.Observability.Settings
  alias Backplane.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    retention_days = Settings.llm_proxy_retention_days()
    cutoff = DateTime.add(DateTime.utc_now(), -retention_days * 86_400, :second)

    from(l in ProxyRequest, where: l.inserted_at < ^cutoff)
    |> Repo.delete_all()

    :ok
  end
end

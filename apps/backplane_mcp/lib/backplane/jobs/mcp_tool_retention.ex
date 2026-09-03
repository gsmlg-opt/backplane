defmodule Backplane.Jobs.McpToolRetention do
  @moduledoc """
  Oban worker that deletes MCP tool-call records older than configured retention.
  """

  use Oban.Worker, queue: :default

  import Ecto.Query

  alias Backplane.MCP.ToolCall
  alias Backplane.Observability.Settings
  alias Backplane.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    retention_days = Settings.mcp_proxy_retention_days()
    cutoff = DateTime.add(DateTime.utc_now(), -retention_days * 86_400, :second)

    from(t in ToolCall, where: t.inserted_at < ^cutoff)
    |> Repo.delete_all()

    :ok
  end
end

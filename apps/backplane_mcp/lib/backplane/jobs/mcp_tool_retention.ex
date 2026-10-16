defmodule Backplane.Jobs.McpToolRetention do
  @moduledoc """
  Styx worker that deletes MCP tool-call records older than configured retention.
  """

  use Styx.Worker, queue: :default

  import Ecto.Query

  alias Backplane.MCP.ToolCall
  alias Backplane.Observability.Settings
  alias Backplane.Repo

  @impl Styx.Worker
  def perform(%Styx.Job{}) do
    retention_days = Settings.mcp_proxy_retention_days()
    cutoff = DateTime.add(DateTime.utc_now(), -retention_days * 86_400, :second)

    from(t in ToolCall, where: t.inserted_at < ^cutoff)
    |> Repo.delete_all()

    :ok
  end
end

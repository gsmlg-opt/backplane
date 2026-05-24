defmodule Backplane.Audit.Pruner do
  @moduledoc """
  Oban cron worker that prunes audit log entries older than the retention period.
  Default retention: 30 days.
  """

  use Oban.Worker,
    queue: :default,
    unique: [period: 3600]

  require Logger

  import Ecto.Query

  alias Backplane.Audit.{SkillLoadLog, ToolCallLog}
  alias Backplane.Repo

  @impl true
  def perform(%Oban.Job{}) do
    retention_days = Application.get_env(:backplane, :audit_retention_days, 30)
    cutoff = DateTime.utc_now() |> DateTime.add(-retention_days * 86_400, :second)

    tool_count =
      ToolCallLog
      |> where([l], l.inserted_at < ^cutoff)
      |> Repo.delete_all()
      |> elem(0)

    skill_count =
      SkillLoadLog
      |> where([l], l.inserted_at < ^cutoff)
      |> Repo.delete_all()
      |> elem(0)

    if tool_count + skill_count > 0 do
      Logger.info(
        "Audit pruner: deleted #{tool_count} tool_call_log and #{skill_count} skill_load_log entries older than #{retention_days} days"
      )
    end

    :ok
  end
end

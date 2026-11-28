defmodule Backplane.Diagnostics.ReportScheduler do
  @moduledoc "Claims durable issue changes and refreshes reports asynchronously."
  use GenServer
  import Ecto.Query

  alias Backplane.Diagnostics.{Issues, Reports}
  alias Backplane.Diagnostics.Issues.Change
  alias Backplane.Repo

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval_ms, 1_000)
    Process.send_after(self(), :refresh, interval)
    {:ok, interval}
  end

  @impl true
  def handle_info(:refresh, interval) do
    refresh_ready(8)
    Process.send_after(self(), :refresh, interval)
    {:noreply, interval}
  end

  defp refresh_ready(0), do: :ok

  defp refresh_ready(remaining) do
    if drain_once() == {:ok, :refreshed}, do: refresh_ready(remaining - 1), else: :ok
  end

  def drain_once do
    now = DateTime.utc_now()

    Repo.transact(
      fn ->
        ready =
          from entry in Change,
            where: entry.available_at <= ^now,
            order_by: [asc: entry.available_at, asc: entry.issue_id],
            limit: 1,
            lock: "FOR UPDATE SKIP LOCKED"

        case Repo.one(ready, log: false) do
          nil -> {:ok, :empty}
          change -> refresh_change(change, now)
        end
      end,
      log: false
    )
  rescue
    _error in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, :persistence_unavailable}
  end

  defp refresh_change(change, now) do
    issue = Issues.get(change.issue_id)
    previous = Reports.get(issue.id)
    revision = if previous, do: previous.revision + 1, else: 1

    snapshot = %{
      id: issue.id,
      status: issue.status,
      category: issue.category,
      severity: issue.severity,
      counts: Issues.counts(issue.id),
      events: Issues.events(issue.id, limit: 8),
      occurrence_ids: Enum.map(Issues.occurrences(issue.id, limit: 8), & &1.id),
      confirmed_contract_violation:
        issue.category == "agent_quality" and issue.severity in ["high", "critical"]
    }

    case Reports.refresh(snapshot, change: change.kind, revision: revision, now: now) do
      {:ok, _} ->
        Repo.delete!(change, log: false)
        {:ok, :refreshed}

      {:error, _} ->
        change
        |> Ecto.Changeset.change(available_at: DateTime.add(now, 30, :second))
        |> Repo.update!(log: false)

        {:ok, :retry}
    end
  end
end

defmodule Backplane.Memory.Distillations do
  @moduledoc "Lifecycle of per-session distillation runs (schedule, claim, complete, fail, block)."

  import Ecto.Query

  alias Backplane.Memory.{Config, Distillation, Records}

  require Logger

  @spec schedule(map()) :: {:ok, Distillation.t()}
  def schedule(%{subject_id: subject_id} = session) do
    now = now()
    due_at = DateTime.add(now, Config.distill_delay_seconds(), :second)
    mode = mode_for(session)

    attrs = %{
      subject_id: subject_id,
      host_id: session[:host_id],
      session_id: session[:session_id],
      agent_id: session[:agent_id],
      integration: session[:integration],
      status: "pending",
      mode: mode,
      due_at: due_at,
      last_error: nil,
      inserted_at: now,
      updated_at: now
    }

    on_conflict =
      from(d in Distillation,
        where: d.status != "running",
        update: [
          set: [
            host_id: ^attrs.host_id,
            session_id: ^attrs.session_id,
            agent_id: ^attrs.agent_id,
            integration: ^attrs.integration,
            status: "pending",
            mode: ^mode,
            due_at: ^due_at,
            last_error: nil,
            updated_at: ^now
          ]
        ]
      )

    repo().insert_all(Distillation, [attrs], on_conflict: on_conflict, conflict_target: :subject_id)

    {:ok, repo().get!(Distillation, subject_id)}
  end

  @spec claim_due(DateTime.t(), pos_integer()) :: [Distillation.t()]
  def claim_due(now, limit) do
    ids =
      from(d in Distillation,
        where: d.status == "pending" and d.due_at <= ^now,
        order_by: [asc: d.due_at, asc: d.subject_id],
        limit: ^limit,
        lock: "FOR UPDATE SKIP LOCKED",
        select: d.subject_id
      )

    query =
      from(d in Distillation,
        join: s in subquery(ids),
        on: d.subject_id == s.subject_id,
        select: d,
        update: [
          set: [status: "running", started_at: ^now, heartbeat_at: ^now, updated_at: ^now],
          inc: [attempts: 1]
        ]
      )

    {_count, rows} = repo().update_all(query, [])

    Enum.map(rows, fn row ->
      case mode_for(row) do
        mode when mode == row.mode ->
          row

        mode ->
          repo().update_all(from(d in Distillation, where: d.subject_id == ^row.subject_id),
            set: [mode: mode]
          )

          %{row | mode: mode}
      end
    end)
  end

  @doc """
  Records one completed chunk: advances the watermark to `through_sequence`,
  refreshes the heartbeat and adds `records_written` to the session total.
  """
  @spec record_progress(String.t(), integer(), non_neg_integer()) :: :ok
  def record_progress(subject_id, through_sequence, records_written) do
    now = now()

    from(d in Distillation, where: d.subject_id == ^subject_id)
    |> repo().update_all(
      set: [distilled_through_sequence: through_sequence, heartbeat_at: now, updated_at: now],
      inc: [records_written: records_written]
    )

    :ok
  end

  @spec complete(String.t()) :: :ok
  def complete(subject_id) do
    now = now()

    update_row(subject_id,
      status: "completed",
      finished_at: now,
      last_error: nil,
      updated_at: now
    )
  end

  @doc "Returns a run that stopped at the per-run chunk cap to `pending`, due now."
  @spec requeue(String.t()) :: :ok
  def requeue(subject_id) do
    now = now()
    update_row(subject_id, status: "pending", due_at: now, last_error: nil, updated_at: now)
  end

  @spec fail(String.t(), String.t()) :: :ok
  def fail(subject_id, reason) do
    Logger.warning("memory distillation failed subject=#{subject_id}: #{reason}")
    now = now()
    update_row(subject_id, status: "failed", last_error: reason, finished_at: now, updated_at: now)
  end

  @spec block_due(DateTime.t(), String.t()) :: non_neg_integer()
  def block_due(now, reason) do
    {count, _} =
      from(d in Distillation, where: d.status == "pending" and d.due_at <= ^now)
      |> repo().update_all(set: [status: "blocked", last_error: reason, updated_at: now])

    if count > 0,
      do: Logger.warning("memory distillation blocked #{count} due session(s): #{reason}")

    count
  end

  @spec unblock_all() :: non_neg_integer()
  def unblock_all do
    {count, _} =
      from(d in Distillation, where: d.status == "blocked")
      |> repo().update_all(set: [status: "pending", last_error: nil, updated_at: now()])

    count
  end

  @doc "Resets running rows whose heartbeat (claim or last completed chunk) is older than `older_than`."
  @spec reset_stale_running(DateTime.t()) :: non_neg_integer()
  def reset_stale_running(older_than) do
    {count, _} =
      from(d in Distillation,
        where:
          d.status == "running" and
            coalesce(d.heartbeat_at, d.started_at) < ^older_than
      )
      |> repo().update_all(set: [status: "pending", updated_at: now()])

    count
  end

  @spec retry(String.t()) :: {:ok, Distillation.t()} | {:error, :not_found}
  def retry(subject_id) do
    now = now()

    {count, _} =
      from(d in Distillation,
        where: d.subject_id == ^subject_id and d.status in ["failed", "blocked", "completed"]
      )
      |> repo().update_all(set: [status: "pending", due_at: now, last_error: nil, updated_at: now])

    case {count, repo().get(Distillation, subject_id)} do
      {1, %Distillation{} = row} -> {:ok, row}
      _ -> {:error, :not_found}
    end
  end

  @spec running_count() :: non_neg_integer()
  def running_count do
    repo().aggregate(from(d in Distillation, where: d.status == "running"), :count)
  end

  @spec for_subjects([String.t()]) :: %{String.t() => Distillation.t()}
  def for_subjects(subject_ids) do
    from(d in Distillation, where: d.subject_id in ^subject_ids)
    |> repo().all()
    |> Map.new(&{&1.subject_id, &1})
  end

  @spec counts() :: %{String.t() => non_neg_integer()}
  def counts do
    from(d in Distillation, group_by: d.status, select: {d.status, count(d.subject_id)})
    |> repo().all()
    |> Map.new()
  end

  defp mode_for(%{session_id: session_id} = session) when is_binary(session_id) do
    case Records.agent_written_for_session(Map.get(session, :host_id), session_id) do
      [] -> "distill"
      _ -> "review"
    end
  end

  defp mode_for(_session), do: "distill"

  defp update_row(subject_id, set) do
    from(d in Distillation, where: d.subject_id == ^subject_id) |> repo().update_all(set: set)
    :ok
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)
end

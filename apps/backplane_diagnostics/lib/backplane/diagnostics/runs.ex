defmodule Backplane.Diagnostics.Runs do
  @moduledoc "Source-scoped native runs and their immutable diagnostic observations."

  import Ecto.Query

  alias Backplane.Diagnostics.Events.Event
  alias Backplane.Repo

  @state_events ~w(run_started run_progress run_waiting run_finished)
  @terminal_outcomes ~w(success failure cancelled rejected unknown_outcome)
  @future_skew_seconds 300

  defmodule Run do
    @moduledoc false
    use Ecto.Schema

    schema "diagnostics_runs" do
      field :source_id, :string
      field :run_id, :string
      field :parent_run_id, :string
      field :state_event_key, :id
      field :native_revision, :integer
      field :state_occurred_at, :utc_datetime_usec
      field :state_epoch, :string
      field :state_sequence, :integer
      field :phase, :string
      field :outcome, :string
      field :release, :string
      field :workload, :string
      field :deadline_at, :utc_datetime_usec
      field :last_progress_at, :utc_datetime_usec
      field :wait_kind, :string
      field :sampled, :boolean, default: false
      field :truncated, :boolean, default: false
      field :source_gap, :boolean, default: false
      field :clock_skew, :boolean, default: false
      field :first_seen_at, :utc_datetime_usec
      field :last_seen_at, :utc_datetime_usec
    end
  end

  defmodule Observation do
    @moduledoc false
    use Ecto.Schema

    @primary_key false
    schema "diagnostics_run_events" do
      field :run_key, :id, primary_key: true
      field :event_key, :id, primary_key: true
      field :disposition, :string
    end
  end

  def get(source_id, run_id) when is_binary(source_id) and is_binary(run_id),
    do: Repo.get_by(Run, source_id: source_id, run_id: run_id)

  def events(source_id, run_id, opts \\ []) do
    Event
    |> join(:inner, [event], obs in Observation, on: obs.event_key == event.id)
    |> join(:inner, [_, obs], run in Run, on: obs.run_key == run.id)
    |> where([_, _, run], run.source_id == ^source_id and run.run_id == ^run_id)
    |> order_by([event], desc: event.occurred_at, desc: event.id)
    |> limit(^bounded_limit(opts))
    |> select([event, obs], %{event: event, disposition: obs.disposition})
    |> Repo.all()
  end

  @doc false
  def project(%Event{run_id: nil}), do: nil

  def project(%Event{} = event) do
    Repo.insert_all(Run, [new_run(event)],
      on_conflict: :nothing,
      conflict_target: [:source_id, :run_id],
      log: false
    )

    run =
      Run
      |> where([run], run.source_id == ^event.source_id and run.run_id == ^event.run_id)
      |> lock("FOR UPDATE")
      |> Repo.one!()

    {disposition, transition} = transition(run, event)

    Repo.insert_all(
      Observation,
      [%{run_key: run.id, event_key: event.id, disposition: disposition}],
      on_conflict: :nothing,
      conflict_target: [:run_key, :event_key],
      log: false
    )

    run
    |> Ecto.Changeset.change(Map.merge(observed(run, event), transition))
    |> Repo.update!(log: false)
  end

  @doc false
  def related_releases(%Run{workload: workload} = run, before, window_seconds, cap)
      when is_binary(workload) do
    after_time = DateTime.add(before, -window_seconds, :second)

    Run
    |> where(
      [row],
      row.source_id == ^run.source_id and row.workload == ^workload and
        row.state_occurred_at >= ^after_time and row.state_occurred_at <= ^before and
        row.outcome in ["success", "failure"] and not is_nil(row.release)
    )
    |> order_by([row], desc: row.state_occurred_at, desc: row.id)
    |> limit(^cap)
    |> Repo.all()
  end

  def related_releases(_run, _before, _window_seconds, _cap), do: []

  defp transition(_run, %Event{event_type: type}) when type not in @state_events,
    do: {"context", %{}}

  defp transition(run, event) do
    revision = get_in(event.body, ["subject", "revision"])
    next = state_attrs(event, revision)

    case compare(run, event, revision) do
      :older -> {"late", %{}}
      :same -> equal_revision(run, next)
      :newer when not is_nil(run.outcome) and not is_map_key(next, :outcome) -> {"late", %{}}
      :newer -> {"applied", next}
    end
  end

  defp equal_revision(run, fields) do
    comparable =
      Map.take(fields, [
        :phase,
        :outcome,
        :workload,
        :release,
        :deadline_at,
        :last_progress_at,
        :wait_kind
      ])

    if Enum.any?(comparable, fn {field, value} -> Map.get(run, field) not in [nil, value] end) do
      {"conflict", %{}}
    else
      {"corroborated",
       Map.reject(comparable, fn {field, _value} -> not is_nil(Map.get(run, field)) end)}
    end
  end

  defp compare(%Run{state_event_key: nil}, _, _), do: :newer
  defp compare(%Run{native_revision: current}, _, nil) when is_integer(current), do: :older
  defp compare(%Run{native_revision: nil}, _, revision) when is_integer(revision), do: :newer

  defp compare(%Run{native_revision: current}, _, revision)
       when is_integer(current) and is_integer(revision) do
    order(revision, current)
  end

  defp compare(
         %Run{state_epoch: epoch, state_sequence: seq},
         %Event{producer_epoch: epoch} = event,
         nil
       ),
       do: order(event.body["source_sequence"], seq)

  defp compare(run, event, nil) do
    case DateTime.compare(event.occurred_at, run.state_occurred_at) do
      :lt -> :older
      :eq -> order(event.id, run.state_event_key)
      :gt -> :newer
    end
  end

  defp order(value, previous) when value < previous, do: :older
  defp order(value, value), do: :same
  defp order(_, _), do: :newer

  defp state_attrs(event, revision) do
    result = event.body["result"] || %{}

    %{
      state_event_key: event.id,
      state_occurred_at: event.occurred_at,
      state_epoch: event.producer_epoch,
      state_sequence: event.body["source_sequence"],
      native_revision: revision
    }
    |> put_concrete(:phase, result["phase"])
    |> put_concrete(:workload, result["workload"])
    |> put_concrete(:release, event.release)
    |> put_concrete(:deadline_at, timestamp(result["deadline_at"]))
    |> put_concrete(:last_progress_at, timestamp(result["last_progress_at"]))
    |> put_concrete(:wait_kind, result["wait_kind"])
    |> put_concrete(:outcome, terminal_outcome(event, result["outcome"]))
  end

  defp terminal_outcome(%Event{event_type: "run_finished"}, outcome)
       when outcome in @terminal_outcomes,
       do: outcome

  defp terminal_outcome(_, _), do: nil

  defp put_concrete(map, _key, nil), do: map
  defp put_concrete(map, key, value), do: Map.put(map, key, value)

  defp new_run(event) do
    %{
      source_id: event.source_id,
      run_id: event.run_id,
      first_seen_at: event.occurred_at,
      last_seen_at: event.occurred_at
    }
  end

  defp observed(run, event) do
    quality = event.body["quality"] || %{}

    %{
      first_seen_at:
        if(DateTime.before?(event.occurred_at, run.first_seen_at),
          do: event.occurred_at,
          else: run.first_seen_at
        ),
      last_seen_at:
        if(DateTime.after?(event.occurred_at, run.last_seen_at),
          do: event.occurred_at,
          else: run.last_seen_at
        ),
      parent_run_id: run.parent_run_id || get_in(event.body, ["subject", "parent_run_id"]),
      sampled: run.sampled or quality["sampled"] == true,
      truncated: run.truncated or quality["truncated"] == true,
      source_gap:
        run.source_gap or is_integer(quality["source_gap"]) or event.event_type == "source_gap",
      clock_skew:
        run.clock_skew or
          DateTime.diff(event.occurred_at, event.received_at) > @future_skew_seconds
    }
  end

  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, %{microsecond: {microsecond, _}} = timestamp, _} ->
        %{timestamp | microsecond: {microsecond, 6}}

      _ ->
        nil
    end
  end

  defp timestamp(_), do: nil

  defp bounded_limit(opts), do: Keyword.get(opts, :limit, 30) |> max(1) |> min(100)
end

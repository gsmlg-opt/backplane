defmodule Backplane.Diagnostics.Projector do
  @moduledoc "Processes durable diagnostic work with transactional and versioned projection claims."

  use GenServer

  import Ecto.Query

  alias Backplane.Diagnostics.{
    Detectors,
    Findings,
    Issues,
    Occurrences,
    Outbox,
    Resolutions,
    Runs,
    Sources
  }

  alias Backplane.Diagnostics.Events.Event
  alias Backplane.Repo

  @name "diagnostics"
  @version 1
  @related_limit 100
  @context_seconds 900

  defmodule Claim do
    @moduledoc false
    use Ecto.Schema

    @primary_key false
    schema "diagnostics_projection_claims" do
      field :projector, :string, primary_key: true
      field :projector_version, :integer, primary_key: true
      field :source_id, :string, primary_key: true
      field :event_id, :string, primary_key: true
      field :processed_at, :utc_datetime_usec
    end
  end

  defmodule SourceEpoch do
    @moduledoc false
    use Ecto.Schema

    @primary_key false
    schema "diagnostics_projection_sequences" do
      field :source_id, :string, primary_key: true
      field :producer_epoch, :string, primary_key: true
      field :projector_version, :integer, primary_key: true
      field :highest_sequence, :integer
      field :seen, :integer
    end
  end

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @impl true
  def init(opts) do
    state = %{
      interval: Keyword.get(opts, :interval_ms, 1_000),
      policy: Keyword.get(opts, :policy, %{})
    }

    schedule(state)
    {:ok, state}
  end

  @impl true
  def handle_info(:project, state) do
    project_ready(state.policy, 32)
    schedule(state)
    {:noreply, state}
  end

  defp project_ready(_policy, 0), do: :ok

  defp project_ready(policy, remaining) do
    case project_next(policy: policy) do
      {:ok, status} when status in [:processed, :already_processed] ->
        project_ready(policy, remaining - 1)

      _ ->
        :ok
    end
  end

  @doc "Processes one event and clears its outbox entry in the same transaction. Replays are safe."
  def project(event_key, opts \\ []) when is_integer(event_key) do
    Repo.transact(
      fn ->
        entry =
          Repo.one(
            from row in Outbox.Entry, where: row.event_key == ^event_key, lock: "FOR UPDATE"
          )

        case Repo.get(Event, event_key) do
          nil -> {:error, :not_found}
          %Event{historical: true} -> {:ok, :historical}
          event -> project_locked(event, entry, Keyword.get(opts, :policy, %{}))
        end
      end,
      log: false
    )
  end

  @doc "Claims the next ready entry using row-level skip-locked concurrency."
  def project_next(opts \\ []) do
    now = DateTime.utc_now()

    result =
      Repo.transact(
        fn ->
          entry =
            Outbox.Entry
            |> where([row], row.available_at <= ^now)
            |> order_by([row], asc: row.available_at, asc: row.event_key)
            |> limit(1)
            |> lock("FOR UPDATE SKIP LOCKED")
            |> Repo.one()

          if entry do
            try do
              project_locked(
                Repo.get!(Event, entry.event_key),
                entry,
                Keyword.get(opts, :policy, %{})
              )
            rescue
              _error -> Repo.rollback({:projection_failed, entry.event_key})
            end
          else
            {:ok, :empty}
          end
        end,
        log: false
      )

    case result do
      {:error, {:projection_failed, key}} ->
        retry_entry(key, now)
        {:error, :projection_failed}

      other ->
        other
    end
  rescue
    _error in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, :persistence_unavailable}
  end

  @doc "Reports known sequence gaps for a projected source epoch without filling missing events."
  def source_epoch(source_id, producer_epoch) do
    case Repo.get_by(SourceEpoch,
           source_id: source_id,
           producer_epoch: producer_epoch,
           projector_version: @version
         ) do
      %SourceEpoch{} = state ->
        %{
          highest_sequence: state.highest_sequence,
          observed: state.seen,
          missing: state.highest_sequence - state.seen
        }

      nil ->
        nil
    end
  end

  defp project_locked(event, entry, policy) do
    # Acquire the source lock before inserting claims that reference it.
    source =
      Repo.one!(
        from source in Sources.Source,
          where: source.id == ^event.source_id,
          lock: "FOR NO KEY UPDATE"
      )

    {claimed, _} =
      Repo.insert_all(
        Claim,
        [
          %{
            projector: @name,
            projector_version: @version,
            source_id: event.source_id,
            event_id: event.event_id,
            processed_at: DateTime.utc_now()
          }
        ],
        on_conflict: :nothing,
        log: false
      )

    if claimed == 1 do
      observe_sequence(event)
      run = Runs.project(event)
      facts = detector_facts(event, run, source, policy)
      project_findings(event, run, Detectors.evaluate(facts, policy))
      reevaluate_contracts(event, run, source, policy)
    end

    if entry, do: Repo.delete!(entry, log: false)
    {:ok, if(claimed == 1, do: :processed, else: :already_processed)}
  end

  defp observe_sequence(event) do
    if sequence = event.body["source_sequence"] do
      update =
        from row in SourceEpoch,
          update: [
            set: [
              highest_sequence:
                fragment("GREATEST(?, EXCLUDED.highest_sequence)", row.highest_sequence),
              seen: row.seen + 1
            ]
          ]

      Repo.insert_all(
        SourceEpoch,
        [
          %{
            source_id: event.source_id,
            producer_epoch: event.producer_epoch,
            projector_version: @version,
            highest_sequence: sequence,
            seen: 1
          }
        ],
        on_conflict: update,
        conflict_target: [:source_id, :producer_epoch, :projector_version],
        log: false
      )
    end
  end

  defp project_findings(event, run, findings) do
    selected = Enum.find(findings, &(&1.status in ["observed", "candidate"]))

    {occurrence, issue_id} =
      if selected do
        occurrence = Occurrences.observe(event, run, selected)
        {occurrence, Issues.observe(event, occurrence, selected)}
      else
        occurrence =
          if event.event_type in ~w(process_exit service_restart resource_sample log_error crash_artifact) and
               not Detectors.expected?(event) and
               get_in(event.body, ["quality", "origin"]) != "diagnostics" do
            if occurrence = Occurrences.corroborate(event, run) do
              Issues.corroborate(event, occurrence)
              occurrence
            end
          end

        {occurrence, nil}
      end

    Findings.project(event.id, findings, occurrence, selected && selected.rule)
    Resolutions.observe(event, run, issue_id)
  end

  defp reevaluate_contracts(
         %Event{event_type: "run_finished"},
         %Runs.Run{outcome: outcome} = run,
         source,
         policy
       )
       when not is_nil(outcome) do
    pending =
      Event
      |> join(:inner, [event], finding in Findings.Finding, on: finding.event_key == event.id)
      |> where(
        [event, finding],
        event.source_id == ^run.source_id and event.run_id == ^run.run_id and
          finding.rule == "contract_violation" and finding.status == "insufficient_evidence"
      )
      |> order_by([event], desc: event.id)
      |> limit(@related_limit)
      |> Repo.all()

    for event <- pending do
      findings = event |> detector_facts(run, source, policy) |> Detectors.evaluate(policy)

      if findings == [] do
        Repo.delete_all(
          from row in Findings.Finding,
            where: row.event_key == ^event.id and row.rule == "contract_violation"
        )
      else
        project_findings(event, run, findings)
      end
    end
  end

  defp reevaluate_contracts(_event, _run, _source, _policy), do: :ok

  defp detector_facts(event, run, source, policy) do
    related = related_events(event, source, policy)
    sequence = source_epoch(event.source_id, event.producer_epoch)
    child = child_run(event, run)

    %{
      event: event,
      run: run,
      related: related,
      gap: sequence != nil and sequence.missing > 0,
      health: source_health(event, related),
      terminal_event: terminal_event(run),
      child_run: child,
      child_terminal_event: terminal_event(child),
      release_runs: release_runs(event, run, policy)
    }
  end

  defp related_events(%Event{event_type: type} = event, source, policy) do
    {query, seconds} =
      case type do
        "service_restart" ->
          {from(row in Event, where: row.event_type == "service_restart"),
           Map.get(policy, :restart_window_seconds, 600)}

        type when type in ~w(run_waiting run_progress) ->
          {from(row in Event, where: row.event_type == "collector_health"), @context_seconds}

        type when type in ~w(provider_attempt tool_attempt handled_error) ->
          run_id = event.run_id

          if run_id do
            {from(row in Event,
               where:
                 row.run_id == ^run_id or
                   row.event_type in ~w(process_exit resource_sample crash_artifact)
             ), @context_seconds}
          else
            {from(row in Event,
               where: row.event_type in ~w(process_exit resource_sample crash_artifact)
             ), @context_seconds}
          end

        _ ->
          {from(row in Event,
             where: row.event_type in ~w(process_exit resource_sample crash_artifact)
           ), 120}
      end

    from_time = DateTime.add(event.occurred_at, -seconds, :second)
    until_time = DateTime.add(event.occurred_at, 120, :second)

    query
    |> where(
      [row],
      row.id != ^event.id and row.occurred_at >= ^from_time and row.occurred_at <= ^until_time
    )
    |> related_scope(event, source)
    |> order_by([row], desc: row.occurred_at, desc: row.id)
    |> limit(@related_limit)
    |> Repo.all()
  end

  defp related_scope(query, event, %{host_id: host_id}) do
    process = get_in(event.body, ["correlation", "process_instance"])

    if host_id && process do
      query
      |> join(:inner, [row], source in Sources.Source, on: row.source_id == source.id)
      |> where(
        [row, source],
        row.source_id == ^event.source_id or
          (source.host_id == ^host_id and
             row.event_type in ~w(process_exit resource_sample crash_artifact) and
             fragment("? -> 'correlation' ->> 'process_instance'", row.body) == ^process)
      )
    else
      where(query, [row], row.source_id == ^event.source_id)
    end
  end

  defp terminal_event(%Runs.Run{state_event_key: key, outcome: outcome})
       when is_integer(key) and not is_nil(outcome),
       do: Repo.get(Event, key)

  defp terminal_event(_), do: nil

  defp child_run(%Event{event_type: type} = event, %Runs.Run{wait_kind: "child_agent"} = parent)
       when type in ~w(handoff run_waiting) do
    child_id = get_in(event.body, ["subject", "child_run_id"])

    if is_binary(child_id) do
      case Runs.get(event.source_id, child_id) do
        %Runs.Run{parent_run_id: parent_id} = child when parent_id == parent.run_id -> child
        _ -> nil
      end
    end
  end

  defp child_run(_, _), do: nil

  defp source_health(event, related) do
    latest =
      Enum.find(
        related,
        &(&1.event_type == "collector_health" and
            &1.source_id == event.source_id and
            not DateTime.after?(&1.occurred_at, event.occurred_at))
      )

    case latest && latest.body["result"] do
      %{"reason_code" => "disconnected"} -> :disconnected
      %{"outcome" => "success"} -> :healthy
      _ -> :unknown
    end
  end

  defp release_runs(%Event{event_type: "run_finished"} = event, %Runs.Run{} = run, policy),
    do:
      Runs.related_releases(
        run,
        event.occurred_at,
        Map.get(policy, :release_window_seconds, 86_400),
        @related_limit
      )

  defp release_runs(_, _, _), do: []

  defp retry_entry(key, now) do
    Repo.update_all(
      from(row in Outbox.Entry,
        where: row.event_key == ^key,
        update: [
          inc: [attempts: 1],
          set: [
            available_at:
              fragment(
                "? + make_interval(secs => LEAST(3600, 5 * power(2, LEAST(?, 10))))",
                type(^now, :utc_datetime_usec),
                row.attempts
              )
          ]
        ]
      ),
      [],
      log: false
    )
  end

  defp schedule(state), do: Process.send_after(self(), :project, state.interval)
end

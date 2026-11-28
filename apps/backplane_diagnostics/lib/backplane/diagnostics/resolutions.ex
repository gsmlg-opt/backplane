defmodule Backplane.Diagnostics.Resolutions do
  @moduledoc "Auditable fix verification, deployment identity, coverage and recurrence."

  import Ecto.Query
  import Ecto.Changeset

  alias Backplane.Diagnostics.Events.Event
  alias Backplane.Diagnostics.Issues
  alias Backplane.Diagnostics.Issues.Issue
  alias Backplane.Diagnostics.Runs.Run
  alias Backplane.DiagnosticsClient.Redaction
  alias Backplane.Repo

  @test_states ~w(reproduced fixed_in_test failed)
  @implementation_states ~w(proposed implemented merged)
  @issue_states ~w(open triaged fixing observing muted duplicate)
  @terminal_outcomes ~w(success failure cancelled rejected unknown_outcome)

  defmodule Resolution do
    @moduledoc false
    use Ecto.Schema

    schema "diagnostics_resolutions" do
      field :issue_id, :id
      field :repository, :string
      field :fix_sha, :string
      field :fix_reference, :string
      field :change_identity, :string
      field :releases, {:array, :string}
      field :source_ids, {:array, :string}
      field :workload, :string
      field :min_runs, :integer, default: 10
      field :min_seconds, :integer, default: 3600
      field :test_state, :string, default: "not_added"
      field :implementation_state, :string, default: "proposed"
      field :deployment_state, :string, default: "not_observed"
      field :observation_state, :string, default: "insufficient_coverage"
      field :active, :boolean, default: true
      field :activation_at, :utc_datetime_usec
      field :deployed_at, :utc_datetime_usec
      field :recurrence_event_key, :id
      timestamps(type: :utc_datetime_usec)
    end
  end

  defmodule Check do
    @moduledoc false
    use Ecto.Schema

    schema "diagnostics_resolution_checks" do
      field :resolution_id, :id
      field :state, :string
      field :evidence_reference, :string
      field :actor, :string
      field :checked_at, :utc_datetime_usec
    end
  end

  defmodule Observation do
    @moduledoc false
    use Ecto.Schema

    @primary_key false
    schema "diagnostics_resolution_runs" do
      field :resolution_id, :id, primary_key: true
      field :source_id, :string, primary_key: true
      field :run_id, :string, primary_key: true
      field :event_key, :id
      field :outcome, :string
      field :observed_at, :utc_datetime_usec
    end
  end

  defmodule ManagementAction do
    @moduledoc false
    use Ecto.Schema

    schema "diagnostics_management_actions" do
      field :issue_id, :id
      field :entity_id, :id
      field :action, :string
      field :actor, :string
      field :recorded_at, :utc_datetime_usec
    end
  end

  def get(id) when is_integer(id), do: Repo.get(Resolution, id)
  def for_issue(issue_id), do: Repo.get_by(Resolution, issue_id: issue_id, active: true)

  def list do
    Repo.all(from r in Resolution, where: r.active, order_by: [desc: r.updated_at], limit: 50)
  end

  def propose(issue_id, attrs, actor) do
    Repo.transact(
      fn ->
        with %Issue{} <- lock_issue(issue_id),
             {:ok, resolution} <- changeset(issue_id, attrs) |> Repo.insert(log: false) do
          audit!(issue_id, "resolution_proposed", actor, resolution.id)
          {:ok, resolution}
        else
          nil -> {:error, :not_found}
          {:error, _} = error -> error
        end
      end,
      log: false
    )
  end

  def record_check(id, state, evidence, actor)
      when state in @test_states and is_binary(evidence) and byte_size(evidence) in 1..256 do
    modify(id, actor, "resolution_check_" <> state, fn issue, resolution ->
      Repo.insert!(
        %Check{
          resolution_id: id,
          state: state,
          evidence_reference: Redaction.summary(evidence, 256),
          actor: actor,
          checked_at: DateTime.utc_now()
        },
        log: false
      )

      activate(issue, resolution, %{test_state: state})
    end)
  end

  def record_check(_, _, _, _), do: {:error, :invalid_check}

  def implementation(id, state, actor) when state in @implementation_states do
    modify(id, actor, "resolution_implementation_" <> state, fn issue, resolution ->
      activate(issue, resolution, %{implementation_state: state})
    end)
  end

  def implementation(_, _, _), do: {:error, :invalid_state}

  def set_issue_state(issue_id, status, actor) when status in @issue_states do
    Repo.transact(
      fn ->
        case lock_issue(issue_id) do
          nil ->
            {:error, :not_found}

          issue ->
            next = issue |> change(status: status) |> Repo.update!(log: false)
            audit!(issue_id, "issue_" <> status, actor, nil)
            {:ok, next}
        end
      end,
      log: false
    )
  end

  def set_issue_state(_, _, _), do: {:error, :invalid_state}

  @doc "Records the actual terminal run and explicit occurrence identity in the projection transaction."
  def observe(%Event{} = event, run, issue_id) do
    if coverage_fact?(event, run), do: observe_coverage(event, run)
    if is_integer(issue_id), do: observe_recurrence(event, issue_id)
    :ok
  end

  def coverage(id) do
    Repo.one!(
      from row in Observation,
        where: row.resolution_id == ^id,
        select: %{
          runs: count(row.run_id),
          first: min(row.observed_at),
          last: max(row.observed_at),
          healthy: filter(count(row.run_id), row.outcome == "success")
        }
    )
  end

  def audit!(issue_id, action, actor, entity_id)
      when is_binary(actor) and byte_size(actor) in 1..128 do
    Repo.insert!(
      %ManagementAction{
        issue_id: issue_id,
        action: action,
        actor: actor,
        entity_id: entity_id,
        recorded_at: DateTime.utc_now()
      },
      log: false
    )
  end

  defp changeset(issue_id, attrs) do
    %Resolution{issue_id: issue_id}
    |> cast(attrs, [
      :repository,
      :fix_sha,
      :fix_reference,
      :change_identity,
      :releases,
      :source_ids,
      :workload,
      :min_runs,
      :min_seconds
    ])
    |> validate_required([:issue_id, :repository, :releases, :source_ids, :workload])
    |> validate_length(:repository, max: 256, count: :bytes)
    |> validate_length(:fix_reference, max: 256, count: :bytes)
    |> validate_length(:change_identity, max: 128, count: :bytes)
    |> validate_length(:workload, max: 128, count: :bytes)
    |> validate_format(:fix_sha, ~r/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/)
    |> validate_list(:releases)
    |> validate_list(:source_ids)
    |> validate_number(:min_runs, greater_than: 0, less_than_or_equal_to: 10_000)
    |> validate_number(:min_seconds,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 31_536_000
    )
    |> unique_constraint(:issue_id, name: :diagnostics_active_resolution)
  end

  defp validate_list(changeset, field) do
    validate_change(changeset, field, fn _, values ->
      if length(values) in 1..16 and Enum.all?(values, &valid_label?/1),
        do: [],
        else: [{field, "requires 1–16 bounded identifiers"}]
    end)
  end

  defp valid_label?(value),
    do: is_binary(value) and byte_size(value) in 1..128 and Redaction.summary(value, 128) == value

  defp modify(id, actor, action, update) do
    Repo.transact(
      fn ->
        with %Resolution{} = resolution <- get(id),
             %Issue{} = issue <- lock_issue(resolution.issue_id),
             %Resolution{active: true} = current <- lock_resolution(id) do
          next = update.(issue, current)
          audit!(issue.id, action, actor, id)
          {:ok, next}
        else
          _ -> {:error, :not_found}
        end
      end,
      log: false
    )
  end

  defp activate(issue, resolution, delta) do
    updated = struct(resolution, delta)
    ready = eligible?(issue.category, updated)

    fields =
      cond do
        ready and is_nil(resolution.activation_at) ->
          Map.put(delta, :activation_at, DateTime.utc_now())

        not ready ->
          Map.merge(delta, %{
            activation_at: nil,
            deployment_state: "not_observed",
            observation_state: "insufficient_coverage",
            deployed_at: nil
          })

        true ->
          delta
      end

    if not ready,
      do:
        Repo.delete_all(from(row in Observation, where: row.resolution_id == ^resolution.id),
          log: false
        )

    resolution |> change(fields) |> Repo.update!(log: false)
  end

  defp eligible?(
         category,
         %{implementation_state: state, test_state: "fixed_in_test"} = resolution
       )
       when state in ["implemented", "merged"] do
    case category do
      "software_defect" -> is_binary(resolution.fix_sha)
      _ -> is_binary(resolution.change_identity) or is_binary(resolution.fix_sha)
    end
  end

  defp eligible?(_, _), do: false

  defp coverage_fact?(
         %Event{id: key, event_type: "run_finished", release: release, body: %{} = body},
         %Run{
           run_id: run_id,
           workload: workload,
           state_event_key: key,
           source_gap: false,
           clock_skew: false
         }
       )
       when is_binary(run_id) and is_binary(release) and is_binary(workload) do
    quality = body["quality"] || %{}

    body["result"]["outcome"] in @terminal_outcomes and
      not (quality["sampled"] == true or quality["source_gap"] != nil)
  end

  defp coverage_fact?(_, _), do: false

  defp observe_coverage(event, run) do
    candidates =
      Repo.all(
        from r in Resolution,
          where:
            r.active and not is_nil(r.activation_at) and r.workload == ^run.workload and
              fragment("? = ANY(?)", type(^event.release, :string), r.releases) and
              fragment("? = ANY(?)", type(^event.source_id, :string), r.source_ids),
          order_by: r.issue_id,
          limit: 100
      )

    Enum.each(candidates, fn candidate ->
      issue = lock_issue(candidate.issue_id)
      resolution = lock_resolution(candidate.id)

      if applicable?(resolution, event) and resolution.observation_state != "recurred" do
        outcome = get_in(event.body, ["result", "outcome"])
        track_run(resolution, issue, event, run.run_id, outcome)
      end
    end)
  end

  defp track_run(resolution, issue, event, run_id, outcome) do
    {inserted, _} =
      Repo.insert_all(
        Observation,
        [
          %{
            resolution_id: resolution.id,
            source_id: event.source_id,
            run_id: run_id,
            event_key: event.id,
            observed_at: event.occurred_at,
            outcome: outcome
          }
        ],
        on_conflict: :nothing,
        log: false
      )

    if inserted == 1 do
      coverage = coverage(resolution.id)

      healthy =
        coverage.healthy >= resolution.min_runs and coverage.runs == coverage.healthy and
          DateTime.diff(coverage.last, coverage.first, :second) >= resolution.min_seconds

      resolution
      |> change(
        deployed_at: resolution.deployed_at || event.occurred_at,
        deployment_state: "observed_on_source",
        observation_state: if(healthy, do: "healthy_observation", else: "insufficient_coverage")
      )
      |> Repo.update!(log: false)

      if issue.status in ["open", "fixing", "triaged", "observing", "resolved"] do
        issue
        |> change(status: if(healthy, do: "resolved", else: "observing"))
        |> Repo.update!(log: false)
      end
    end
  end

  defp observe_recurrence(event, issue_id) do
    with %Issue{} = issue <- lock_issue(issue_id),
         %Resolution{} = current <- for_issue(issue_id),
         %Resolution{} = resolution <- lock_resolution(current.id),
         true <- applicable?(resolution, event),
         true <- resolution.observation_state != "recurred" do
      resolution
      |> change(
        observation_state: "recurred",
        deployment_state: "observed_on_source",
        deployed_at: resolution.deployed_at || event.occurred_at,
        recurrence_event_key: event.id
      )
      |> Repo.update!(log: false)

      issue |> change(status: "reopened") |> Repo.update!(log: false)
      queue_recurrence(issue_id, event)
    end
  end

  defp applicable?(
         %Resolution{active: true, activation_at: %DateTime{} = activated} = resolution,
         event
       ) do
    event.release in resolution.releases and event.source_id in resolution.source_ids and
      (is_nil(resolution.fix_sha) or event.git_sha == resolution.fix_sha) and
      DateTime.compare(event.occurred_at, activated) != :lt
  end

  defp applicable?(_, _), do: false

  defp queue_recurrence(issue_id, event) do
    Issues.enqueue_change(issue_id, event.id, "reopened", DateTime.utc_now())
  end

  defp lock_issue(id),
    do: Repo.one(from issue in Issue, where: issue.id == ^id, lock: "FOR UPDATE")

  defp lock_resolution(id),
    do: Repo.one(from r in Resolution, where: r.id == ^id, lock: "FOR UPDATE")
end

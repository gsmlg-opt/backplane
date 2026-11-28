defmodule Backplane.Diagnostics.Analyses do
  @moduledoc "Durable, coalesced diagnostic analysis jobs with atomic reservations and expiring claims."

  import Ecto.Query

  alias Backplane.Diagnostics.Analyses.{Output, Policy, Proxy}
  alias Backplane.Diagnostics.{Evidence, RepairTasks}
  alias Backplane.Diagnostics.Reports.Report
  alias Backplane.Repo

  @pending ~w(queued waiting_for_model budget_exhausted retrying)
  @lock_id 2_041_119_802_610_005_000
  @template_version 1
  @max_attempts 3

  defmodule Job do
    @moduledoc false
    use Ecto.Schema

    schema "diagnostics_analyses" do
      field :issue_id, :id
      field :evidence_bundle_id, :id
      field :evidence_digest, :string
      field :policy_version, :integer
      field :template_version, :integer
      field :status, :string
      field :reason, :string
      field :model, :string
      field :result, :map
      field :usage, :map
      field :available_at, :utc_datetime_usec
      field :bypass_cooldown, :boolean, default: false
      field :attempts, :integer, default: 0
      field :lease_token, :string
      field :lease_until, :utc_datetime_usec
      field :started_at, :utc_datetime_usec
      field :finished_at, :utc_datetime_usec
      field :expired_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end
  end

  defmodule Budget do
    @moduledoc false
    use Ecto.Schema

    @primary_key {:day, :date, autogenerate: false}
    schema "diagnostics_analysis_budgets" do
      field :calls, :integer
      field :tokens, :integer
      field :cost_micros, :integer
    end
  end

  @doc "Returns the newest status and separately usable structured output, if any."
  def latest(issue_id) do
    Job
    |> where([job], job.issue_id == ^issue_id)
    |> order_by([job], desc: job.id)
    |> limit(1)
    |> Repo.one(log: false)
  end

  @doc "Counts current work by fixed lifecycle status without reading evidence or model output."
  def health do
    Job
    |> group_by([job], job.status)
    |> select([job], {job.status, count(job.id)})
    |> Repo.all(log: false)
    |> Map.new()
  end

  @doc "Enqueues one immutable evidence/policy combination, coalescing never-started evidence per issue."
  def schedule(%Evidence.Bundle{payload: %{"references" => [_ | _]}} = bundle, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    policy = Policy.load(opts)

    Repo.transact(
      fn ->
        lock_queue!()

        if current_report_bundle?(bundle, opts) do
          case Repo.get_by(Job,
                 issue_id: bundle.issue_id,
                 evidence_digest: bundle.digest,
                 policy_version: policy.version
               ) do
            %Job{} = historical -> {:ok, historical}
            nil -> queue_latest(bundle, policy, opts, now)
          end
        else
          {:ok, :superseded}
        end
      end,
      log: false
    )
  end

  defp current_report_bundle?(bundle, opts) do
    if Keyword.get(opts, :require_current_bundle, false) do
      case Repo.get(Report, bundle.issue_id, log: false) do
        %Report{evidence_bundle_id: id} -> id == bundle.id
        _ -> false
      end
    else
      true
    end
  end

  @doc "Claims at most one job, reserving the maximum allowable usage before any model request."
  def claim(opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    policy = Policy.load(opts)

    Repo.transact(
      fn ->
        lock_queue!()
        expire_claims(now)

        case candidate(now, policy.max_concurrent) do
          nil -> {:ok, :idle}
          job -> check_candidate(job, policy, now)
        end
      end,
      log: false
    )
  end

  @doc "Runs one claimed job through a supervised model call and records only validated output."
  def run_once(opts \\ []) do
    case claim(opts) do
      {:ok, {job, bundle, policy}} ->
        result = run_model(job, bundle, policy, opts)
        now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
        finish(job, bundle, result, now)

      state ->
        state
    end
  end

  defp queue_latest(bundle, policy, opts, now) do
    waiting = pending_query()
    prior = Repo.one(from job in waiting, where: job.issue_id == ^bundle.issue_id, limit: 1)

    if is_nil(prior) and Repo.aggregate(waiting, :count, :id) >= policy.queue_limit do
      {:error, :analysis_queue_full}
    else
      retire_prior(prior, now)

      {:ok,
       Repo.insert!(
         %Job{
           issue_id: bundle.issue_id,
           evidence_bundle_id: bundle.id,
           evidence_digest: bundle.digest,
           policy_version: policy.version,
           template_version: @template_version,
           status: if(policy.model, do: "queued", else: "waiting_for_model"),
           available_at: now,
           bypass_cooldown: Keyword.get(opts, :bypass_cooldown, false)
         },
         log: false
       )}
    end
  end

  defp retire_prior(nil, _now), do: :ok

  defp retire_prior(%Job{attempts: 0} = prior, _now), do: Repo.delete!(prior, log: false)

  defp retire_prior(prior, now), do: update_job(prior, status: "superseded", finished_at: now)

  defp pending_query, do: from(job in Job, where: job.status in @pending)

  defp expire_claims(now) do
    from(job in Job, where: job.status == "running" and job.lease_until <= ^now)
    |> Repo.update_all(
      [
        set: [
          status: "abandoned",
          reason: "lease_expired",
          finished_at: now,
          lease_token: nil,
          lease_until: nil,
          updated_at: now
        ]
      ],
      log: false
    )
  end

  defp candidate(now, maximum) do
    running = from(job in Job, where: job.status == "running")

    if Repo.aggregate(running, :count, :id) < maximum do
      active_issues = from job in running, select: job.issue_id

      pending_query()
      |> where([job], job.available_at <= ^now and job.issue_id not in subquery(active_issues))
      |> order_by([job], asc: job.available_at, asc: job.id)
      |> limit(1)
      |> Repo.one(log: false)
    end
  end

  defp check_candidate(job, policy, now) do
    with {:ok, bundle} <- Evidence.load(job.evidence_bundle_id, now),
         :ok <- current_policy(job, bundle, policy, now),
         :ok <- current_model(policy),
         :ok <- cooldown(job, policy, now),
         :ok <- reserve(policy, now) do
      leased =
        update_job(job,
          status: "running",
          reason: nil,
          model: policy.model,
          attempts: job.attempts + 1,
          started_at: now,
          lease_token: Ecto.UUID.generate(),
          lease_until: DateTime.add(now, policy.timeout_ms + 15_000, :millisecond)
        )

      {:ok, {leased, bundle, policy}}
    else
      {:error, error} when error in [:evidence_expired, :not_found] ->
        {:ok,
         update_job(job, status: "evidence_expired", finished_at: now, reason: "evidence_expired")}

      {:error, :waiting_for_model} ->
        {:ok,
         update_job(job,
           status: "waiting_for_model",
           available_at: DateTime.add(now, 60, :second)
         )}

      {:error, :budget_exhausted} ->
        {:ok,
         update_job(job, status: "budget_exhausted", available_at: DateTime.add(now, 60, :second))}

      {:error, {:cooldown, due}} ->
        {:ok, update_job(job, available_at: due)}

      {:rescheduled, current} ->
        {:ok, current}
    end
  end

  defp current_policy(%Job{policy_version: version}, _bundle, %{version: version}, _now), do: :ok

  defp current_policy(job, bundle, policy, now) do
    old = update_job(job, status: "superseded", reason: "policy_changed", finished_at: now)

    case Repo.get_by(Job,
           issue_id: bundle.issue_id,
           evidence_digest: bundle.digest,
           policy_version: policy.version
         ) do
      nil ->
        case queue_latest(bundle, policy, [bypass_cooldown: job.bypass_cooldown], now) do
          {:ok, current} -> {:rescheduled, current}
          {:error, :analysis_queue_full} -> {:rescheduled, old}
        end

      current ->
        {:rescheduled, current}
    end
  end

  defp current_model(%{model: model}) when is_binary(model), do: :ok
  defp current_model(_), do: {:error, :waiting_for_model}

  defp cooldown(%Job{bypass_cooldown: true}, _policy, _now), do: :ok

  defp cooldown(job, policy, now) do
    since = DateTime.add(now, -policy.cooldown_seconds, :second)

    last =
      Job
      |> where(
        [prior],
        prior.issue_id == ^job.issue_id and prior.id != ^job.id and prior.started_at > ^since
      )
      |> select([prior], max(prior.started_at))
      |> Repo.one(log: false)

    if last,
      do: {:error, {:cooldown, DateTime.add(last, policy.cooldown_seconds, :second)}},
      else: :ok
  end

  defp reserve(policy, now) do
    day = DateTime.to_date(now)

    current =
      Repo.get(Budget, day, log: false) || %Budget{day: day, calls: 0, tokens: 0, cost_micros: 0}

    calls = current.calls + 1
    tokens = current.tokens + policy.max_input_tokens + policy.max_output_tokens
    cost = current.cost_micros + policy.request_cost_micros

    pricing_known = policy.daily_cost_micros == 0 or policy.request_cost_micros > 0

    if pricing_known and calls <= policy.daily_calls and tokens <= policy.daily_tokens and
         (policy.daily_cost_micros == 0 or cost <= policy.daily_cost_micros) do
      Repo.insert!(%Budget{day: day, calls: calls, tokens: tokens, cost_micros: cost},
        on_conflict: [set: [calls: calls, tokens: tokens, cost_micros: cost]],
        conflict_target: [:day],
        log: false
      )

      :ok
    else
      {:error, :budget_exhausted}
    end
  end

  defp run_model(job, bundle, policy, opts) do
    supervisor = Keyword.get(opts, :task_supervisor, Backplane.Diagnostics.Analyses.Tasks)
    model_client = Keyword.get(opts, :model_client, &Proxy.complete/3)

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        safe_complete(model_client, bundle.payload, job.model, policy)
      end)

    case Task.yield(task, policy.timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> {:error, :timed_out}
    end
  catch
    :exit, _reason -> {:error, :worker_unavailable}
  end

  defp safe_complete(client, payload, model, policy) do
    client.(payload, model, policy)
  rescue
    _error -> {:error, :model_unavailable}
  catch
    _kind, _reason -> {:error, :model_unavailable}
  end

  defp finish(job, bundle, result, now) do
    Repo.transact(
      fn ->
        lock_queue!()

        case Repo.get(Job, job.id, log: false) do
          %Job{status: "running", lease_token: lease, lease_until: valid_until} = running
          when lease == job.lease_token ->
            if DateTime.after?(valid_until, now) do
              {:ok, store_result(running, bundle, result, now)}
            else
              {:error, :claim_expired}
            end

          _ ->
            {:error, :claim_expired}
        end
      end,
      log: false
    )
  end

  defp store_result(job, bundle, {:ok, response, raw_usage}, now) do
    usage = Proxy.usage(raw_usage)

    case Output.validate(response, bundle.payload) do
      {:ok, valid} ->
        updated = finish_status(job, now, status: "completed", result: valid, usage: usage)
        RepairTasks.store!(updated, bundle, valid, now)
        updated

      _ ->
        finish_status(job, now,
          status: "analysis_invalid",
          reason: "output_or_reference_invalid",
          usage: usage
        )
    end
  end

  defp store_result(job, _bundle, {:error, :not_dispatched}, now)
       when job.attempts < @max_attempts do
    waiting = from(other in pending_query(), where: other.issue_id == ^job.issue_id)

    if Repo.exists?(waiting) do
      finish_status(job, now, status: "superseded", reason: "newer_evidence")
    else
      update_job(job,
        status: "retrying",
        reason: "model_not_dispatched",
        lease_token: nil,
        lease_until: nil,
        available_at: DateTime.add(now, 60 * job.attempts, :second)
      )
    end
  end

  defp store_result(job, _bundle, {:error, :timed_out}, now),
    do: finish_status(job, now, status: "timed_out", reason: "model_timeout")

  defp store_result(job, _bundle, {:error, :invalid_response}, now),
    do: finish_status(job, now, status: "analysis_invalid", reason: "model_response_invalid")

  defp store_result(job, _bundle, _other, now),
    do: finish_status(job, now, status: "failed", reason: "model_unavailable")

  defp finish_status(job, now, attrs) do
    update_job(job, attrs ++ [finished_at: now, lease_token: nil, lease_until: nil])
  end

  defp update_job(job, attrs),
    do: job |> Ecto.Changeset.change(Map.new(attrs)) |> Repo.update!(log: false)

  defp lock_queue!,
    do: Repo.query!("SELECT pg_advisory_xact_lock($1::bigint)", [@lock_id], log: false)
end

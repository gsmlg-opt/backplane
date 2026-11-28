defmodule Backplane.Diagnostics.Reports do
  @moduledoc "Deterministic per-issue reports, analysis trigger policy and internal notifications."

  alias Backplane.Diagnostics.{Analyses, Evidence}
  alias Backplane.Diagnostics.Events.Event
  alias Backplane.DiagnosticsClient.Redaction
  alias Backplane.Repo

  import Ecto.Query

  @changes ~w(opened severity_increased evidence_added reopened verification_changed manual repeat)
  @notifications ~w(opened severity_increased reopened verification_changed)
  @analysis_triggers ~w(opened severity_increased evidence_added reopened manual)
  @exception_types ~w(exception handled_error worker_exit process_exit log_error crash_artifact)

  defmodule Report do
    @moduledoc false
    use Ecto.Schema

    @primary_key {:issue_id, :id, autogenerate: false}
    schema "diagnostics_reports" do
      field :revision, :integer
      field :change, :string
      field :body, :map
      field :evidence_bundle_id, :id
      timestamps(type: :utc_datetime_usec)
    end
  end

  defmodule Notification do
    @moduledoc false
    use Ecto.Schema

    schema "diagnostics_notification_candidates" do
      field :issue_id, :id
      field :report_revision, :integer
      field :kind, :string
      field :inserted_at, :utc_datetime_usec
    end
  end

  def get(issue_id) do
    case Repo.get(Report, issue_id, log: false) do
      %Report{evidence_bundle_id: bundle} = report when is_integer(bundle) ->
        if Evidence.expired?(bundle) do
          body =
            report.body
            |> put_in(["quality", "evidence_available"], false)
            |> put_in(["quality", "evidence_expired"], true)

          %{report | body: body}
        else
          report
        end

      report ->
        report
    end
  end

  @doc "Refreshes a trusted projection snapshot and preserves its monotonic report revision."
  def refresh(%{id: issue_id} = issue, opts \\ []) when is_integer(issue_id) and issue_id > 0 do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    revision = Keyword.get(opts, :revision, 1)
    change = opts |> Keyword.get(:change, :opened) |> normalize_change()

    issue =
      Map.update(issue, :events, [], fn events ->
        events |> Enum.take(30) |> Enum.reject(&diagnostics_origin?/1)
      end)

    with {:ok, {report, bundle}} <- upsert(issue, revision, change, now, opts) do
      {:ok, with_analysis_state(report, maybe_schedule(issue, bundle, change, opts))}
    end
  end

  defp upsert(issue, revision, change, now, opts) do
    Repo.transact(
      fn ->
        Repo.query!(
          "SELECT pg_advisory_xact_lock(hashtextextended('diagnostics-report:' || $1::bigint::text, 0))",
          [issue.id],
          log: false
        )

        prior = Repo.get(Report, issue.id, log: false)

        cond do
          prior && prior.revision > revision ->
            {:ok, {prior, nil}}

          prior && prior.revision == revision ->
            {:ok, {prior, read_bundle(prior, now)}}

          true ->
            refresh_report(issue, prior, revision, change, now, opts)
        end
      end,
      log: false
    )
  end

  defp refresh_report(issue, prior, revision, change, now, opts) do
    with {:ok, bundle} <- bundle_for(issue, prior, change, now, opts) do
      body = deterministic(issue, bundle)

      report = %Report{
        issue_id: issue.id,
        revision: revision,
        change: change,
        body: body,
        evidence_bundle_id: if(bundle, do: bundle.id, else: prior && prior.evidence_bundle_id),
        inserted_at: now,
        updated_at: now
      }

      stored =
        Repo.insert!(report,
          on_conflict: {:replace, [:revision, :change, :body, :evidence_bundle_id, :updated_at]},
          conflict_target: [:issue_id],
          returning: true,
          log: false
        )

      notify(stored, now)
      {:ok, {stored, bundle}}
    end
  end

  defp bundle_for(_issue, %Report{} = prior, "repeat", now, _opts) do
    {:ok, read_bundle(prior, now)}
  end

  defp bundle_for(issue, _prior, _change, _now, opts), do: Evidence.freeze(issue, opts)

  defp read_bundle(%Report{evidence_bundle_id: nil}, _now), do: nil

  defp read_bundle(report, now) do
    case Evidence.load(report.evidence_bundle_id, now) do
      {:ok, bundle} -> bundle
      {:error, _} -> nil
    end
  end

  defp deterministic(issue, bundle) do
    counts = Map.get(issue, :counts, %{})

    body = %{
      "issue_id" => issue.id,
      "severity" => bounded_text(issue[:severity]),
      "category" => bounded_text(issue[:category]),
      "status" => bounded_text(issue[:status]),
      "events" => count(counts[:events]),
      "occurrences" => count(counts[:occurrences]),
      "affected_runs" => count(counts[:runs]),
      "evidence_ids" => (bundle && Enum.map(bundle.payload["references"], & &1["id"])) || [],
      "quality" => quality(issue.events, bundle)
    }

    if summary = issue[:summary], do: Map.put(body, "summary", bounded_text(summary)), else: body
  end

  defp quality(events, bundle) do
    %{
      "evidence_available" => not is_nil(bundle) and bundle.payload["references"] != [],
      "source_gaps" =>
        Enum.any?(events, fn event ->
          get_in(event.body, ["quality", "source_gap"]) not in [nil, 0]
        end),
      "truncated" =>
        Enum.any?(events, fn event -> get_in(event.body, ["quality", "truncated"]) == true end)
    }
  end

  defp notify(%Report{change: change} = report, now) when change in @notifications do
    Repo.insert!(
      %Notification{
        issue_id: report.issue_id,
        report_revision: report.revision,
        kind: change,
        inserted_at: now
      },
      on_conflict: :nothing,
      conflict_target: [:issue_id, :report_revision, :kind],
      log: false
    )
  end

  defp notify(_report, _now), do: :ok

  defp maybe_schedule(
         issue,
         %Evidence.Bundle{payload: %{"references" => [_ | _]}} = bundle,
         change,
         opts
       )
       when change in @analysis_triggers do
    if change == "manual" or eligible?(issue) do
      Analyses.schedule(
        bundle,
        Keyword.merge(opts,
          require_current_bundle: true,
          bypass_cooldown: change in ~w(severity_increased reopened manual)
        )
      )
    end
  end

  defp maybe_schedule(_, _, _, _), do: :ok

  defp with_analysis_state(report, {:error, :analysis_queue_full}) do
    body = Map.put(report.body, "analysis_queue_state", "queue_full")

    from(row in Report,
      where: row.issue_id == ^report.issue_id and row.revision == ^report.revision
    )
    |> Repo.update_all([set: [body: body]], log: false)

    %{report | body: body}
  end

  defp with_analysis_state(report, _queued), do: report

  defp eligible?(issue) do
    issue[:confirmed_contract_violation] == true or
      (bounded_text(issue[:severity]) in ~w(high critical) and
         Enum.any?(issue.events, &(&1.event_type in @exception_types)))
  end

  defp diagnostics_origin?(%Event{body: body}),
    do: get_in(body, ["quality", "origin"]) == "diagnostics"

  defp normalize_change(value) do
    value = bounded_text(value)
    if value in @changes, do: value, else: "repeat"
  end

  defp bounded_text(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp bounded_text(value) when is_binary(value), do: Redaction.summary(value, 256)
  defp bounded_text(_), do: nil

  defp count(value) when is_integer(value) and value >= 0, do: value
  defp count(_), do: 0
end

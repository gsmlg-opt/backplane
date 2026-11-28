defmodule Backplane.Diagnostics.Queries do
  @moduledoc "Bounded diagnostics read models shared by the Admin and MCP surfaces."

  alias Backplane.Diagnostics.{Analyses, Evidence, Issues, RepairTasks, Reports, Runs}

  @issue_fields ~w(id fingerprint fingerprint_version category severity status occurrence_count first_seen_at last_seen_at)a
  @run_fields ~w(source_id run_id parent_run_id native_revision phase outcome release workload deadline_at last_progress_at wait_kind sampled truncated source_gap clock_skew first_seen_at last_seen_at)a
  @event_fields ~w(source_id event_id event_type run_id attempt_id trace_id release git_sha error_class occurred_at received_at)a
  @filter_fields ~w(status severity category)a

  def search_issues(params) when is_map(params) do
    limit =
      case params["limit"] do
        value when is_integer(value) and value in 1..50 -> value
        _ -> 20
      end

    with {:ok, cursor} <- parse_cursor(params["cursor"]) do
      filters =
        for field <- @filter_fields,
            value = params[Atom.to_string(field)],
            is_binary(value),
            byte_size(value) <= 64,
            do: {field, value}

      issues = Issues.list([limit: limit + 1, before: cursor] ++ filters)
      {page, extra} = Enum.split(issues, limit)
      next_cursor = if extra != [], do: to_cursor(List.last(page))
      {:ok, %{"issues" => Enum.map(page, &summary(&1, @issue_fields)), "cursor" => next_cursor}}
    end
  end

  def get_issue(value) do
    with {:ok, id} <- parse_id(value),
         %Issues.Issue{} = issue <- Issues.get(id) do
      observations = Issues.events(id, limit: 10)

      {:ok,
       Map.merge(summary(issue, @issue_fields), %{
         "counts" => Issues.counts(id),
         "observations" => Enum.map(observations, &event_summary/1)
       })}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def get_run(source, run)
      when is_binary(source) and is_binary(run) and byte_size(source) in 1..128 and
             byte_size(run) in 1..128 do
    case Runs.get(source, run) do
      %Runs.Run{} = record ->
        events = Runs.events(source, run, limit: 20)

        {:ok,
         Map.put(
           summary(record, @run_fields),
           "observations",
           Enum.map(events, fn observation ->
             Map.put(event_summary(observation.event), "disposition", observation.disposition)
           end)
         )}

      nil ->
        {:error, :not_found}
    end
  end

  def get_run(_, _), do: {:error, :invalid_reference}

  def get_evidence(bundle, reference) do
    with {:ok, id} <- parse_id(bundle), do: Evidence.fetch(id, reference)
  end

  def get_report(issue) do
    with {:ok, id} <- parse_id(issue) do
      case Reports.get(id) do
        nil -> {:error, :not_found}
        {:ok, report} -> {:ok, report_summary(report, id)}
        {:error, _} = error -> error
        report -> {:ok, report_summary(report, id)}
      end
    end
  end

  def parse_id(value) when is_integer(value) and value in 1..9_223_372_036_854_775_807,
    do: {:ok, value}

  def parse_id(value) when is_binary(value) and byte_size(value) in 1..19 do
    case Integer.parse(value) do
      {number, ""} -> parse_id(number)
      _ -> {:error, :invalid_reference}
    end
  end

  def parse_id(_), do: {:error, :invalid_reference}

  defp event_summary(event) do
    summary(event, @event_fields)
    |> Map.put(
      "evidence_availability",
      if(get_in(event.body || %{}, ["quality", "evidence_expired"]) || is_nil(event.body),
        do: "expired",
        else: "available"
      )
    )
  end

  defp report_summary(report, id) do
    analysis = Analyses.latest(id)
    repair = RepairTasks.get(id)

    report
    |> summary(~w(issue_id revision change evidence_bundle_id body updated_at)a)
    |> Map.put(
      "analysis",
      if(analysis, do: summary(analysis, ~w(status reason model updated_at)a))
    )
    |> Map.put("repair_task", if(repair, do: summary(repair, ~w(body expired_at)a)))
  end

  defp summary(map, fields),
    do: Map.new(Map.take(map, fields), fn {key, value} -> {Atom.to_string(key), value} end)

  defp to_cursor(issue) do
    Base.url_encode64(
      DateTime.to_iso8601(issue.last_seen_at) <> "@" <> Integer.to_string(issue.id),
      padding: false
    )
  end

  defp parse_cursor(nil), do: {:ok, nil}

  defp parse_cursor(value) when is_binary(value) and byte_size(value) <= 128 do
    with {:ok, bytes} <- Base.url_decode64(value, padding: false),
         [date, id] <- String.split(bytes, "@", parts: 2),
         {:ok, observed, _} <- DateTime.from_iso8601(date),
         {:ok, id} <- parse_id(id) do
      {:ok, {observed, id}}
    else
      _ -> {:error, :invalid_cursor}
    end
  end

  defp parse_cursor(_), do: {:error, :invalid_cursor}
end

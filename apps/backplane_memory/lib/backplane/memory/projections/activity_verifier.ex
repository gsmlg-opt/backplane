defmodule Backplane.Memory.Projections.ActivityVerifier do
  @moduledoc "Direct canonical-event consistency checks and repair for daily activity."

  alias Backplane.Memory.{Audit, Config}
  alias Backplane.Memory.Projections.{ActivityStore, Rebuild}

  @drift_limit 1_000
  @repair_page_size 100
  @counter_names ~w(event_count session_count memory_count lesson_count crystal_count recall_count action_count error_count)

  def verify(opts) when is_list(opts) do
    with {:ok, opts} <- options(opts) do
      rows = repo().query!(verification_sql(), verification_params(opts)).rows

      drift = Enum.map(rows, &drift_row/1)

      drift_count =
        case rows do
          [[count | _rest] | _] -> count
          [] -> 0
        end

      {:ok,
       %{
         status: if(drift_count == 0, do: :consistent, else: :drift),
         drift_count: drift_count,
         drift_truncated: drift_count > @drift_limit,
         drift: drift
       }}
    end
  end

  def verify(_opts), do: {:error, :invalid_options}

  def repair(opts) when is_list(opts) do
    with {:ok, normalized} <- options(opts),
         {:ok, repaired} <- repair_pages(normalized, nil, 0),
         {:ok, cleanup} <- cleanup_orphans(normalized),
         {:ok, verification} <- verify(normalized_to_keyword(normalized)) do
      {:ok, Map.merge(cleanup, %{repaired_subjects: repaired, verification: verification})}
    end
  end

  def repair(_opts), do: {:error, :invalid_options}

  defp verification_sql do
    counters = Enum.join(@counter_names, ", ")

    differences =
      Enum.map_join(@counter_names, " OR ", &"expected.#{&1} IS DISTINCT FROM actual.#{&1}")

    """
    WITH expected AS (
      SELECT (event.occurred_at AT TIME ZONE 'UTC')::date AS date,
             COALESCE(event.project, '') AS project,
             COALESCE(event.agent_id, '') AS agent_id,
             event.host_id,
             event.client_id,
             event.scope,
             event.namespace,
             event.event_type,
             count(*)::bigint AS event_count,
             count(DISTINCT NULLIF(event.session_id, ''))::bigint AS session_count,
             count(*) FILTER (
               WHERE event.event_type LIKE 'memory.%' AND event.event_type <> 'memory.recalled'
             )::bigint AS memory_count,
             count(*) FILTER (WHERE event.event_type LIKE 'lesson.%')::bigint AS lesson_count,
             count(*) FILTER (WHERE event.event_type LIKE 'crystal.%')::bigint AS crystal_count,
             count(*) FILTER (WHERE event.event_type = 'memory.recalled')::bigint AS recall_count,
             count(*) FILTER (
               WHERE event.event_type LIKE 'action.%' OR event.event_type LIKE 'task.%'
             )::bigint AS action_count,
             count(*) FILTER (
               WHERE event.event_type IN ('agent.tool.failed', 'tool.call.failed', 'agent.run.failed')
                  OR event.status = 'failed'
                  OR event.payload->'source'->>'is_error' = 'true'
             )::bigint AS error_count
      FROM bpm_events AS event
      WHERE event.schema_version IS NOT NULL
        AND ($6::text IS NULL OR event.host_id = $6)
        AND event.client_id = $1
        AND event.scope = $2
        AND event.namespace = $3
        AND event.occurred_at >= $4::date
        AND event.occurred_at < ($5::date + INTERVAL '1 day')
      GROUP BY 1, 2, 3, 4, 5, 6, 7, 8
    ), actual AS (
      SELECT date, project, agent_id, host_id, client_id, scope, namespace, event_type,
             #{counters}
      FROM memory_activity_daily
      WHERE client_id = $1 AND scope = $2 AND namespace = $3
        AND ($6::text IS NULL OR host_id = $6)
        AND date >= $4::date AND date <= $5::date
    ), drift AS (
      SELECT COALESCE(expected.date, actual.date) AS date,
             COALESCE(expected.project, actual.project) AS project,
             COALESCE(expected.agent_id, actual.agent_id) AS agent_id,
             COALESCE(expected.host_id, actual.host_id) AS host_id,
             COALESCE(expected.client_id, actual.client_id) AS client_id,
             COALESCE(expected.scope, actual.scope) AS scope,
             COALESCE(expected.namespace, actual.namespace) AS namespace,
             COALESCE(expected.event_type, actual.event_type) AS event_type,
             #{Enum.map_join(@counter_names, ", ", &"expected.#{&1} AS expected_#{&1}")},
             #{Enum.map_join(@counter_names, ", ", &"actual.#{&1} AS actual_#{&1}")}
      FROM expected
      FULL OUTER JOIN actual USING (date, project, agent_id, host_id, client_id, scope, namespace, event_type)
      WHERE #{differences}
    )
    SELECT count(*) OVER()::bigint AS drift_count, drift.*
    FROM drift
    ORDER BY date, project, agent_id, host_id, event_type
    LIMIT #{@drift_limit}
    """
  end

  defp drift_row([
         _count,
         date,
         project,
         agent_id,
         host_id,
         client_id,
         scope,
         namespace,
         event_type
         | counters
       ]) do
    {expected, actual} = Enum.split(counters, length(@counter_names))

    %{
      date: date,
      project: project,
      agent_id: agent_id,
      host_id: host_id,
      client_id: client_id,
      scope: scope,
      namespace: namespace,
      event_type: event_type,
      expected: counter_map(expected),
      actual: counter_map(actual)
    }
  end

  defp counter_map(values),
    do: Map.new(Enum.zip(Enum.map(@counter_names, &String.to_atom/1), values))

  defp repair_pages(opts, cursor, repaired) do
    rows = repo().query!(repair_subjects_sql(), repair_params(opts, cursor)).rows

    with {:ok, repaired} <- rebuild_rows(rows, repaired) do
      case List.last(rows) do
        [host_id, session_id] when length(rows) == @repair_page_size ->
          repair_pages(opts, {host_id, session_id}, repaired)

        _last ->
          {:ok, repaired}
      end
    end
  end

  defp rebuild_rows(rows, repaired) do
    Enum.reduce_while(rows, {:ok, repaired}, fn [host_id, session_id], {:ok, count} ->
      case Rebuild.session(host_id, session_id) do
        {:ok, _result} ->
          {:cont, {:ok, count + 1}}

        {:error, reason} ->
          {:halt, {:error, %{host_id: host_id, session_id: session_id, reason: reason}}}
      end
    end)
  end

  defp cleanup_orphans(opts) do
    repo().transaction(fn ->
      repo().query!(
        "LOCK TABLE memory_activity_subject_contributions, memory_activity_daily " <>
          "IN SHARE ROW EXCLUSIVE MODE"
      )

      contributions = repo().query!(delete_orphan_contributions_sql(), verification_params(opts))
      :ok = ActivityStore.recompute_keys!(Enum.map(contributions.rows, &List.to_tuple/1))
      daily = repo().query!(delete_orphan_daily_sql(), verification_params(opts))

      cleanup = %{
        orphan_contributions_removed: contributions.num_rows,
        orphan_daily_removed: daily.num_rows
      }

      :ok =
        Audit.log(
          "activity.repair",
          "system",
          %{
            "client_id" => opts.client_id,
            "scope" => opts.scope,
            "namespace" => opts.namespace
          },
          Map.merge(cleanup, %{
            date_from: Date.to_iso8601(opts.date_from),
            date_to: Date.to_iso8601(opts.date_to),
            bounded: true
          })
        )

      cleanup
    end)
  end

  defp delete_orphan_contributions_sql do
    """
    DELETE FROM memory_activity_subject_contributions AS contribution
    WHERE contribution.client_id = $1
      AND contribution.scope = $2
      AND contribution.namespace = $3
      AND ($6::text IS NULL OR contribution.host_id = $6)
      AND contribution.date >= $4::date
      AND contribution.date <= $5::date
      AND NOT EXISTS (
        SELECT 1
        FROM bpm_projected_sessions AS session
        JOIN bpm_events AS event
          ON event.host_id = session.host_id
         AND event.session_id = session.session_id
        WHERE session.subject_id = contribution.subject_id
          AND event.schema_version IS NOT NULL
          AND (event.occurred_at AT TIME ZONE 'UTC')::date = contribution.date
          AND COALESCE(event.project, '') = contribution.project
          AND COALESCE(event.agent_id, '') = contribution.agent_id
          AND event.host_id = contribution.host_id
          AND event.client_id = contribution.client_id
          AND event.scope = contribution.scope
          AND event.namespace = contribution.namespace
          AND event.event_type = contribution.event_type
        GROUP BY session.subject_id
        HAVING count(*)::bigint = contribution.event_count
           AND count(DISTINCT NULLIF(event.session_id, ''))::bigint = contribution.session_count
           AND count(*) FILTER (
                 WHERE event.event_type LIKE 'memory.%'
                   AND event.event_type <> 'memory.recalled'
               )::bigint = contribution.memory_count
           AND count(*) FILTER (WHERE event.event_type LIKE 'lesson.%')::bigint = contribution.lesson_count
           AND count(*) FILTER (WHERE event.event_type LIKE 'crystal.%')::bigint = contribution.crystal_count
           AND count(*) FILTER (WHERE event.event_type = 'memory.recalled')::bigint = contribution.recall_count
           AND count(*) FILTER (
                 WHERE event.event_type LIKE 'action.%' OR event.event_type LIKE 'task.%'
               )::bigint = contribution.action_count
           AND count(*) FILTER (
                 WHERE event.event_type IN ('agent.tool.failed', 'tool.call.failed', 'agent.run.failed')
                    OR event.status = 'failed'
                    OR event.payload->'source'->>'is_error' = 'true'
               )::bigint = contribution.error_count
      )
    RETURNING date, project, agent_id, host_id, client_id, scope, namespace, event_type
    """
  end

  defp delete_orphan_daily_sql do
    """
    DELETE FROM memory_activity_daily AS daily
    WHERE daily.client_id = $1
      AND daily.scope = $2
      AND daily.namespace = $3
      AND ($6::text IS NULL OR daily.host_id = $6)
      AND daily.date >= $4::date
      AND daily.date <= $5::date
      AND NOT EXISTS (
        SELECT 1
        FROM memory_activity_subject_contributions AS contribution
        WHERE contribution.date = daily.date
          AND contribution.project = daily.project
          AND contribution.agent_id = daily.agent_id
          AND contribution.host_id = daily.host_id
          AND contribution.client_id = daily.client_id
          AND contribution.scope = daily.scope
          AND contribution.namespace = daily.namespace
          AND contribution.event_type = daily.event_type
      )
    """
  end

  defp repair_subjects_sql do
    """
    SELECT event.host_id, event.session_id
    FROM bpm_events AS event
    WHERE event.schema_version IS NOT NULL
      AND event.client_id = $1
      AND event.scope = $2
      AND event.namespace = $3
      AND ($6::text IS NULL OR event.host_id = $6)
      AND event.occurred_at >= $4::date
      AND event.occurred_at < ($5::date + INTERVAL '1 day')
      AND ($7::text IS NULL OR event.host_id > $7
           OR (event.host_id = $7 AND event.session_id > $8))
    GROUP BY event.host_id, event.session_id
    ORDER BY event.host_id, event.session_id
    LIMIT #{@repair_page_size}
    """
  end

  defp options(opts) do
    allowed = [:host_id, :client_id, :scope, :namespace, :date_from, :date_to]
    today = Date.utc_today()
    window = Config.activity_retention_days()

    if Keyword.keyword?(opts) and Enum.all?(Keyword.keys(opts), &(&1 in allowed)) do
      with {:ok, host_id} <- optional_identifier(Keyword.get(opts, :host_id)),
           {:ok, client_id} <- identifier(Keyword.get(opts, :client_id)),
           {:ok, scope} <- identifier(Keyword.get(opts, :scope)),
           {:ok, namespace} <- identifier(Keyword.get(opts, :namespace)),
           {:ok, date_from} <- date(Keyword.get(opts, :date_from, Date.add(today, 1 - window))),
           {:ok, date_to} <- date(Keyword.get(opts, :date_to, today)),
           true <- Date.compare(date_from, date_to) in [:lt, :eq],
           true <- Date.diff(date_to, date_from) < window do
        {:ok,
         %{
           host_id: host_id,
           client_id: client_id,
           scope: scope,
           namespace: namespace,
           date_from: date_from,
           date_to: date_to
         }}
      else
        _invalid -> {:error, :invalid_options}
      end
    else
      {:error, :invalid_options}
    end
  end

  defp identifier(value) when is_binary(value) do
    if String.trim(value) == "", do: {:error, :invalid_identifier}, else: {:ok, value}
  end

  defp identifier(_value), do: {:error, :invalid_identifier}
  defp optional_identifier(nil), do: {:ok, nil}
  defp optional_identifier(value), do: identifier(value)
  defp date(%Date{} = date), do: {:ok, date}

  defp date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, :invalid_date}
    end
  end

  defp date(_value), do: {:error, :invalid_date}

  defp verification_params(opts),
    do: [opts.client_id, opts.scope, opts.namespace, opts.date_from, opts.date_to, opts.host_id]

  defp repair_params(opts, nil), do: verification_params(opts) ++ [nil, nil]

  defp repair_params(opts, {host_id, session_id}),
    do: verification_params(opts) ++ [host_id, session_id]

  defp normalized_to_keyword(opts), do: Map.to_list(opts)
  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)
end

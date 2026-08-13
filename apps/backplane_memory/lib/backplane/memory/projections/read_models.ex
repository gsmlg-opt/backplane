defmodule Backplane.Memory.Projections.ReadModels do
  @moduledoc """
  Bounded production reads over the canonical captured-session projections.

  Session snapshots and indexed observation rows are the read models. Projection
  state is joined so callers can distinguish complete, pending, and failed output.
  Every response is capped at 100 rows and offset 10,000. Pattern aggregation is
  additionally bounded to the 10,000 most recent eligible observation rows.
  """

  import Ecto.Query

  alias Backplane.Memory.Config
  alias Backplane.Memory.Projections.{ActivityDaily, ProjectedObservation, Snapshot, State}

  @subject_type "captured_session"
  @default_session_limit 20
  @default_timeline_limit 50
  @default_pattern_limit 10
  @max_limit 100
  @max_offset 10_000
  @pattern_candidate_limit 10_000
  @default_activity_limit 1_000
  @max_activity_limit 10_000

  @doc "Returns bounded, revision-aligned canonical input for one session summary."
  def summary_input(host_id, session_id, opts \\ [])

  def summary_input(host_id, session_id, opts)
      when is_binary(host_id) and is_binary(session_id) and is_list(opts) do
    with :ok <- required_identifier(host_id, :invalid_host_id),
         :ok <- required_identifier(session_id, :invalid_session_id),
         {:ok, summary_opts} <- summary_options(opts),
         {:ok, session} <- summary_session(host_id, session_id),
         :ok <- complete_summary_session(session, summary_opts.allow_incomplete),
         {:ok, observations, errors} <-
           summary_observations(session, summary_opts.limit, summary_opts.allow_incomplete) do
      model = session.read_model
      gaps = model["gaps"] || []

      {:ok,
       %{
         subject_id: session.subject_id,
         host_id: model["host_id"],
         session_id: model["session_id"],
         project: model["project"] || "",
         agent_id: model["agent_id"],
         status: model["status"],
         started_at: datetime(model["started_at"]),
         ended_at: datetime(model["ended_at"]),
         last_event_at: datetime(model["last_event_at"]),
         source_complete: gaps == [],
         source_gaps: gaps,
         processing_status: session.state_status,
         counts: model["counts"] || %{},
         input_revision: session.input_revision,
         session_output_revision: session.output_revision,
         observations: observations,
         errors: errors
       }}
    end
  end

  def summary_input(_host_id, _session_id, _opts), do: {:error, :invalid_options}

  def sessions(opts \\ [])

  def sessions(opts) when is_list(opts) do
    with {:ok, opts} <-
           options(opts, @default_session_limit, [
             :project,
             :host_id,
             :client_id,
             :scope,
             :namespace,
             :session_id,
             :active
           ]) do
      query =
        Snapshot
        |> projection_query("session")
        |> session_filters(opts)
        |> order_by(
          [snapshot, _state],
          desc: fragment("COALESCE(?->>'started_at', '')", snapshot.read_model),
          asc: fragment("?->>'host_id'", snapshot.read_model),
          asc: fragment("?->>'session_id'", snapshot.read_model),
          asc: snapshot.subject_id
        )
        |> limit(^opts.limit)
        |> offset(^opts.offset)
        |> select([snapshot, state], %{
          subject_id: snapshot.subject_id,
          read_model: snapshot.read_model,
          processing_status: state.status,
          processing_version: state.processing_version,
          input_revision: state.input_revision,
          output_revision: state.output_revision,
          snapshot_input_revision: snapshot.input_revision,
          snapshot_output_revision: snapshot.output_revision,
          attempt_count: state.attempt_count,
          last_error: state.last_error
        })

      {:ok, query |> repo().all() |> Enum.map(&session_result/1)}
    end
  end

  def sessions(_opts), do: {:error, :invalid_options}

  def active_sessions(opts \\ [])

  def active_sessions(opts) when is_list(opts) do
    sessions(Keyword.put(opts, :active, true))
  end

  def active_sessions(_opts), do: {:error, :invalid_options}

  def timeline(opts \\ [])

  def timeline(opts) when is_list(opts) do
    with {:ok, opts} <-
           options(opts, @default_timeline_limit, [
             :project,
             :session_id,
             :host_id,
             :client_id,
             :scope,
             :namespace,
             :event_type,
             :tool_name,
             :minimum_importance,
             :is_error,
             :file_path,
             :occurred_from,
             :occurred_to
           ]) do
      query =
        ProjectedObservation
        |> observation_projection_query()
        |> observation_subject_filters(opts)
        |> observation_filters(opts)
        |> order_by(
          [observation, _state, _snapshot],
          asc: observation.occurred_at,
          asc: observation.host_id,
          asc: observation.session_id,
          asc_nulls_last: observation.source_sequence,
          asc: observation.event_type,
          asc: observation.event_id,
          asc: observation.subject_id
        )
        |> limit(^opts.limit)
        |> offset(^opts.offset)
        |> select([observation, state, snapshot], %{
          subject_id: observation.subject_id,
          host_id: observation.host_id,
          client_id: observation.client_id,
          scope: observation.scope,
          namespace: observation.namespace,
          session_id: observation.session_id,
          observation: %{
            "event_id" => observation.event_id,
            "source_sequence" => observation.source_sequence,
            "event_type" => observation.event_type,
            "occurred_at" => observation.occurred_at,
            "tool_name" => observation.tool_name,
            "importance" => observation.importance,
            "content" => observation.content,
            "message" => observation.message,
            "is_error" => observation.is_error,
            "file_paths" => observation.file_paths,
            "commit_hash" => observation.commit_hash
          },
          processing_status: state.status,
          processing_version: state.processing_version,
          input_revision: state.input_revision,
          output_revision: state.output_revision,
          snapshot_input_revision: snapshot.input_revision,
          snapshot_output_revision: snapshot.output_revision,
          attempt_count: state.attempt_count,
          last_error: state.last_error
        })

      {:ok, query |> repo().all() |> timeline_results()}
    end
  end

  def timeline(_opts), do: {:error, :invalid_options}

  def patterns(opts \\ [])

  def patterns(opts) when is_list(opts) do
    with {:ok, opts} <-
           options(opts, @default_pattern_limit, [
             :project,
             :session_id,
             :host_id,
             :client_id,
             :scope,
             :namespace
           ]) do
      query =
        opts
        |> pattern_candidates()
        |> subquery()
        |> group_by([candidate], candidate.tool_name)
        |> order_by([candidate], desc: count(), asc: candidate.tool_name)
        |> limit(^opts.limit)
        |> offset(^opts.offset)
        |> select([candidate], %{
          tool_name: candidate.tool_name,
          count: count()
        })

      {:ok, repo().all(query)}
    end
  end

  def patterns(_opts), do: {:error, :invalid_options}

  @doc "Returns bounded durable activity for one exact authorized host partition."
  def activity(opts \\ [])

  def activity(opts) when is_list(opts) do
    with {:ok, opts} <- activity_options(opts) do
      query =
        ActivityDaily
        |> where(
          [activity],
          activity.client_id == ^opts.client_id and activity.scope == ^opts.scope and
            activity.namespace == ^opts.namespace and activity.date >= ^opts.date_from and
            activity.date <= ^opts.date_to
        )
        |> maybe_activity_filter(:project, opts.project)
        |> maybe_activity_filter(:agent_id, opts.agent_id)
        |> where([activity], activity.host_id == ^opts.host_id)
        |> maybe_activity_filter(:event_type, opts.event_type)
        |> order_by(
          [activity],
          desc: activity.date,
          asc: activity.project,
          asc: activity.agent_id,
          asc: activity.host_id,
          asc: activity.event_type,
          asc: activity.client_id,
          asc: activity.scope,
          asc: activity.namespace
        )
        |> limit(^opts.limit)
        |> offset(^opts.offset)
        |> select([activity], %{
          date: activity.date,
          project: activity.project,
          agent_id: activity.agent_id,
          host_id: activity.host_id,
          client_id: activity.client_id,
          scope: activity.scope,
          namespace: activity.namespace,
          event_type: activity.event_type,
          event_count: activity.event_count,
          session_count: activity.session_count,
          memory_count: activity.memory_count,
          lesson_count: activity.lesson_count,
          crystal_count: activity.crystal_count,
          recall_count: activity.recall_count,
          action_count: activity.action_count,
          error_count: activity.error_count
        })

      {:ok, repo().all(query)}
    end
  end

  def activity(_opts), do: {:error, :invalid_options}

  defp activity_options(opts) do
    allowed = [
      :client_id,
      :scope,
      :namespace,
      :date_from,
      :date_to,
      :project,
      :agent_id,
      :host_id,
      :event_type,
      :limit,
      :offset
    ]

    today = Date.utc_today()
    window_days = Config.activity_retention_days()

    if Keyword.keyword?(opts) and Enum.all?(Keyword.keys(opts), &(&1 in allowed)) do
      with {:ok, date_from} <-
             optional_date(Keyword.get(opts, :date_from, Date.add(today, 1 - window_days))),
           {:ok, date_to} <- optional_date(Keyword.get(opts, :date_to, today)) do
        normalized = %{
          client_id: Keyword.get(opts, :client_id),
          scope: Keyword.get(opts, :scope),
          namespace: Keyword.get(opts, :namespace),
          date_from: date_from,
          date_to: date_to,
          project: Keyword.get(opts, :project),
          agent_id: Keyword.get(opts, :agent_id),
          host_id: Keyword.get(opts, :host_id),
          event_type: Keyword.get(opts, :event_type),
          limit: Keyword.get(opts, :limit, @default_activity_limit),
          offset: Keyword.get(opts, :offset, 0)
        }

        if valid_activity_options?(normalized, window_days),
          do: {:ok, normalized},
          else: {:error, :invalid_options}
      else
        _invalid -> {:error, :invalid_options}
      end
    else
      {:error, :invalid_options}
    end
  end

  defp valid_activity_options?(opts, window_days) do
    Enum.all?(
      [opts.host_id, opts.client_id, opts.scope, opts.namespace],
      &valid_required_identifier?/1
    ) and
      Enum.all?(
        [opts.project, opts.agent_id, opts.event_type],
        &valid_optional_identifier?/1
      ) and
      is_integer(opts.limit) and opts.limit in 1..@max_activity_limit and
      is_integer(opts.offset) and opts.offset in 0..@max_offset and
      Date.compare(opts.date_from, opts.date_to) in [:lt, :eq] and
      Date.diff(opts.date_to, opts.date_from) < window_days
  end

  defp optional_date(%Date{} = date), do: {:ok, date}

  defp optional_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, :invalid_date}
    end
  end

  defp optional_date(_value), do: {:error, :invalid_date}

  defp valid_required_identifier?(value) when is_binary(value), do: String.trim(value) != ""
  defp valid_required_identifier?(_value), do: false

  defp maybe_activity_filter(query, _field, nil), do: query

  defp maybe_activity_filter(query, field_name, value) do
    where(query, [activity], field(activity, ^field_name) == ^value)
  end

  defp summary_options(opts) do
    if Keyword.keyword?(opts) and
         Enum.all?(Keyword.keys(opts), &(&1 in [:limit, :allow_incomplete])) do
      case Keyword.get(opts, :limit, 20) do
        limit when is_integer(limit) and limit in 1..@max_limit ->
          allow_incomplete = Keyword.get(opts, :allow_incomplete, false)

          if is_boolean(allow_incomplete) do
            {:ok, %{limit: limit, allow_incomplete: allow_incomplete}}
          else
            {:error, :invalid_options}
          end

        _invalid ->
          {:error, :invalid_options}
      end
    else
      {:error, :invalid_options}
    end
  end

  defp required_identifier(value, error) do
    if String.trim(value) == "", do: {:error, error}, else: :ok
  end

  defp summary_session(host_id, session_id) do
    query =
      from(snapshot in Snapshot,
        join: state in State,
        on:
          state.projector == "session" and state.subject_type == ^@subject_type and
            state.subject_id == snapshot.subject_id,
        where:
          snapshot.projector == "session" and snapshot.subject_type == ^@subject_type and
            fragment("?->>'host_id'", snapshot.read_model) == ^host_id and
            fragment("?->>'session_id'", snapshot.read_model) == ^session_id,
        select: %{
          subject_id: snapshot.subject_id,
          read_model: fragment("? - 'source_event_ids'", snapshot.read_model),
          input_revision: state.input_revision,
          output_revision: state.output_revision,
          state_status: state.status,
          snapshot_input_revision: snapshot.input_revision,
          snapshot_output_revision: snapshot.output_revision
        }
      )

    case repo().one(query) do
      nil -> {:error, :not_found}
      session -> {:ok, session}
    end
  end

  defp complete_summary_session(session, allow_incomplete) do
    model = session.read_model
    acceptable_statuses = if allow_incomplete, do: ["complete", "pending"], else: ["complete"]

    cond do
      session.state_status not in acceptable_statuses ->
        {:error, :projection_incomplete}

      session.input_revision != session.snapshot_input_revision or
          session.output_revision != session.snapshot_output_revision ->
        {:error, :projection_incomplete}

      not allow_incomplete and model["gaps"] not in [nil, []] ->
        {:error, :projection_incomplete}

      model["status"] not in ["completed", "stopped", "abandoned"] ->
        {:error, :session_not_closed}

      true ->
        :ok
    end
  end

  defp summary_observations(session, limit, allow_incomplete) do
    acceptable_statuses = if allow_incomplete, do: ["complete", "pending"], else: ["complete"]

    base =
      from(observation in ProjectedObservation,
        join: state in State,
        on:
          state.projector == "observations" and state.subject_type == ^@subject_type and
            state.subject_id == observation.subject_id,
        join: snapshot in Snapshot,
        on:
          snapshot.projector == "observations" and snapshot.subject_type == ^@subject_type and
            snapshot.subject_id == observation.subject_id,
        where:
          observation.subject_id == ^session.subject_id and state.status in ^acceptable_statuses and
            state.input_revision == ^session.input_revision and
            observation.input_revision == state.input_revision and
            snapshot.input_revision == state.input_revision and
            snapshot.output_revision == state.output_revision and not is_nil(observation.content),
        order_by: [
          desc: observation.importance,
          asc: observation.occurred_at,
          asc_nulls_last: observation.source_sequence,
          asc: observation.event_id
        ],
        select: %{
          event_id: observation.event_id,
          source_sequence: observation.source_sequence,
          event_type: observation.event_type,
          occurred_at: observation.occurred_at,
          tool_name: observation.tool_name,
          content: observation.content,
          message: observation.message,
          importance: observation.importance,
          file_paths: observation.file_paths,
          commit_hash: observation.commit_hash
        }
      )

    observations =
      base
      |> where([observation], not observation.is_error)
      |> limit(^limit)
      |> repo().all()

    errors =
      base
      |> where([observation], observation.is_error)
      |> limit(^limit)
      |> repo().all()

    if observation_projection_aligned?(
         session.subject_id,
         session.input_revision,
         acceptable_statuses
       ) do
      {:ok, observations, errors}
    else
      {:error, :projection_incomplete}
    end
  end

  defp observation_projection_aligned?(subject_id, input_revision, acceptable_statuses) do
    repo().exists?(
      from(state in State,
        join: snapshot in Snapshot,
        on:
          snapshot.projector == "observations" and snapshot.subject_type == ^@subject_type and
            snapshot.subject_id == state.subject_id,
        where:
          state.projector == "observations" and state.subject_type == ^@subject_type and
            state.subject_id == ^subject_id and state.status in ^acceptable_statuses and
            state.input_revision == ^input_revision and
            snapshot.input_revision == state.input_revision and
            snapshot.output_revision == state.output_revision
      )
    )
  end

  defp projection_query(query, projector) do
    from(snapshot in query,
      join: state in State,
      on:
        state.projector == snapshot.projector and state.subject_type == snapshot.subject_type and
          state.subject_id == snapshot.subject_id,
      where: snapshot.projector == ^projector and snapshot.subject_type == @subject_type
    )
  end

  defp observation_projection_query(query) do
    from(observation in query,
      join: state in State,
      on:
        state.projector == "observations" and state.subject_type == ^@subject_type and
          state.subject_id == observation.subject_id,
      join: snapshot in Snapshot,
      on:
        snapshot.projector == "observations" and snapshot.subject_type == ^@subject_type and
          snapshot.subject_id == observation.subject_id
    )
  end

  defp pattern_candidates(opts) do
    ProjectedObservation
    |> observation_projection_query()
    |> observation_subject_filters(opts)
    |> where(
      [observation, state, snapshot],
      state.status == "complete" and state.input_revision == observation.input_revision and
        snapshot.input_revision == state.input_revision and
        snapshot.output_revision == state.output_revision and not is_nil(observation.tool_name) and
        observation.tool_name != ""
    )
    |> order_by([observation], desc: observation.occurred_at, desc: observation.event_id)
    |> limit(^@pattern_candidate_limit)
    |> select([observation], %{tool_name: observation.tool_name})
  end

  defp session_filters(query, opts) do
    query
    |> require_json_partition()
    |> maybe_json_filter(:project, opts.project)
    |> maybe_json_filter(:host_id, opts.host_id)
    |> maybe_json_filter(:client_id, opts.client_id)
    |> maybe_json_filter(:scope, opts.scope)
    |> maybe_json_filter(:namespace, opts.namespace)
    |> maybe_json_filter(:session_id, opts.session_id)
    |> maybe_active_filter(opts.active)
  end

  defp observation_subject_filters(query, opts) do
    query
    |> require_observation_partition()
    |> maybe_observation_subject_filter(:project, opts.project)
    |> maybe_observation_subject_filter(:session_id, opts.session_id)
    |> maybe_observation_subject_filter(:host_id, opts.host_id)
    |> maybe_observation_subject_filter(:client_id, opts.client_id)
    |> maybe_observation_subject_filter(:scope, opts.scope)
    |> maybe_observation_subject_filter(:namespace, opts.namespace)
  end

  defp maybe_observation_subject_filter(query, _field, nil), do: query

  defp maybe_observation_subject_filter(query, field, value) do
    where(query, [observation], field(observation, ^field) == ^value)
  end

  defp observation_filters(query, opts) do
    query
    |> maybe_observation_string_filter(:event_type, opts.event_type)
    |> maybe_observation_string_filter(:tool_name, opts.tool_name)
    |> maybe_minimum_importance(opts.minimum_importance)
    |> maybe_error_filter(opts.is_error)
    |> maybe_file_filter(opts.file_path)
    |> maybe_occurred_from(opts.occurred_from)
    |> maybe_occurred_to(opts.occurred_to)
  end

  defp maybe_json_filter(query, _field, nil), do: query

  defp maybe_json_filter(query, :project, value) do
    where(query, [snapshot, _state], fragment("?->>'project'", snapshot.read_model) == ^value)
  end

  defp maybe_json_filter(query, :host_id, value) do
    where(query, [snapshot, _state], fragment("?->>'host_id'", snapshot.read_model) == ^value)
  end

  defp maybe_json_filter(query, :client_id, value) do
    where(query, [snapshot, _state], fragment("?->>'client_id'", snapshot.read_model) == ^value)
  end

  defp maybe_json_filter(query, :scope, value) do
    where(query, [snapshot, _state], fragment("?->>'scope'", snapshot.read_model) == ^value)
  end

  defp maybe_json_filter(query, :namespace, value) do
    where(query, [snapshot, _state], fragment("?->>'namespace'", snapshot.read_model) == ^value)
  end

  defp maybe_json_filter(query, :session_id, value) do
    where(query, [snapshot, _state], fragment("?->>'session_id'", snapshot.read_model) == ^value)
  end

  defp maybe_observation_string_filter(query, _field, nil), do: query

  defp maybe_observation_string_filter(query, :event_type, value) do
    where(query, [observation], observation.event_type == ^value)
  end

  defp maybe_observation_string_filter(query, :tool_name, value) do
    where(query, [observation], observation.tool_name == ^value)
  end

  defp maybe_minimum_importance(query, nil), do: query

  defp maybe_minimum_importance(query, value) do
    where(query, [observation], observation.importance >= ^value)
  end

  defp maybe_error_filter(query, nil), do: query

  defp maybe_error_filter(query, value) do
    where(query, [observation], observation.is_error == ^value)
  end

  defp maybe_file_filter(query, nil), do: query

  defp maybe_file_filter(query, value) do
    where(query, [observation], fragment("? = ANY(?)", ^value, observation.file_paths))
  end

  defp maybe_occurred_from(query, nil), do: query

  defp maybe_occurred_from(query, value) do
    where(query, [observation], observation.occurred_at >= ^value)
  end

  defp maybe_occurred_to(query, nil), do: query

  defp maybe_occurred_to(query, value) do
    where(query, [observation], observation.occurred_at <= ^value)
  end

  defp maybe_active_filter(query, true) do
    where(query, [snapshot, _state], fragment("?->>'status'", snapshot.read_model) == "active")
  end

  defp maybe_active_filter(query, false), do: query

  defp options(opts, default_limit, allowed) do
    allowed = [:limit, :offset | allowed]

    if Keyword.keyword?(opts) and Enum.all?(Keyword.keys(opts), &(&1 in allowed)) do
      normalized = %{
        limit: Keyword.get(opts, :limit, default_limit),
        offset: Keyword.get(opts, :offset, 0),
        project: Keyword.get(opts, :project),
        host_id: Keyword.get(opts, :host_id),
        client_id: Keyword.get(opts, :client_id),
        scope: Keyword.get(opts, :scope),
        namespace: Keyword.get(opts, :namespace),
        session_id: Keyword.get(opts, :session_id),
        active: Keyword.get(opts, :active, false),
        event_type: Keyword.get(opts, :event_type),
        tool_name: Keyword.get(opts, :tool_name),
        minimum_importance: Keyword.get(opts, :minimum_importance),
        is_error: Keyword.get(opts, :is_error),
        file_path: Keyword.get(opts, :file_path),
        occurred_from: Keyword.get(opts, :occurred_from),
        occurred_to: Keyword.get(opts, :occurred_to)
      }

      with {:ok, normalized} <- normalize_times(normalized),
           true <- valid_options?(normalized) do
        {:ok, normalized}
      else
        _invalid -> {:error, :invalid_options}
      end
    else
      {:error, :invalid_options}
    end
  end

  defp valid_options?(opts) do
    is_integer(opts.limit) and opts.limit in 1..@max_limit and is_integer(opts.offset) and
      opts.offset in 0..@max_offset and valid_optional_identifier?(opts.project) and
      valid_optional_identifier?(opts.host_id) and valid_optional_identifier?(opts.session_id) and
      valid_optional_identifier?(opts.client_id) and valid_optional_identifier?(opts.scope) and
      valid_optional_identifier?(opts.namespace) and
      valid_optional_identifier?(opts.event_type) and
      valid_optional_identifier?(opts.tool_name) and
      valid_optional_identifier?(opts.file_path) and
      valid_optional_integer?(opts.minimum_importance) and
      valid_optional_boolean?(opts.is_error) and is_boolean(opts.active) and
      valid_time_range?(opts)
  end

  defp require_json_partition(query) do
    where(
      query,
      [snapshot, _state],
      fragment("COALESCE(?->>'host_id', '') <> ''", snapshot.read_model) and
        fragment("COALESCE(?->>'client_id', '') <> ''", snapshot.read_model) and
        fragment("COALESCE(?->>'scope', '') <> ''", snapshot.read_model) and
        fragment("COALESCE(?->>'namespace', '') <> ''", snapshot.read_model)
    )
  end

  defp require_observation_partition(query) do
    where(
      query,
      [observation],
      not is_nil(observation.host_id) and not is_nil(observation.client_id) and
        not is_nil(observation.scope) and not is_nil(observation.namespace)
    )
  end

  defp valid_optional_integer?(nil), do: true

  defp valid_optional_integer?(value),
    do: is_integer(value) and value >= -2_147_483_648 and value <= 2_147_483_647

  defp valid_optional_boolean?(nil), do: true
  defp valid_optional_boolean?(value), do: is_boolean(value)

  defp normalize_times(opts) do
    with {:ok, occurred_from} <- optional_datetime(opts.occurred_from),
         {:ok, occurred_to} <- optional_datetime(opts.occurred_to) do
      {:ok, %{opts | occurred_from: occurred_from, occurred_to: occurred_to}}
    end
  end

  defp optional_datetime(nil), do: {:ok, nil}

  defp optional_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, parsed, _offset} -> {:ok, DateTime.shift_zone!(parsed, "Etc/UTC")}
      {:error, _reason} -> {:error, :invalid_time}
    end
  end

  defp optional_datetime(_value), do: {:error, :invalid_time}

  defp valid_time_range?(%{occurred_from: nil}), do: true
  defp valid_time_range?(%{occurred_to: nil}), do: true

  defp valid_time_range?(opts),
    do: DateTime.compare(opts.occurred_from, opts.occurred_to) in [:lt, :eq]

  defp valid_optional_identifier?(nil), do: true

  defp valid_optional_identifier?(value) when is_binary(value),
    do: String.trim(value) != ""

  defp valid_optional_identifier?(_value), do: false

  defp session_result(row) do
    model = row.read_model

    %{
      subject_id: row.subject_id,
      host_id: model["host_id"],
      session_id: model["session_id"],
      project: model["project"],
      agent_id: model["agent_id"],
      status: model["status"],
      observation_count: get_in(model, ["counts", "events"]) || 0,
      started_at: datetime(model["started_at"]),
      ended_at: datetime(model["ended_at"]),
      processing_status: row.processing_status,
      processing_version: row.processing_version,
      input_revision: row.input_revision,
      output_revision: row.output_revision,
      snapshot_input_revision: row.snapshot_input_revision,
      snapshot_output_revision: row.snapshot_output_revision,
      stale: stale?(row),
      attempt_count: row.attempt_count,
      last_error: row.last_error,
      gaps: model["gaps"] || []
    }
  end

  defp timeline_results(rows) do
    {subjects, subject_order} =
      Enum.reduce(rows, {%{}, []}, fn row, {subjects, subject_order} ->
        subject_id = row.subject_id

        case subjects do
          %{^subject_id => subject} ->
            updated = %{
              subject
              | observations: [observation_result(row) | subject.observations]
            }

            {Map.put(subjects, subject_id, updated), subject_order}

          %{} ->
            subject = %{
              subject_id: row.subject_id,
              host_id: row.host_id,
              session_id: row.session_id,
              processing_status: row.processing_status,
              processing_version: row.processing_version,
              input_revision: row.input_revision,
              output_revision: row.output_revision,
              snapshot_input_revision: row.snapshot_input_revision,
              snapshot_output_revision: row.snapshot_output_revision,
              stale: stale?(row),
              attempt_count: row.attempt_count,
              last_error: row.last_error,
              observations: [observation_result(row)]
            }

            {Map.put(subjects, subject_id, subject), [subject_id | subject_order]}
        end
      end)

    subject_order
    |> Enum.reverse()
    |> Enum.map(fn subject_id ->
      subjects |> Map.fetch!(subject_id) |> Map.update!(:observations, &Enum.reverse/1)
    end)
  end

  defp observation_result(row) do
    observation = row.observation

    %{
      id: observation["event_id"],
      event_id: observation["event_id"],
      source_sequence: observation["source_sequence"],
      event_type: observation["event_type"],
      session_id: row.session_id,
      tool_name: observation["tool_name"],
      importance: observation["importance"] || 0,
      content: observation["content"],
      message: observation["message"],
      is_error: observation["is_error"] || false,
      created_at: datetime(observation["occurred_at"]),
      occurred_at: datetime(observation["occurred_at"]),
      file_paths: observation["file_paths"] || [],
      commit_hash: observation["commit_hash"]
    }
  end

  defp datetime(nil), do: nil
  defp datetime(%DateTime{} = value), do: value

  defp datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, parsed, _offset} -> parsed
      {:error, _reason} -> value
    end
  end

  defp datetime(value), do: value

  defp stale?(row) do
    row.processing_status != "complete" or row.input_revision != row.snapshot_input_revision or
      row.output_revision != row.snapshot_output_revision
  end

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)
end

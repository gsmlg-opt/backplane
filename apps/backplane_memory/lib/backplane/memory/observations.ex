defmodule Backplane.Memory.Observations do
  import Ecto.Query
  alias Backplane.Memory.Events.Store
  alias Backplane.Memory.Observations.{Observation, Session}
  alias Backplane.Memory.Privacy.Filter
  alias Backplane.Memory.Config
  alias Backplane.Memory.Workers.SummaryWorker

  @event_opt_keys [
    :event_type,
    :payload,
    :stream_id,
    :project,
    :agent_id,
    :host_id,
    :client_id,
    :run_id,
    :correlation_id,
    :causation_id,
    :occurred_at,
    :idempotency_key
  ]

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)

  @doc "Record an observation, applying privacy filter. Returns {:ok, obs} or {:error, reason}."
  def record(session_id, content, opts \\ []) do
    if Config.dual_write?() do
      record_with_event(session_id, content, opts)
    else
      record_legacy(session_id, content, opts)
    end
  end

  defp record_legacy(session_id, content, opts) do
    with {:ok, filtered} <- Filter.apply(content) do
      filtered
      |> observation_attrs(session_id, opts)
      |> then(&Observation.changeset(%Observation{}, &1))
      |> repo().insert()
    end
  end

  defp record_with_event(session_id, content, opts) do
    observation_id = Ecto.UUID.generate()
    event_attrs = event_attrs(session_id, observation_id, content, opts)

    Ecto.Multi.new()
    |> Store.append_multi(:event, event_attrs)
    |> Ecto.Multi.run(:observation, fn repo, %{event: event_result} ->
      case event_result do
        {:inserted, event} ->
          event.content
          |> observation_attrs(session_id, opts)
          |> then(&Observation.changeset(%Observation{id: observation_id}, &1))
          |> repo.insert()

        {:duplicate, event} ->
          load_linked_observation(repo, event)
      end
    end)
    |> transact_record()
  end

  defp transact_record(multi) do
    case repo().transaction(multi) do
      {:ok, %{event: event_result, observation: observation}} ->
        Store.emit_result({:ok, event_result})
        {:ok, observation}

      {:error, :event, {:idempotency_race, _marker} = race, _changes} ->
        resolve_record_race(race)

      {:error, :event, reason, _changes} ->
        {:error, reason}

      {:error, :observation, %Ecto.Changeset{} = changeset, _changes} ->
        {:error, changeset}

      {:error, :observation, reason, _changes} ->
        {:error, reason}
    end
  end

  defp resolve_record_race(race) do
    with {:ok, {:duplicate, event} = event_result} <-
           Store.resolve_idempotency_race(race, repo: repo()),
         {:ok, observation} <- load_linked_observation(repo(), event) do
      Store.emit_result({:ok, event_result})
      {:ok, observation}
    end
  end

  defp load_linked_observation(repo, event) do
    with id when is_binary(id) <-
           get_in(event.payload || %{}, ["_backplane", "legacy_observation_id"]),
         {:ok, id} <- Ecto.UUID.cast(id),
         %Observation{} = observation <- repo.get(Observation, id) do
      {:ok, observation}
    else
      _ -> {:error, :idempotency_conflict}
    end
  end

  defp observation_attrs(filtered, session_id, opts) do
    filtered = normalize_content(filtered)

    %{
      session_id: session_id,
      tool_name: opts[:tool_name],
      content: filtered,
      is_error: opts[:is_error] || false,
      files: %{"paths" => extract_files(filtered)}
    }
  end

  defp event_attrs(session_id, observation_id, content, opts) do
    tool_name = opts[:tool_name]
    is_error = event_is_error(opts[:is_error])

    event_type =
      opts[:event_type] ||
        fallback_event_type(tool_name, is_error)

    payload =
      if Keyword.has_key?(opts, :payload),
        do: opts[:payload],
        else: %{"paths" => extract_files(normalize_content(content))}

    base = %{
      session_id: session_id,
      event_type: event_type,
      actor_type: "system",
      role: "system",
      status: if(is_error, do: "error", else: "ok"),
      tool_name: tool_name,
      content: content,
      payload: put_observation_link(payload, observation_id)
    }

    option_attrs =
      opts
      |> Keyword.take(@event_opt_keys -- [:event_type, :payload])
      |> Map.new()

    Map.merge(base, option_attrs)
  end

  defp event_is_error(value) do
    case Ecto.Type.cast(:boolean, value || false) do
      {:ok, true} -> true
      _ -> false
    end
  end

  defp normalize_content(content) when is_binary(content), do: content
  defp normalize_content(_content), do: ""

  defp put_observation_link(payload, observation_id)
       when is_map(payload) and not is_struct(payload) do
    link = %{"legacy_observation_id" => observation_id}

    payload
    |> Map.delete(:_backplane)
    |> Map.update("_backplane", link, fn
      existing when is_map(existing) -> Map.merge(existing, link)
      _existing -> link
    end)
  end

  defp put_observation_link(payload, _observation_id), do: payload

  defp fallback_event_type(tool_name, is_error)
       when is_binary(tool_name) and byte_size(tool_name) > 0,
       do: if(is_error, do: "tool.call.failed", else: "tool.call.completed")

  defp fallback_event_type(_tool_name, _is_error), do: "legacy.observation"

  @doc "Register/upsert a session."
  def register_session(session_id, project) do
    if Config.dual_write?() do
      case register_session_with_event(session_id, project, 1) do
        {:ok, session, event_result} ->
          if event_result, do: Store.emit_result({:ok, event_result})
          {:ok, session}

        {:error, reason} ->
          {:error, reason}
      end
    else
      session_id
      |> session_changeset(project)
      |> repo().insert(on_conflict: :nothing, conflict_target: [:session_id])
    end
  end

  defp register_session_with_event(session_id, project, attempts_left) do
    multi =
      Ecto.Multi.new()
      |> Ecto.Multi.run(:session, fn repo, _changes ->
        preexisting? = repo.exists?(from(s in Session, where: s.session_id == ^session_id))

        case repo.insert(session_changeset(session_id, project),
               on_conflict: :nothing,
               conflict_target: [:session_id]
             ) do
          {:ok, session} -> {:ok, {session, not preexisting?}}
          {:error, reason} -> {:error, reason}
        end
      end)
      |> Ecto.Multi.merge(fn
        %{session: {session, true}} ->
          Store.append_multi(
            Ecto.Multi.new(),
            :event,
            lifecycle_event_attrs("session.started", session)
          )

        %{session: {_session, false}} ->
          Ecto.Multi.new()
      end)

    case repo().transaction(multi) do
      {:ok, %{session: {session, _new?}} = changes} ->
        {:ok, session, Map.get(changes, :event)}

      {:error, :event, {:idempotency_race, _marker} = race, _changes}
      when attempts_left > 0 ->
        with {:ok, {:duplicate, _event} = resolved} <-
               Store.resolve_idempotency_race(race, repo: repo()),
             {:ok, session, retried} <-
               register_session_with_event(session_id, project, attempts_left - 1) do
          {:ok, session, retried || resolved}
        end

      {:error, _operation, reason, _changes} ->
        {:error, reason}
    end
  end

  defp session_changeset(session_id, project) do
    Session.changeset(%Session{}, %{
      session_id: session_id,
      project: project,
      started_at: DateTime.utc_now()
    })
  end

  @doc "Mark a session as ended and enqueue consolidation."
  def end_session(session_id) do
    if Config.dual_write?() do
      case end_session_with_event(session_id, 1) do
        {:ok, result, event_result} ->
          if event_result, do: Store.emit_result({:ok, event_result})
          maybe_enqueue_summary(result, session_id)
          result

        {:error, reason} ->
          {:error, reason}
      end
    else
      result = transition_session(session_id)
      maybe_enqueue_summary(result, session_id)
      result
    end
  end

  defp end_session_with_event(session_id, attempts_left) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    multi =
      Ecto.Multi.new()
      |> Ecto.Multi.update_all(
        :session_transition,
        from(s in Session, where: s.session_id == ^session_id and is_nil(s.ended_at)),
        set: [ended_at: now]
      )
      |> Ecto.Multi.one(:session, from(s in Session, where: s.session_id == ^session_id))
      |> Ecto.Multi.merge(fn
        %{session_transition: {1, nil}, session: %Session{} = session} ->
          Ecto.Multi.new()
          |> Store.append_multi(:event, lifecycle_event_attrs("session.ended", session))
          |> Ecto.Multi.run(:closed_stream, fn repo, _changes ->
            Store.close_stream("session:" <> session.session_id, repo: repo)
          end)

        %{session_transition: {0, nil}} ->
          Ecto.Multi.new()
      end)

    case repo().transaction(multi) do
      {:ok, %{session_transition: {count, nil}} = changes} ->
        {:ok, {count, nil}, Map.get(changes, :event)}

      {:error, :event, {:idempotency_race, _marker} = race, _changes}
      when attempts_left > 0 ->
        with {:ok, {:duplicate, _event} = resolved} <-
               Store.resolve_idempotency_race(race, repo: repo()),
             {:ok, result, retried} <-
               end_session_with_event(session_id, attempts_left - 1) do
          {:ok, result, retried || resolved}
        end

      {:error, _operation, reason, _changes} ->
        {:error, reason}
    end
  end

  defp transition_session(session_id) do
    repo().update_all(
      from(s in Session, where: s.session_id == ^session_id and is_nil(s.ended_at)),
      set: [ended_at: DateTime.utc_now()]
    )
  end

  defp maybe_enqueue_summary({count, nil}, session_id) when count > 0 do
    SummaryWorker.enqueue(session_id)
    :ok
  end

  defp maybe_enqueue_summary(_result, _session_id), do: :ok

  defp lifecycle_event_attrs(type, session) do
    %{
      stream_id: "session:" <> session.session_id,
      session_id: session.session_id,
      project: session.project,
      event_type: type,
      actor_type: "system",
      role: "system",
      status: "ok",
      idempotency_key: type <> ":" <> session.session_id
    }
  end

  @doc "Return observations referencing any of the listed file paths, newest first."
  def file_history(file_paths, opts \\ []) when is_list(file_paths) do
    exclude_session = opts[:exclude_session]
    limit = opts[:limit] || 50

    query =
      from(o in Observation,
        where:
          fragment(
            "EXISTS (SELECT 1 FROM jsonb_array_elements_text(?->'paths') AS p WHERE p = ANY(?))",
            o.files,
            ^file_paths
          ),
        order_by: [desc: o.created_at],
        limit: ^limit
      )

    query =
      if exclude_session do
        where(query, [o], o.session_id != ^exclude_session)
      else
        query
      end

    repo().all(query)
  end

  # Extract file paths from content using simple heuristics
  defp extract_files(content) do
    Regex.scan(
      ~r{(?:^|[\s"'`(])(/[^\s"'`)\n]+\.\w+|[a-zA-Z0-9_./\-]+/[a-zA-Z0-9_./\-]+\.\w+)},
      content
    )
    |> Enum.map(fn [_, path] -> String.trim(path) end)
    |> Enum.uniq()
    |> Enum.take(20)
  end
end

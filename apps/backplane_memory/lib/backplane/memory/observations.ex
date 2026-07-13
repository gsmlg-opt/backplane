defmodule Backplane.Memory.Observations do
  import Ecto.Query
  alias Backplane.Memory.Observations.{Observation, Session}
  alias Backplane.Memory.Privacy.Filter
  alias Backplane.Memory.{Config, Events}

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)

  @doc "Record an observation, applying privacy filter. Returns {:ok, obs} or {:error, reason}."
  def record(session_id, content, opts \\ []) do
    with {:ok, filtered} <- Filter.apply(content) do
      files = extract_files(filtered)

      attrs = %{
        session_id: session_id,
        tool_name: opts[:tool_name],
        content: filtered,
        is_error: opts[:is_error] || false,
        files: %{"paths" => files}
      }

      persist(attrs)
    end
  end

  defp persist(attrs) do
    if Config.dual_write?() do
      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.insert(:observation, Observation.changeset(%Observation{}, attrs))
        |> Ecto.Multi.run(:event, fn repo, %{observation: observation} ->
          case Events.Store.append(event_attrs(observation), repo: repo, telemetry: false) do
            {:ok, _event} = result -> result
            {:error, reason} -> {:error, reason}
          end
        end)

      case repo().transaction(multi) do
        {:ok, %{observation: observation, event: event_result}} ->
          Events.Store.emit_result({:ok, event_result})
          {:ok, observation}

        {:error, :observation, changeset, _changes} ->
          {:error, changeset}

        {:error, :event, reason, _changes} ->
          {:error, reason}
      end
    else
      %Observation{} |> Observation.changeset(attrs) |> repo().insert()
    end
  end

  defp event_attrs(%Observation{} = observation) do
    %{
      id: observation.id,
      stream_id: "session:" <> observation.session_id,
      session_id: observation.session_id,
      event_type: "legacy.observation",
      actor_type: "system",
      role: "system",
      status: if(observation.is_error, do: "error", else: "ok"),
      tool_name: observation.tool_name,
      content: observation.content,
      payload: observation.files,
      idempotency_key: "legacy-observation:" <> observation.id
    }
  end

  @doc "Register/upsert a session."
  def register_session(session_id, project) do
    result =
      repo().transaction(fn ->
        changeset =
          Session.changeset(%Session{}, %{
            session_id: session_id,
            project: project,
            started_at: DateTime.utc_now()
          })

        with {:ok, session} <-
               repo().insert(changeset, on_conflict: :nothing, conflict_target: [:session_id]),
             {:ok, event_result} <- lifecycle_event("session.started", session, repo()) do
          {session, event_result}
        else
          {:error, reason} -> repo().rollback(reason)
        end
      end)

    case result do
      {:ok, {session, event_result}} ->
        Backplane.Memory.Events.Store.emit_result({:ok, event_result})
        {:ok, session}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Mark a session as ended and enqueue consolidation."
  def end_session(session_id) do
    result =
      repo().transaction(fn ->
        {count, _} =
          repo().update_all(
            from(s in Session, where: s.session_id == ^session_id and is_nil(s.ended_at)),
            set: [ended_at: DateTime.utc_now()]
          )

        if count > 0 do
          project =
            repo().one(from(s in Session, where: s.session_id == ^session_id, select: s.project))

          case lifecycle_event(
                 "session.ended",
                 %{session_id: session_id, project: project},
                 repo()
               ) do
            {:ok, event_result} -> {count, event_result}
            {:error, reason} -> repo().rollback(reason)
          end
        else
          {count, []}
        end
      end)

    {_count, event_result} = result = unwrap_transaction(result)

    if event_result != [] and
         (match?({:inserted, _}, event_result) or match?({:duplicate, _}, event_result)) do
      Backplane.Memory.Events.Store.emit_result({:ok, event_result})
    end

    case result do
      {n, _} when n > 0 -> Backplane.Memory.Workers.SummaryWorker.enqueue(session_id)
      _ -> :ok
    end

    result
  end

  defp unwrap_transaction({:ok, value}), do: value
  defp unwrap_transaction({:error, reason}), do: {0, reason}

  defp lifecycle_event(type, session, repo) do
    if Config.dual_write?() do
      Events.Store.append(
        %{
          stream_id: "session:" <> session.session_id,
          session_id: session.session_id,
          project: session.project,
          event_type: type,
          actor_type: "system",
          role: "system",
          status: "ok",
          idempotency_key: type <> ":" <> session.session_id
        },
        repo: repo,
        telemetry: false
      )
    else
      {:ok, :disabled}
    end
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

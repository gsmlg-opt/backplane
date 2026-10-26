defmodule Backplane.Memory.Observations do
  @moduledoc "Observation and session commands backed exclusively by canonical events."

  import Ecto.Query

  alias Backplane.Memory.Events.{Event, Store}
  alias Backplane.Memory.Ingest.EventValidator
  alias Backplane.Memory.PartitionIdentity
  alias Backplane.Memory.Privacy.Filter
  alias Backplane.Memory.Projections.{ObservationProjector, ProjectedObservation, Source}
  alias Backplane.Memory.Workers.SummaryWorker

  @option_keys [:project, :agent_id, :run_id, :correlation_id, :causation_id]

  @doc "Records one canonical event after filtering its content and payload."
  def record(session_id, content, opts \\ []) do
    with {:ok, partition} <- partition(opts),
         :ok <- valid_session(session_id),
         {:ok, filtered} <- Filter.apply(content),
         :ok <- nonempty_content(filtered) do
      attrs = event_attrs(session_id, filtered, opts, partition)

      transact(attrs, fn repo, stream ->
        attrs
        |> materialize(repo, stream, opts)
        |> append!(repo)
        |> observation()
      end)
    end
  end

  @doc "Starts a session once. Its authoritative lifecycle lives in the event stream."
  def register_session(session_id, project, opts \\ []) do
    with {:ok, partition} <- partition(opts),
         :ok <- valid_session(session_id) do
      attrs = lifecycle_attrs("session.started", session_id, project, opts, partition)

      transact(attrs, fn repo, stream ->
        case lifecycle_event(repo, stream, "session.started") do
          %Event{} = event -> session(event, stream)
          nil -> attrs |> materialize(repo, stream, opts) |> append!(repo) |> session(stream)
        end
      end)
    end
  end

  @doc "Ends an existing session once and enqueues canonical consolidation."
  def end_session(session_id, opts \\ []) do
    with {:ok, partition} <- partition(opts),
         :ok <- valid_session(session_id) do
      attrs = lifecycle_attrs("session.ended", session_id, nil, opts, partition)

      result =
        transact(attrs, fn repo, stream ->
          case lifecycle_event(repo, stream, "session.started") do
            nil ->
              repo.rollback(:not_found)

            %Event{} = started ->
              if lifecycle_event(repo, stream, "session.ended") do
                {0, nil}
              else
                event_result =
                  attrs
                  |> Map.put(:project, started.project)
                  |> materialize(repo, stream, opts)
                  |> append!(repo)

                {:ok, _stream} = Store.close_stream(stream.stream_id, repo: repo)
                %{event_result: event_result, value: {1, nil}}
              end
          end
        end)

      case result do
        {:ok, {count, nil} = transition} ->
          if count > 0, do: enqueue_summary(session_id, partition)
          transition

        {:error, :not_found} ->
          if opts[:require_existing] == true, do: {:error, :not_found}, else: {0, nil}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc "Returns canonical projected observations referencing the requested file paths."
  def file_history(file_paths, opts \\ []) when is_list(file_paths) do
    with {:ok, partition} <- partition(opts) do
      query =
        from(o in ProjectedObservation,
          where:
            o.memory_space_id == ^partition.memory_space_id and o.scope == ^partition.scope and
              o.namespace == ^partition.namespace and
              fragment("? && ?", o.file_paths, ^file_paths),
          order_by: [desc: o.occurred_at, desc: o.event_id],
          limit: ^Keyword.get(opts, :limit, 50)
        )

      query =
        case opts[:exclude_session] do
          nil -> query
          session_id -> where(query, [o], o.session_id != ^session_id)
        end

      repo().all(query)
    else
      {:error, _reason} -> []
    end
  end

  defp transact(attrs, callback) do
    started_at = System.monotonic_time()
    result = Store.with_stream_lock(Map.put(attrs, :project, nil), callback)

    case result do
      {:ok, %{event_result: event_result, value: value}} ->
        if event_result, do: Store.emit_result({:ok, event_result}, started_at)
        {:ok, value}

      {:ok, value} ->
        {:ok, value}

      {:error, reason} ->
        Store.emit_result({:error, reason}, started_at)
        {:error, reason}
    end
  end

  defp append!(attrs, repo) do
    case Store.append_tagged(attrs, repo: repo, telemetry: false) do
      {:ok, result} -> result
      {:error, reason} -> repo.rollback(reason)
    end
  end

  defp observation({status, event}) do
    projected = ObservationProjector.project([event])["observations"] |> hd()

    %{
      event_result: {status, event},
      value: %{
        id: event.id,
        event_id: event.id,
        session_id: event.session_id,
        tool_name: projected["tool_name"],
        content: event.content,
        is_error: projected["is_error"],
        files: %{"paths" => projected["file_paths"]},
        created_at: event.occurred_at
      }
    }
  end

  defp session({status, event}, stream) do
    %{event_result: {status, event}, value: session(event, stream)}
  end

  defp session(%Event{} = event, stream) do
    %{
      session_id: event.session_id,
      project: event.project,
      started_at: event.occurred_at,
      ended_at: stream.closed_at
    }
  end

  defp lifecycle_event(repo, stream, type) do
    repo.one(
      from(e in Event,
        where: e.stream_id == ^stream.stream_id and e.event_type == ^type,
        order_by: [asc: e.sequence],
        limit: 1
      )
    )
  end

  defp materialize(attrs, repo, stream, opts) do
    existing =
      if attrs[:idempotency_key], do: repo.get_by(Event, idempotency_key: attrs.idempotency_key)

    sequence =
      if existing do
        existing.source_sequence
      else
        max_sequence =
          repo.one(
            from(e in Event,
              where: e.host_id == ^attrs.host_id and e.session_id == ^attrs.session_id,
              select: max(e.source_sequence)
            )
          )

        (max_sequence || 0) + 1
      end

    occurred_at = opts[:occurred_at] || (existing && existing.occurred_at) || DateTime.utc_now()

    {:ok, payload} = Filter.apply_payload(attrs.payload)

    attrs
    |> Map.put(:payload, payload)
    |> Map.put(:source_sequence, sequence || stream.next_sequence)
    |> Map.put(:occurred_at, occurred_at)
    |> Map.put(:captured_at, (existing && existing.captured_at) || occurred_at)
    |> Map.put(:payload_hash, EventValidator.payload_hash(payload))
  end

  defp event_attrs(session_id, content, opts, partition) do
    error? = opts[:is_error] in [true, "true", 1, "1"]
    tool = opts[:tool_name]
    type = opts[:event_type] || default_type(tool, error?)
    payload = observation_payload(Keyword.get(opts, :payload, %{}), content)

    base_attrs(session_id, opts, partition)
    |> Map.merge(%{
      event_type: type,
      content: content,
      tool_name: tool,
      status: if(error?, do: "failed", else: "ok"),
      payload: payload,
      idempotency_key: namespaced_key(opts[:idempotency_key], partition)
    })
  end

  defp lifecycle_attrs(type, session_id, project, opts, partition) do
    base_attrs(session_id, opts, partition)
    |> Map.merge(%{
      project: project,
      event_type: type,
      status: "ok",
      payload: %{},
      idempotency_key: namespaced_key(type <> ":" <> session_id, partition)
    })
  end

  defp base_attrs(session_id, opts, partition) do
    partition
    |> Map.merge(Map.new(Keyword.take(opts, @option_keys)))
    |> Map.merge(%{
      stream_id: Keyword.get(opts, :stream_id, stream_id(session_id, partition)),
      session_id: session_id,
      schema_version: 1,
      integration: "memory-api",
      actor_type: "system",
      role: "system",
      payload: %{},
      privacy: %{"server_filtered" => true}
    })
  end

  defp stream_id(session_id, partition) do
    identity = [
      partition.memory_space_id,
      partition.scope,
      partition.namespace,
      partition.host_id,
      session_id
    ]

    "memory-api:" <> Base.url_encode64(Jason.encode!(identity), padding: false)
  end

  defp namespaced_key(nil, _partition), do: nil

  defp namespaced_key(key, partition) when is_binary(key) do
    "memory-api:" <>
      Base.url_encode64(
        Jason.encode!([
          partition.memory_space_id,
          partition.scope,
          partition.namespace,
          partition.host_id,
          key
        ]),
        padding: false
      )
  end

  defp namespaced_key(_key, _partition), do: nil

  defp default_type(tool, error?) when is_binary(tool) and byte_size(tool) > 0,
    do: if(error?, do: "tool.call.failed", else: "tool.call.completed")

  defp default_type(_tool, _error?), do: "observation.recorded"

  defp observation_payload(payload, content) when is_map(payload) and not is_struct(payload) do
    paths = extract_files(content)

    Map.update(payload, "paths", paths, fn
      existing when is_list(existing) -> Enum.uniq(existing ++ paths)
      _existing -> paths
    end)
  end

  defp observation_payload(payload, _content), do: payload

  defp enqueue_summary(session_id, partition) do
    with {:ok, %{input_revision: revision}} <-
           Source.input_revision(partition.host_id, session_id) do
      SummaryWorker.enqueue(partition.host_id, session_id, revision, partition)
    end
  end

  defp partition(opts) when is_list(opts) do
    candidate = opts[:trusted_partition] || Map.new(opts)
    PartitionIdentity.validate_generator(candidate)
  end

  defp partition(_opts), do: {:error, :incomplete_partition}

  defp valid_session(id) when is_binary(id) do
    if String.trim(id) == "", do: {:error, :missing_identity}, else: :ok
  end

  defp valid_session(_id), do: {:error, :missing_identity}
  defp nonempty_content(content) when byte_size(content) > 0, do: :ok
  defp nonempty_content(_content), do: {:error, :invalid_content}

  defp extract_files(content) do
    Regex.scan(
      ~r{(?:^|[\s"'`(])(/[^\s"'`)\n]+\.\w+|[a-zA-Z0-9_./\-]+/[a-zA-Z0-9_./\-]+\.\w+)},
      content
    )
    |> Enum.map(fn [_, path] -> String.trim(path) end)
    |> Enum.uniq()
    |> Enum.take(20)
  end

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)
end

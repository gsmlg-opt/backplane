defmodule Backplane.Memory.Replay do
  @moduledoc """
  Bounded exact-partition reads over canonical replay projections.

  Missing partition identity returns `:unauthorized`, malformed cursors return
  `:invalid_cursor`, invalid limits/options return `:invalid_options`, and an
  exact partition with no projected session returns `:not_found`.
  """
  import Ecto.Query
  alias Backplane.Memory.Projections.{ProjectedSession, Source}
  alias Backplane.Memory.Replay.{Event, LinkResolver}

  @doc "Lists bounded replayable sessions in one exact authenticated partition."
  def sessions(partition, opts \\ []) do
    Backplane.Memory.PipelineTelemetry.span("replay.sessions", map_metadata(partition), fn ->
      do_sessions(partition, opts)
    end)
  end

  defp do_sessions(partition, opts) do
    with {:ok, partition} <- partition(partition),
         :ok <- session_options(opts),
         limit when is_integer(limit) and limit in 1..100 <- Keyword.get(opts, :limit, 20),
         offset when is_integer(offset) and offset in 0..10_000 <- Keyword.get(opts, :offset, 0) do
      rows =
        ProjectedSession
        |> where(
          [session],
          session.host_id == ^partition.host_id and session.client_id == ^partition.client_id and
            session.scope == ^partition.scope and session.namespace == ^partition.namespace
        )
        |> order_by([session], desc: session.last_event_at, desc: session.session_id)
        |> limit(^limit)
        |> offset(^offset)
        |> select([session], %{
          session_id: session.session_id,
          project: session.project,
          agent_id: session.agent_id,
          integration: session.integration,
          status: session.status,
          started_at: session.started_at,
          ended_at: session.ended_at,
          last_event_at: session.last_event_at,
          event_count: session.source_sequence_max,
          gap_count: session.gap_count
        })
        |> repo().all()

      {:ok, %{sessions: rows, limit: limit, offset: offset}}
    else
      {:error, reason} when reason in [:unauthorized, :invalid_options] -> {:error, reason}
      _ -> {:error, :invalid_options}
    end
  end

  def load(partition, session_id, opts \\ []) do
    metadata = Map.put(map_metadata(partition), :session_id, session_id)

    Backplane.Memory.PipelineTelemetry.span("replay.load", metadata, fn ->
      do_load(partition, session_id, opts)
    end)
  end

  defp do_load(partition, session_id, opts) do
    with {:ok, partition} <- partition(partition),
         :ok <- options(opts),
         true <- is_binary(session_id) and String.trim(session_id) != "",
         limit when is_integer(limit) and limit in 1..100 <- Keyword.get(opts, :limit, 50),
         subject_id <- Source.subject_id!(partition.host_id, session_id),
         projected_session <- repo().get(ProjectedSession, subject_id),
         {:ok, revision} <- exact_revision(projected_session, partition, session_id),
         {:ok, after_position} <- cursor(Keyword.get(opts, :cursor), revision) do
      rows =
        repo().all(
          from e in Event,
            where:
              e.subject_id == ^subject_id and e.input_revision == ^revision and
                e.host_id == ^partition.host_id and e.client_id == ^partition.client_id and
                e.scope == ^partition.scope and e.namespace == ^partition.namespace and
                e.session_id == ^session_id and e.position > ^after_position,
            order_by: e.position,
            limit: ^(limit + 1)
        )

      {page, rest} = Enum.split(rows, limit)
      links_by_event = LinkResolver.resolve(Enum.map(page, & &1.event_id), partition, session_id)

      {:ok,
       %{
         events:
           Enum.map(page, fn event ->
             event
             |> Map.take([:event_id, :position, :kind, :event_type, :occurred_at, :detail])
             |> Map.put(:links, Map.fetch!(links_by_event, event.event_id))
           end),
         next_cursor: next_cursor(page, rest, revision)
       }}
    else
      {:error, reason}
      when reason in [:unauthorized, :invalid_cursor, :invalid_options, :not_found] ->
        {:error, reason}

      _ ->
        {:error, :invalid_options}
    end
  end

  defp options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and Keyword.keys(opts) -- [:cursor, :limit] == [],
      do: :ok,
      else: {:error, :invalid_options}
  end

  defp options(_opts), do: {:error, :invalid_options}

  defp session_options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and Keyword.keys(opts) -- [:limit, :offset] == [],
      do: :ok,
      else: {:error, :invalid_options}
  end

  defp session_options(_opts), do: {:error, :invalid_options}

  defp exact_revision(%ProjectedSession{} = session, partition, session_id) do
    if Map.take(session, [:host_id, :client_id, :scope, :namespace, :session_id]) ==
         Map.put(partition, :session_id, session_id),
       do: {:ok, session.input_revision},
       else: {:error, :not_found}
  end

  defp exact_revision(nil, _partition, _session_id), do: {:error, :not_found}

  defp partition(value) when is_map(value) do
    result =
      Map.new([:host_id, :client_id, :scope, :namespace], fn key ->
        {key, Map.get(value, key) || Map.get(value, Atom.to_string(key))}
      end)

    if Enum.all?(result, fn {_k, v} -> is_binary(v) and String.trim(v) != "" end),
      do: {:ok, result},
      else: {:error, :unauthorized}
  end

  defp partition(_), do: {:error, :unauthorized}
  defp cursor(nil, _revision), do: {:ok, 0}

  defp cursor(value, revision) when is_binary(value) do
    with {:ok, raw} <- Base.url_decode64(value, padding: false),
         [^revision, encoded_position] <- String.split(raw, ":", parts: 2),
         {position, ""} when position >= 0 <- Integer.parse(encoded_position),
         do: {:ok, position},
         else: (_ -> {:error, :invalid_cursor})
  end

  defp cursor(_, _revision), do: {:error, :invalid_cursor}
  defp next_cursor(_page, [], _revision), do: nil

  defp next_cursor(page, [_ | _], revision),
    do:
      (revision <> ":" <> Integer.to_string(List.last(page).position))
      |> Base.url_encode64(padding: false)

  defp map_metadata(value) when is_map(value), do: value
  defp map_metadata(value) when is_list(value), do: Map.new(value)
  defp map_metadata(_value), do: %{}

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)
end

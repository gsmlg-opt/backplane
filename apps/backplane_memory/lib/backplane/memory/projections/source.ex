defmodule Backplane.Memory.Projections.Source do
  @moduledoc "Queries the authoritative captured-event source for projection inputs."

  import Ecto.Query

  alias Backplane.Memory.Events.{Event, Stream}
  alias Backplane.Memory.Projections.Revision

  @default_page_size 100

  def events(host_id, session_id) do
    with :ok <- validate_identifier(host_id, :invalid_host_id),
         :ok <- validate_identifier(session_id, :invalid_session_id) do
      query =
        from(e in Event,
          where:
            not is_nil(e.schema_version) and e.host_id == ^host_id and
              e.session_id == ^session_id,
          order_by: [asc: e.source_sequence, asc: e.event_type, asc: e.id]
        )

      {:ok, repo().all(query)}
    end
  end

  @doc "Locks the canonical session streams in the same deterministic order as event appends/rebuilds."
  def lock_streams(host_id, session_id) do
    repo().all(
      from(s in Stream,
        where: s.host_id == ^host_id and s.session_id == ^session_id,
        order_by: [asc: s.stream_id],
        lock: "FOR UPDATE"
      )
    )
  end

  @doc "Streams the authoritative revision input with bounded database fetches."
  def input_revision(host_id, session_id) do
    query =
      from(e in Event,
        where:
          not is_nil(e.schema_version) and e.host_id == ^host_id and
            e.session_id == ^session_id,
        order_by: [asc: e.source_sequence, asc: e.event_type, asc: e.id],
        select: [e.id, e.payload_hash, e.source_sequence, e.event_type]
      )

    {context, count} =
      query
      |> repo().stream(max_rows: @default_page_size)
      |> Enum.reduce({:crypto.hash_init(:sha256) |> :crypto.hash_update("["), 0}, fn row,
                                                                                     {context,
                                                                                      count} ->
        {:ok, encoded} = Revision.encode_json(row)
        separator = if count == 0, do: "", else: ","
        {:crypto.hash_update(context, [separator, encoded]), count + 1}
      end)

    revision =
      context
      |> :crypto.hash_update("]")
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    {:ok, %{input_revision: revision, event_count: count}}
  end

  def subjects do
    reduce_subjects([], fn subject, subjects -> {:cont, [subject | subjects]} end)
    |> case do
      {:ok, subjects} -> {:ok, Enum.reverse(subjects)}
      {:error, reason} -> {:error, reason}
    end
  end

  def reduce_subjects(acc, reducer, opts \\ []) when is_function(reducer, 2) do
    page_size = Keyword.get(opts, :page_size, @default_page_size)

    if is_integer(page_size) and page_size > 0 do
      reduce_subject_pages(nil, page_size, acc, reducer)
    else
      {:error, :invalid_page_size}
    end
  end

  def subject_id(host_id, session_id) do
    with :ok <- validate_identifier(host_id, :invalid_host_id),
         :ok <- validate_identifier(session_id, :invalid_session_id) do
      encoded =
        [host_id, session_id]
        |> Jason.encode!()
        |> Base.url_encode64(padding: false)

      {:ok, encoded}
    end
  end

  def subject_id!(host_id, session_id) do
    {:ok, subject_id} = subject_id(host_id, session_id)
    subject_id
  end

  defp validate_identifier(value, error) when is_binary(value) do
    if String.trim(value) == "", do: {:error, error}, else: :ok
  end

  defp validate_identifier(_value, error), do: {:error, error}

  defp reduce_subject_pages(cursor, page_size, acc, reducer) do
    subjects = subject_page(cursor, page_size)

    case reduce_page(subjects, acc, reducer) do
      {:halt, acc} ->
        {:ok, acc}

      {:cont, acc} when length(subjects) < page_size ->
        {:ok, acc}

      {:cont, acc} ->
        last = List.last(subjects)
        reduce_subject_pages({last["host_id"], last["session_id"]}, page_size, acc, reducer)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp subject_page(cursor, page_size) do
    Event
    |> where(
      [e],
      not is_nil(e.schema_version) and not is_nil(e.host_id) and not is_nil(e.session_id)
    )
    |> after_subject(cursor)
    |> group_by([e], [e.host_id, e.session_id])
    |> order_by([e], asc: e.host_id, asc: e.session_id)
    |> select([e], {e.host_id, e.session_id})
    |> limit(^page_size)
    |> repo().all()
    |> Enum.map(fn {host_id, session_id} ->
      %{
        "host_id" => host_id,
        "session_id" => session_id,
        "subject_id" => subject_id!(host_id, session_id)
      }
    end)
  end

  defp after_subject(query, nil), do: query

  defp after_subject(query, {host_id, session_id}) do
    where(
      query,
      [e],
      e.host_id > ^host_id or (e.host_id == ^host_id and e.session_id > ^session_id)
    )
  end

  defp reduce_page(subjects, acc, reducer) do
    Enum.reduce_while(subjects, {:cont, acc}, fn subject, {:cont, acc} ->
      case reducer.(subject, acc) do
        {:cont, next_acc} -> {:cont, {:cont, next_acc}}
        {:halt, next_acc} -> {:halt, {:halt, next_acc}}
        {:error, reason} -> {:halt, {:error, reason}}
        other -> {:halt, {:error, {:invalid_reducer_result, other}}}
      end
    end)
  end

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)
end

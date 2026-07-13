defmodule Backplane.Memory.Events.Store do
  @moduledoc "Persistent, ordered storage for normalized memory events."

  import Ecto.Query
  alias Backplane.Memory.Events.{Event, Stream}

  def append(attrs, opts \\ []) do
    repo = Keyword.get(opts, :repo, repo())

    with {:ok, event} <- Backplane.Memory.Events.append(attrs),
         {:ok, result} <- repo.transaction(fn -> append_locked(repo, event) end) do
      unwrap(result)
    end
  end

  def append_batch(attrs_list, opts \\ []) when is_list(attrs_list) do
    repo = Keyword.get(opts, :repo, repo())

    with {:ok, events} <- Backplane.Memory.Events.append_batch(attrs_list),
         {:ok, result} <- repo.transaction(fn -> batch_locked(repo, events) end) do
      unwrap(result)
    end
  end

  def append_batch(_, _), do: {:error, :invalid_attributes}

  def get(id, opts \\ []) do
    Keyword.get(opts, :repo, repo()).get(Event, id)
  end

  def list(stream_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, repo())
    limit = Keyword.get(opts, :limit, 100)

    Event
    |> where([e], e.stream_id == ^stream_id)
    |> order_by([e], asc: e.sequence)
    |> limit(^limit)
    |> repo.all()
  end

  def close_stream(stream_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, repo())

    repo.transaction(fn ->
      stream = lock_stream(repo, stream_id)
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      repo.update_all(from(s in Stream, where: s.stream_id == ^stream_id),
        set: [closed_at: stream.closed_at || now]
      )

      %{stream | closed_at: stream.closed_at || now}
    end)
  end

  defp append_locked(repo, %Event{} = event) do
    stream = lock_stream(repo, event.stream_id, event)

    case duplicate(repo, event) do
      nil ->
        case ensure_open(stream) do
          :ok ->
            event = %{event | sequence: stream.next_sequence}
            {:ok, inserted} = repo.insert(Event.changeset(event, Map.from_struct(event)))

            repo.update_all(from(s in Stream, where: s.stream_id == ^event.stream_id),
              set: [next_sequence: event.sequence + 1, last_event_at: event.occurred_at]
            )

            {:inserted, inserted}

          error ->
            error
        end

      existing ->
        {:duplicate, existing}
    end
  end

  defp batch_locked(repo, events) do
    events
    |> Enum.map(& &1.stream_id)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.each(fn id -> lock_stream(repo, id) end)

    Enum.reduce_while(events, [], fn event, acc ->
      case append_locked(repo, event) do
        {:error, reason} -> repo.rollback(reason)
        result -> {:cont, [result | acc]}
      end
    end)
    |> Enum.reverse()
  end

  defp duplicate(repo, %{idempotency_key: nil}), do: nil

  defp duplicate(repo, event),
    do:
      repo.one(
        from e in Event,
          where: e.stream_id == ^event.stream_id and e.idempotency_key == ^event.idempotency_key
      )

  defp lock_stream(repo, stream_id, event \\ nil) do
    repo.insert(
      %Stream{
        stream_id: stream_id,
        project: event && event.project,
        agent_id: event && event.agent_id
      },
      on_conflict: :nothing
    )

    repo.one!(from s in Stream, where: s.stream_id == ^stream_id, lock: "FOR UPDATE")
  end

  defp ensure_open(%{closed_at: nil}), do: :ok
  defp ensure_open(_), do: {:error, :stream_closed}

  defp unwrap({:error, reason}), do: {:error, reason}
  defp unwrap(result), do: {:ok, result}

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)
end

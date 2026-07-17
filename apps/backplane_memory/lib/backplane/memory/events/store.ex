defmodule Backplane.Memory.Events.Store do
  @moduledoc "Persistent, ordered storage for normalized memory events."

  import Ecto.Query

  alias Backplane.Memory.EventNotifier
  alias Backplane.Memory.Events.{Event, Preparation, Stream}

  @metadata_fields [:project, :agent_id, :host_id, :client_id, :session_id, :run_id]
  @idempotency_constraint "bpm_events_idempotency_key_uniq"

  def append(attrs, opts \\ []) do
    started_at = System.monotonic_time()
    repo = Keyword.get(opts, :repo, repo())
    telemetry? = Keyword.get(opts, :telemetry, true)

    tagged_result =
      Ecto.Multi.new()
      |> append_multi(:event, attrs)
      |> transact_append(repo, :event)

    if telemetry?, do: emit_telemetry(tagged_result, started_at)
    unwrap_public(tagged_result)
  end

  @doc false
  def append_multi(%Ecto.Multi{} = multi, name, attrs) do
    case Preparation.prepare(attrs) do
      {:ok, event} ->
        Ecto.Multi.run(multi, name, fn repo, _changes -> append_locked(repo, event) end)

      {:error, reason} ->
        Ecto.Multi.error(multi, name, reason)
    end
  end

  def append_batch(attrs_list, opts \\ [])

  def append_batch(attrs_list, opts) when is_list(attrs_list) do
    started_at = System.monotonic_time()
    repo = Keyword.get(opts, :repo, repo())
    telemetry? = Keyword.get(opts, :telemetry, true)

    tagged_result =
      with {:ok, events} <- Preparation.prepare_batch(attrs_list) do
        transact_batch(repo, events, idempotency_count(events) + 1)
      end

    if telemetry?, do: emit_batch_telemetry(tagged_result, started_at)
    unwrap_public(tagged_result)
  end

  def append_batch(_, opts) do
    started_at = System.monotonic_time()
    result = {:error, :invalid_attributes}
    telemetry? = if Keyword.keyword?(opts), do: Keyword.get(opts, :telemetry, true), else: true
    if telemetry?, do: emit_telemetry(result, started_at)
    result
  end

  def get(id, opts \\ []) do
    Keyword.get(opts, :repo, repo()).get(Event, id)
  end

  @doc false
  def emit_result(result), do: emit_telemetry(result, System.monotonic_time())

  @doc false
  def emit_result(result, started_at), do: emit_telemetry(result, started_at)

  @doc false
  def resolve_idempotency_race({:idempotency_race, marker}, opts \\ []) do
    repo = Keyword.get(opts, :repo, repo())

    case repo.get_by(Event, idempotency_key: marker.idempotency_key) do
      nil ->
        {:error, :idempotency_unique_violation}

      existing ->
        case validate_duplicate(existing, marker) do
          {:duplicate, event} -> {:ok, {:duplicate, event}}
          {:error, reason} -> {:error, reason}
        end
    end
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
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    query =
      from(s in Stream,
        where: s.stream_id == ^stream_id,
        update: [set: [closed_at: fragment("COALESCE(?, ?)", s.closed_at, ^now)]],
        select: s
      )

    case repo.update_all(query, []) do
      {1, [stream]} -> {:ok, stream}
      {0, []} -> {:error, :not_found}
    end
  end

  defp transact_append(multi, repo, name) do
    case repo.transaction(multi) do
      {:ok, %{^name => tagged}} ->
        {:ok, tagged}

      {:error, ^name, {:idempotency_race, _marker} = race, _changes} ->
        resolve_idempotency_race(race, repo: repo)

      {:error, ^name, reason, _changes} ->
        {:error, reason}
    end
  end

  defp transact_batch(_repo, _events, attempts_left) when attempts_left <= 0,
    do: {:error, :idempotency_race_retry_exhausted}

  defp transact_batch(repo, events, attempts_left) do
    case repo.transaction(fn -> batch_locked(repo, events) end) do
      {:ok, tagged} ->
        {:ok, tagged}

      {:error, {:idempotency_race, _marker} = race} ->
        case resolve_idempotency_race(race, repo: repo) do
          {:ok, {:duplicate, _event}} -> transact_batch(repo, events, attempts_left - 1)
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp append_locked(repo, %Event{} = event) do
    case find_duplicate(repo, event.idempotency_key) do
      nil ->
        stream = create_and_lock_stream(repo, event.stream_id, event)

        case find_duplicate(repo, event.idempotency_key) do
          nil -> append_insert_result(insert_new_event(repo, stream, event))
          existing -> append_duplicate_result(validate_duplicate(existing, event))
        end

      existing ->
        append_duplicate_result(validate_duplicate(existing, event))
    end
  end

  defp append_insert_result({:inserted, event, _stream}), do: {:ok, {:inserted, event}}
  defp append_insert_result({:error, reason}), do: {:error, reason}

  defp append_duplicate_result({:duplicate, event}), do: {:ok, {:duplicate, event}}
  defp append_duplicate_result({:error, reason}), do: {:error, reason}

  defp batch_locked(repo, events) do
    streams = create_and_lock_streams(repo, events)

    events
    |> Enum.reduce_while({[], streams}, fn event, {results, stream_by_id} ->
      case append_with_locked_stream(repo, Map.fetch!(stream_by_id, event.stream_id), event) do
        {:ok, tagged, stream} ->
          {:cont, {[tagged | results], Map.put(stream_by_id, event.stream_id, stream)}}

        {:error, reason} ->
          repo.rollback(reason)
      end
    end)
    |> case do
      {results, _streams} -> Enum.reverse(results)
    end
  end

  defp append_with_locked_stream(repo, stream, event) do
    case find_duplicate(repo, event.idempotency_key) do
      nil ->
        case insert_new_event(repo, stream, event) do
          {:inserted, inserted, updated_stream} ->
            {:ok, {:inserted, inserted}, updated_stream}

          {:error, reason} ->
            {:error, reason}
        end

      existing ->
        case validate_duplicate(existing, event) do
          {:duplicate, duplicate} -> {:ok, {:duplicate, duplicate}, stream}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp insert_new_event(repo, stream, event) do
    with :ok <- ensure_open(stream) do
      stream = fill_null_metadata(repo, stream, event)
      event = %{event | sequence: stream.next_sequence}

      case repo.insert(Event.changeset(event, Map.from_struct(event))) do
        {:ok, inserted} ->
          last_event_at = greatest_datetime(stream.last_event_at, event.occurred_at)

          repo.update_all(from(s in Stream, where: s.stream_id == ^event.stream_id),
            set: [next_sequence: event.sequence + 1, last_event_at: last_event_at]
          )

          updated_stream = %{
            stream
            | next_sequence: event.sequence + 1,
              last_event_at: last_event_at
          }

          case EventNotifier.enqueue(repo, inserted.id) do
            :ok -> {:inserted, inserted, updated_stream}
            {:error, reason} -> {:error, reason}
          end

        {:error, changeset} ->
          if idempotency_unique_violation?(changeset, event) do
            {:error, race_marker(event)}
          else
            {:error, changeset}
          end
      end
    end
  end

  defp create_and_lock_streams(repo, events) do
    events_by_stream = Enum.group_by(events, & &1.stream_id)
    stream_ids = events_by_stream |> Map.keys() |> Enum.sort()

    Enum.each(stream_ids, fn stream_id ->
      event = events_by_stream |> Map.fetch!(stream_id) |> hd()
      insert_missing_stream(repo, stream_id, event)
    end)

    Map.new(stream_ids, fn stream_id ->
      {stream_id, lock_existing_stream(repo, stream_id)}
    end)
  end

  defp create_and_lock_stream(repo, stream_id, event) do
    insert_missing_stream(repo, stream_id, event)
    lock_existing_stream(repo, stream_id)
  end

  defp insert_missing_stream(repo, stream_id, event) do
    attrs = metadata(event)

    repo.insert(
      struct(Stream, Map.put(attrs, :stream_id, stream_id)),
      on_conflict: :nothing,
      conflict_target: [:stream_id]
    )
  end

  defp lock_existing_stream(repo, stream_id) do
    repo.one!(from s in Stream, where: s.stream_id == ^stream_id, lock: "FOR UPDATE")
  end

  defp fill_null_metadata(repo, stream, event) do
    updates =
      Enum.reduce(@metadata_fields, [], fn field, updates ->
        if is_nil(Map.get(stream, field)) and not is_nil(Map.get(event, field)) do
          [{field, Map.get(event, field)} | updates]
        else
          updates
        end
      end)

    if updates == [] do
      stream
    else
      repo.update_all(from(s in Stream, where: s.stream_id == ^stream.stream_id), set: updates)
      Enum.reduce(updates, stream, fn {field, value}, stream -> Map.put(stream, field, value) end)
    end
  end

  defp metadata(event),
    do: Map.take(event, @metadata_fields)

  defp find_duplicate(_repo, nil), do: nil
  defp find_duplicate(repo, key), do: repo.get_by(Event, idempotency_key: key)

  defp validate_duplicate(existing, event_or_marker) do
    fingerprint = fingerprint(event_or_marker)

    if existing.stream_id == event_or_marker.stream_id and
         existing.event_type == event_or_marker.event_type and
         not is_nil(fingerprint(existing)) and
         fingerprint(existing) == fingerprint do
      {:duplicate, existing}
    else
      {:error, :idempotency_conflict}
    end
  end

  defp fingerprint(%Event{payload: payload}),
    do: get_in(payload || %{}, ["_backplane", "event_fingerprint"])

  defp fingerprint(marker), do: Map.get(marker, :event_fingerprint)

  defp race_marker(event) do
    {:idempotency_race,
     %{
       idempotency_key: event.idempotency_key,
       stream_id: event.stream_id,
       event_type: event.event_type,
       event_fingerprint: fingerprint(event)
     }}
  end

  defp idempotency_unique_violation?(changeset, event) do
    not is_nil(event.idempotency_key) and
      Enum.any?(changeset.errors, fn
        {:idempotency_key, {_message, opts}} ->
          opts[:constraint] == :unique and
            to_string(opts[:constraint_name]) == @idempotency_constraint

        _ ->
          false
      end)
  end

  defp idempotency_count(events),
    do: Enum.count(events, &(not is_nil(&1.idempotency_key)))

  defp greatest_datetime(nil, occurred_at), do: occurred_at

  defp greatest_datetime(last_event_at, occurred_at) do
    case DateTime.compare(last_event_at, occurred_at) do
      :lt -> occurred_at
      _ -> last_event_at
    end
  end

  defp ensure_open(%{closed_at: nil}), do: :ok
  defp ensure_open(_), do: {:error, :stream_closed}

  defp unwrap_public({:ok, {_status, %Event{} = event}}), do: {:ok, event}

  defp unwrap_public({:ok, results}) when is_list(results),
    do: {:ok, Enum.map(results, fn {_status, event} -> event end)}

  defp unwrap_public({:error, reason}), do: {:error, reason}

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)

  defp emit_telemetry({:ok, {:inserted, event}}, started_at),
    do: emit_status(:inserted, event, started_at)

  defp emit_telemetry({:ok, {:duplicate, event}}, started_at),
    do: emit_status(:duplicate, event, started_at)

  defp emit_telemetry({:ok, %Event{} = event}, started_at),
    do: emit_status(:inserted, event, started_at)

  defp emit_telemetry({:error, _reason}, started_at) do
    :telemetry.execute(
      [:backplane, :memory, :event, :error],
      measurements(nil, started_at),
      telemetry_metadata(:error, nil)
    )
  end

  defp emit_telemetry(_, _started_at), do: :ok

  defp emit_status(status, event, started_at) do
    outcome = if status == :inserted, do: :append, else: :duplicate

    :telemetry.execute(
      [:backplane, :memory, :event, outcome],
      measurements(event, started_at),
      telemetry_metadata(status, event)
    )
  end

  defp measurements(event, started_at) do
    %{
      duration: elapsed(started_at),
      content_bytes: content_bytes(event),
      payload_bytes: payload_bytes(event)
    }
  end

  defp elapsed(started_at) when is_integer(started_at),
    do: max(System.monotonic_time() - started_at, 0)

  defp elapsed(_started_at), do: 0

  defp content_bytes(%Event{content: content}) when is_binary(content), do: byte_size(content)
  defp content_bytes(_event), do: 0

  defp payload_bytes(%Event{payload: payload}) do
    case Jason.encode(payload || %{}) do
      {:ok, encoded} -> byte_size(encoded)
      {:error, _reason} -> 0
    end
  end

  defp payload_bytes(_event), do: 0

  defp telemetry_metadata(status, event) do
    %{
      stream_id: metadata_value(event, :stream_id),
      event_type: metadata_value(event, :event_type),
      project: metadata_value(event, :project),
      agent_id: metadata_value(event, :agent_id),
      session_id: metadata_value(event, :session_id),
      run_id: metadata_value(event, :run_id),
      status: status
    }
  end

  defp metadata_value(%Event{} = event, field),
    do: event |> Map.get(field) |> bounded_metadata()

  defp metadata_value(_event, _field), do: nil

  defp bounded_metadata(value) when is_binary(value) and byte_size(value) <= 256,
    do: if(String.valid?(value), do: value, else: nil)

  defp bounded_metadata(value) when is_binary(value) do
    if String.valid?(value), do: truncate_metadata(value), else: nil
  end

  defp bounded_metadata(_value), do: nil

  defp truncate_metadata(value) do
    value
    |> String.graphemes()
    |> Enum.reduce_while({[], 0}, fn grapheme, {acc, bytes} ->
      size = byte_size(grapheme)

      if bytes + size <= 256,
        do: {:cont, {[grapheme | acc], bytes + size}},
        else: {:halt, {acc, bytes}}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  defp emit_batch_telemetry({:ok, results}, started_at) when is_list(results) do
    Enum.each(results, &emit_telemetry({:ok, &1}, started_at))
  end

  defp emit_batch_telemetry({:error, reason}, started_at),
    do: emit_telemetry({:error, reason}, started_at)

  defp emit_batch_telemetry(_, _started_at), do: :ok
end

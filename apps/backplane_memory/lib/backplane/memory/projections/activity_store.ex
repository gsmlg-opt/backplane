defmodule Backplane.Memory.Projections.ActivityStore do
  @moduledoc "Revision-safe replacement and aggregation for canonical daily activity."

  import Ecto.Query

  alias Backplane.Memory.ActivityNotifier
  alias Backplane.Memory.Projections.{ActivityContribution, ActivityDaily}

  @processing_version "activity-v1"
  @dimensions ~w(memory_space_id date project agent_id host_id client_id scope namespace event_type)a
  @counters ~w(event_count session_count memory_count lesson_count crystal_count recall_count action_count error_count)a

  @doc "Replaces one subject contribution inside the caller's database transaction."
  def replace_subject!(subject_id, input_revision, partition, projected_rows)
      when is_binary(subject_id) and is_binary(input_revision) and is_list(projected_rows) do
    {:ok, partition} = Backplane.Memory.PartitionIdentity.validate(partition)

    rows =
      Enum.map(projected_rows, fn row ->
        row
        |> Map.put("memory_space_id", partition.memory_space_id)
        |> Map.put("source_client_id", partition[:source_client_id])
        |> normalize_row!()
      end)

    old_keys = subject_keys(subject_id)
    new_keys = Enum.map(rows, &key/1)
    affected_keys = Enum.sort(Enum.uniq(old_keys ++ new_keys))

    Enum.each(affected_keys, &lock_key!/1)
    repo().delete_all(from(c in ActivityContribution, where: c.subject_id == ^subject_id))

    now = now()

    if rows != [] do
      repo().insert_all(
        ActivityContribution,
        Enum.map(rows, fn row ->
          row
          |> Map.put(:subject_id, subject_id)
          |> Map.put(:processing_version, @processing_version)
          |> Map.put(:input_revision, input_revision)
          |> Map.put(:inserted_at, now)
          |> Map.put(:updated_at, now)
        end)
      )
    end

    Enum.each(affected_keys, &recompute_key!(&1, now))
    :ok = ActivityNotifier.enqueue(repo(), affected_keys)
    :ok
  end

  def replace_subject!(_subject_id, _input_revision, _partition, _rows),
    do: raise(ArgumentError, "invalid activity replacement")

  @doc false
  def recompute_keys!(keys) when is_list(keys) do
    keys = Enum.sort(Enum.uniq(keys))
    Enum.each(keys, &lock_key!/1)
    now = now()
    Enum.each(keys, &recompute_key!(&1, now))
    :ok
  end

  defp normalize_row!(row) when is_map(row) do
    normalized = %{
      memory_space_id: required_dimension!(value(row, :memory_space_id), :memory_space_id),
      date: date!(value(row, :date)),
      project: optional_dimension(value(row, :project)),
      agent_id: optional_dimension(value(row, :agent_id)),
      host_id: required_dimension!(value(row, :host_id), :host_id),
      client_id: required_dimension!(value(row, :client_id), :client_id),
      source_client_id: optional_dimension(value(row, :source_client_id)),
      scope: required_dimension!(value(row, :scope), :scope),
      namespace: required_dimension!(value(row, :namespace), :namespace),
      event_type: required_dimension!(value(row, :event_type), :event_type)
    }

    Enum.reduce(@counters, normalized, fn counter, acc ->
      Map.put(acc, counter, counter!(value(row, counter), counter))
    end)
  end

  defp value(row, key), do: Map.get(row, key, Map.get(row, Atom.to_string(key)))

  defp date!(%Date{} = date), do: date

  defp date!(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      {:error, reason} -> raise ArgumentError, "invalid activity date: #{inspect(reason)}"
    end
  end

  defp date!(_value), do: raise(ArgumentError, "invalid activity date")

  defp optional_dimension(nil), do: ""
  defp optional_dimension(value) when is_binary(value), do: value
  defp optional_dimension(_value), do: raise(ArgumentError, "invalid activity dimension")

  defp required_dimension!(value, _field) when is_binary(value) and byte_size(value) > 0,
    do: value

  defp required_dimension!(_value, field),
    do: raise(ArgumentError, "invalid activity #{field}")

  defp counter!(value, _field) when is_integer(value) and value >= 0, do: value
  defp counter!(_value, field), do: raise(ArgumentError, "invalid activity #{field}")

  defp subject_keys(subject_id) do
    repo().all(
      from(c in ActivityContribution,
        where: c.subject_id == ^subject_id,
        select: {
          c.memory_space_id,
          c.date,
          c.project,
          c.agent_id,
          c.host_id,
          c.client_id,
          c.scope,
          c.namespace,
          c.event_type
        }
      )
    )
  end

  defp key(row), do: @dimensions |> Enum.map(&Map.fetch!(row, &1)) |> List.to_tuple()

  defp lock_key!(key) do
    encoded = key |> Tuple.to_list() |> Enum.map_join("\u001f", &dimension_string/1)
    repo().query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [encoded])
  end

  defp dimension_string(%Date{} = date), do: Date.to_iso8601(date)
  defp dimension_string(value), do: value

  defp recompute_key!(key, now) do
    query = contribution_key_query(key)

    totals =
      repo().one(
        from(c in query,
          select: %{
            source_client_id: fragment("(array_agg(?))[1]", c.source_client_id),
            event_count: sum(c.event_count),
            session_count: sum(c.session_count),
            memory_count: sum(c.memory_count),
            lesson_count: sum(c.lesson_count),
            crystal_count: sum(c.crystal_count),
            recall_count: sum(c.recall_count),
            action_count: sum(c.action_count),
            error_count: sum(c.error_count)
          }
        )
      )

    if is_nil(totals.event_count) do
      repo().delete_all(daily_key_query(key))
    else
      identity = Map.take(totals, [:source_client_id])

      totals =
        totals
        |> Map.take(@counters)
        |> Map.new(fn {counter, value} -> {counter, Decimal.to_integer(value)} end)

      dimensions = Map.new(Enum.zip(@dimensions, Tuple.to_list(key)))

      repo().insert_all(
        ActivityDaily,
        [
          dimensions
          |> Map.merge(identity)
          |> Map.merge(totals)
          |> Map.merge(%{inserted_at: now, updated_at: now})
        ],
        on_conflict: {:replace, @counters ++ [:updated_at]},
        conflict_target: @dimensions
      )
    end
  end

  defp contribution_key_query(key), do: key_query(ActivityContribution, key)
  defp daily_key_query(key), do: key_query(ActivityDaily, key)

  defp key_query(schema, key) do
    Enum.zip(@dimensions, Tuple.to_list(key))
    |> Enum.reduce(schema, fn {field_name, field_value}, query ->
      where(query, [row], field(row, ^field_name) == ^field_value)
    end)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)
end

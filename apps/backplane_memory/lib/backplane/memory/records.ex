defmodule Backplane.Memory.Records do
  @moduledoc """
  Global memory store: remember, forget, inspect, search and list recent records.

  Provenance fields are descriptive only and never used to authorize access.
  """

  import Ecto.Query

  alias Backplane.Memory.Record
  alias Backplane.Memory.Records.Search

  @default_recent_limit 20
  @max_recent_limit 100
  @max_changed_limit 500

  @spec remember(map()) :: {:ok, Record.t()} | {:error, Ecto.Changeset.t()}
  def remember(attrs) when is_map(attrs) do
    attrs = prepare(attrs)

    with key when is_binary(key) <- attrs["request_key"],
         %Record{} = existing <- repo().get_by(Record, request_key: key) do
      {:ok, existing}
    else
      _ -> insert(attrs)
    end
  end

  @spec forget(Ecto.UUID.t(), String.t()) :: {:ok, Record.t()} | {:error, :not_found}
  def forget(id, reason) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %Record{} = record <- repo().get(Record, uuid) do
      if record.status != "active" do
        {:ok, record}
      else
        record
        |> Ecto.Changeset.change(%{
          status: "forgotten",
          forgotten_reason: reason,
          forgotten_at: DateTime.utc_now()
        })
        |> repo().update()
      end
    else
      _ -> {:error, :not_found}
    end
  end

  @spec get(Ecto.UUID.t()) ::
          {:ok, %{record: Record.t(), history: [Record.t()]}} | {:error, :not_found}
  def get(id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %Record{} = record <- repo().get(Record, uuid) do
      {:ok, %{record: record, history: history([record.id], [])}}
    else
      _ -> {:error, :not_found}
    end
  end

  @spec search(String.t(), map()) :: [Record.t()]
  defdelegate search(query, filters \\ %{}), to: Search

  @spec recent(map()) :: [Record.t()]
  def recent(filters \\ %{}) do
    limit = Search.clamp(filters["limit"], @default_recent_limit, @max_recent_limit)

    Record
    |> where([r], r.kind == "worklog" and r.status == "active")
    |> Search.filter_equal(:host_id, filters["host_id"])
    |> Search.filter_equal(:agent_id, filters["agent_id"])
    |> Search.filter_time(:since, filters["since"])
    |> order_by([r], desc: r.observed_at, desc: r.inserted_at)
    |> limit(^limit)
    |> repo().all()
  end

  @doc """
  Lists records newest-first without a text query. Accepts the same string-key
  filters as `search/2` (`host_id`, `agent_id`, `kind`, `include_inactive`, `limit`).
  """
  @spec list(map()) :: [Record.t()]
  def list(filters \\ %{}) do
    limit = Search.clamp(filters["limit"], @default_recent_limit, @max_recent_limit)

    Record
    |> then(fn q ->
      if filters["include_inactive"] == true, do: q, else: where(q, [r], r.status == "active")
    end)
    |> Search.filter_equal(:host_id, filters["host_id"])
    |> Search.filter_equal(:agent_id, filters["agent_id"])
    |> Search.filter_equal(:kind, filters["kind"])
    |> Search.filter_time(:since, filters["since"])
    |> Search.filter_time(:until, filters["until"])
    |> order_by([r], desc: r.observed_at, desc: r.inserted_at)
    |> limit(^limit)
    |> repo().all()
  end

  @doc """
  Records written by `host_id` (all statuses), ordered `updated_at, id` ascending and
  strictly after the optional `(updated_at, id)` cursor. `limit` is clamped to 1..500.
  """
  @spec changed_since(String.t(), nil | %{updated_at: DateTime.t(), id: Ecto.UUID.t()}, integer()) ::
          [Record.t()]
  def changed_since(host_id, cursor, limit) do
    limit = limit |> max(1) |> min(@max_changed_limit)

    Record
    |> where([r], r.host_id == ^host_id)
    |> after_cursor(cursor)
    |> order_by([r], asc: r.updated_at, asc: r.id)
    |> limit(^limit)
    |> repo().all()
  end

  defp after_cursor(query, nil), do: query

  defp after_cursor(query, %{updated_at: at, id: id}) do
    where(query, [r], r.updated_at > ^at or (r.updated_at == ^at and r.id > ^id))
  end

  @doc "Serializes a record to the string-keyed map returned by the memory tools and host pull."
  @spec to_map(Record.t()) :: map()
  def to_map(%Record{} = r) do
    %{
      "id" => r.id,
      "kind" => r.kind,
      "title" => r.title,
      "content" => r.content,
      "subjects" => r.subjects,
      "property" => r.property,
      "tags" => r.tags,
      "status" => r.status,
      "superseded_by" => r.superseded_by,
      "forgotten_reason" => r.forgotten_reason,
      "observed_at" => r.observed_at,
      "updated_at" => DateTime.to_iso8601(r.updated_at),
      "provenance" => %{
        "writer" => r.writer,
        "host" => r.host_id,
        "agent" => r.agent_id,
        "integration" => r.integration,
        "session" => r.session_id,
        "client" => r.client_id,
        "source_event_ids" => r.source_event_ids
      }
    }
  end

  @doc """
  Normalizes subjects to lowercase `type`/`key` maps and returns them with
  sorted, deduplicated `"type:key"` strings.
  """
  @spec normalize_subjects(list()) :: {[map()], [String.t()]}
  def normalize_subjects(subjects) when is_list(subjects) do
    normalized =
      subjects
      |> Enum.map(fn s -> {norm(s["type"] || s[:type]), norm(s["key"] || s[:key])} end)
      |> Enum.reject(fn {t, k} -> t == "" or k == "" end)
      |> Enum.uniq()
      |> Enum.sort()

    {Enum.map(normalized, fn {t, k} -> %{"type" => t, "key" => k} end),
     Enum.map(normalized, fn {t, k} -> "#{t}:#{k}" end)}
  end

  def normalize_subjects(_), do: {[], []}

  defp norm(nil), do: ""
  defp norm(v), do: v |> to_string() |> String.trim() |> String.downcase()

  defp prepare(attrs) do
    {subjects, keys} = normalize_subjects(attrs["subjects"] || [])

    attrs
    |> Map.put_new("kind", "note")
    |> Map.put_new_lazy("observed_at", &DateTime.utc_now/0)
    |> Map.put("subjects", subjects)
    |> Map.put("subject_keys", keys)
  end

  defp insert(attrs) do
    result =
      repo().transaction(fn ->
        case %Record{} |> Record.changeset(attrs) |> repo().insert() do
          {:ok, record} ->
            supersede(record)

          {:error, changeset} ->
            repo().rollback(changeset)
        end
      end)

    case result do
      {:ok, record} ->
        {:ok, record}

      {:error, %Ecto.Changeset{} = changeset} ->
        # Lost a request_key race: return the winner instead of failing.
        case attrs["request_key"] && repo().get_by(Record, request_key: attrs["request_key"]) do
          %Record{} = existing -> {:ok, existing}
          _ -> {:error, changeset}
        end
    end
  end

  # Supersession follows observation time, not arrival order: a fact observed
  # earlier than an active same-slot fact (e.g. an offline write uploaded late)
  # is stored already superseded by the newer one. Every status change bumps
  # `updated_at` so host pulls (`changed_since/3`) re-send the old row.
  defp supersede(%Record{kind: "fact", property: property, subject_keys: [_ | _]} = record)
       when is_binary(property) do
    same_slot =
      where(
        Record,
        [r],
        r.kind == "fact" and r.status == "active" and r.property == ^property and
          r.subject_keys == ^record.subject_keys and r.id != ^record.id
      )

    newer =
      same_slot
      |> where([r], r.observed_at > ^record.observed_at)
      |> order_by([r], desc: r.observed_at, desc: r.inserted_at)
      |> limit(1)
      |> repo().one()

    case newer do
      nil ->
        same_slot
        |> where([r], r.observed_at <= ^record.observed_at)
        |> repo().update_all(
          set: [status: "superseded", superseded_by: record.id, updated_at: DateTime.utc_now()]
        )

        record

      %Record{id: newer_id} ->
        record
        |> Ecto.Changeset.change(%{status: "superseded", superseded_by: newer_id})
        |> repo().update!()
    end
  end

  defp supersede(record), do: record

  defp history([], acc), do: acc |> Enum.sort_by(&{&1.observed_at, &1.inserted_at}, :desc)

  defp history(ids, acc) do
    older = Record |> where([r], r.superseded_by in ^ids) |> repo().all()
    history(Enum.map(older, & &1.id), acc ++ older)
  end

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)
end

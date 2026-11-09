defmodule Backplane.HostAgent.Memory.Local do
  @moduledoc """
  Host-local memory records and the remember/forget outbox.

  Record maps use the gateway's `Backplane.Memory.Records.to_map/1` keys. The
  `"id"` is the remote id once synced, else the local id; `"sync"` and
  `"local_id"` are host-only additions.
  """

  alias Backplane.HostAgent.Memory.{Store, UUID7}
  alias Turso.Result

  @default_store Store
  @columns ~w(local_id remote_id request_key kind title content subjects subject_keys property tags status
              superseded_by forgotten_reason writer agent_id integration session_id observed_at
              updated_at sync_state host_id client_id source_event_ids)

  @doc """
  Stores a pending local record and its `remember` outbox entry. Idempotent on
  `request_key`: an existing row with that key is returned unchanged.

  Options: `:host_id` — this host's id, kept as the record's provenance host.
  """
  @spec queue_remember(GenServer.server(), map(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def queue_remember(store \\ @default_store, args, request_key, opts \\ []) when is_map(args) do
    with {:ok, subjects} <- normalize_subjects(args["subjects"]) do
      tx(store, fn conn ->
        case find_by(conn, "request_key", request_key) do
          nil -> do_queue_remember(conn, args, request_key, subjects, opts)
          existing -> to_map(existing)
        end
      end)
    end
  end

  defp do_queue_remember(conn, args, request_key, subjects, opts) do
    now = now()
    observed_at = observed_at(args["observed_at"]) || now
    local_id = UUID7.generate()

    row = %{
      "local_id" => local_id,
      "remote_id" => nil,
      "request_key" => request_key,
      "kind" => args["kind"] || "note",
      "title" => args["title"],
      "content" => args["content"],
      "subjects" => encode(subjects),
      "subject_keys" => subject_keys(subjects),
      "property" => args["property"],
      "tags" => encode(args["tags"] || []),
      "status" => "active",
      "superseded_by" => nil,
      "forgotten_reason" => nil,
      "writer" => if(args["writer"] == "user", do: "user", else: "agent"),
      "agent_id" => args["agent"],
      "integration" => args["integration"],
      "session_id" => args["session_id"],
      "observed_at" => observed_at,
      "updated_at" => now,
      "sync_state" => "pending",
      "host_id" => Keyword.get(opts, :host_id),
      "client_id" => nil,
      "source_event_ids" => encode([])
    }

    # The original observation time travels with the upload so the gateway
    # orders supersession by when the memory was written, not when it synced.
    payload = Map.merge(args, %{"request_key" => request_key, "observed_at" => observed_at})

    insert_row(conn, row)
    enqueue(conn, "remember", local_id, payload, now)
    to_map(row)
  end

  defp observed_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.to_iso8601(datetime)
      {:error, _} -> nil
    end
  end

  defp observed_at(_value), do: nil

  @spec queue_forget(GenServer.server(), String.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found | term()}
  def queue_forget(store \\ @default_store, id, reason) do
    tx(store, fn conn ->
      case find(conn, id) do
        nil ->
          Store.rollback(conn, :not_found)

        %{"status" => "active"} = row ->
          now = now()

          exec!(
            conn,
            "UPDATE local_records SET status = 'forgotten', forgotten_reason = ?, updated_at = ?, sync_state = 'pending' WHERE local_id = ?",
            [reason, now, row["local_id"]]
          )

          enqueue(conn, "forget", row["local_id"], %{"reason" => reason}, now)

          to_map(%{
            row
            | "status" => "forgotten",
              "forgotten_reason" => reason,
              "updated_at" => now,
              "sync_state" => "pending"
          })

        row ->
          to_map(row)
      end
    end)
  end

  @spec upsert_remote(GenServer.server(), map()) :: {:ok, map()} | {:error, term()}
  def upsert_remote(store \\ @default_store, record) when is_map(record) do
    with {:ok, subjects} <- normalize_subjects(record["subjects"]) do
      tx(store, fn conn -> do_upsert(conn, record, subjects) end)
    end
  end

  @spec search(GenServer.server(), String.t(), map()) :: [map()]
  def search(store, query, filters \\ %{}) do
    terms =
      query |> String.split() |> Enum.filter(&(String.length(&1) >= 2))

    {term_sql, term_params} =
      Enum.reduce(terms, {[], []}, fn term, {sqls, params} ->
        like = "%" <> escape_like(term) <> "%"

        {["(title LIKE ? ESCAPE '\\' OR content LIKE ? ESCAPE '\\' OR subject_keys LIKE ? ESCAPE '\\')" | sqls],
         params ++ [like, like, like]}
      end)

    {filter_sql, filter_params} = filter_clauses(filters)
    limit = clamp(filters["limit"], 10, 50)

    where = Enum.join(term_sql ++ filter_sql ++ status_clause(filters["include_inactive"]), " AND ")

    rows =
      select_rows(
        store,
        "SELECT * FROM local_records #{where_sql(where)} ORDER BY observed_at DESC, local_id DESC LIMIT #{limit}",
        term_params ++ filter_params
      )

    Enum.map(rows, &to_map/1)
  end

  @spec get(GenServer.server(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(store \\ @default_store, id) do
    case find(store, id) do
      nil -> {:error, :not_found}
      row -> {:ok, to_map(row)}
    end
  end

  @spec recent(GenServer.server(), map()) :: [map()]
  def recent(store \\ @default_store, filters) do
    limit = clamp(filters["limit"], 20, 100)
    {filter_sql, params} = filter_clauses(Map.take(filters, ["agent", "since"]))
    where = Enum.join(["kind = 'worklog'", "status = 'active'" | filter_sql], " AND ")

    store
    |> select_rows(
      "SELECT * FROM local_records WHERE #{where} ORDER BY observed_at DESC, local_id DESC LIMIT #{limit}",
      params
    )
    |> Enum.map(&to_map/1)
  end

  @spec pending_outbox(GenServer.server(), pos_integer()) :: [map()]
  def pending_outbox(store \\ @default_store, limit) when is_integer(limit) and limit > 0 do
    store
    |> select_rows(
      "SELECT * FROM memory_outbox WHERE state = 'pending' ORDER BY seq LIMIT #{limit}",
      []
    )
    |> Enum.map(&Map.update!(&1, "payload", fn p -> Jason.decode!(p) end))
  end

  @spec complete(GenServer.server(), integer(), map()) :: :ok | {:error, term()}
  def complete(store \\ @default_store, seq, remote) do
    with {:ok, subjects} <- normalize_subjects(remote["subjects"]),
         {:ok, _} <-
           tx(store, fn conn ->
             exec!(conn, "DELETE FROM memory_outbox WHERE seq = ?", [seq])
             do_upsert(conn, remote, subjects)
           end),
         do: :ok
  end

  @max_error_bytes 1_000

  @doc "Truncates an error string to at most 1000 bytes, UTF-8 safe, with a trailing ellipsis."
  @spec truncate_error(term()) :: term()
  def truncate_error(error) when is_binary(error) and byte_size(error) > @max_error_bytes do
    trim_utf8(binary_part(error, 0, @max_error_bytes - 3)) <> "…"
  end

  def truncate_error(error), do: error

  defp trim_utf8(<<>>), do: <<>>

  defp trim_utf8(binary) do
    if String.valid?(binary),
      do: binary,
      else: trim_utf8(binary_part(binary, 0, byte_size(binary) - 1))
  end

  @spec fail(GenServer.server(), integer(), String.t()) :: :ok | {:error, term()}
  def fail(store \\ @default_store, seq, reason) do
    with {:ok, _} <-
           tx(store, fn conn ->
             now = now()

             case select_rows(conn, "SELECT local_id FROM memory_outbox WHERE seq = ?", [seq]) do
               [%{"local_id" => local_id}] ->
                 exec!(
                   conn,
                   "UPDATE memory_outbox SET state = 'failed', last_error = ?, attempts = attempts + 1, updated_at = ? WHERE seq = ?",
                   [truncate_error(reason), now, seq]
                 )

                 exec!(
                   conn,
                   "UPDATE local_records SET sync_state = 'failed' WHERE local_id = ?",
                   [local_id]
                 )

               [] ->
                 :ok
             end
           end),
         do: :ok
  end

  @spec bump_attempt(GenServer.server(), integer(), String.t()) :: :ok | {:error, term()}
  def bump_attempt(store \\ @default_store, seq, reason) do
    with {:ok, _} <-
           tx(store, fn conn ->
             exec!(
               conn,
               "UPDATE memory_outbox SET attempts = attempts + 1, last_error = ?, updated_at = ? WHERE seq = ?",
               [truncate_error(reason), now(), seq]
             )
           end),
         do: :ok
  end

  @spec get_state(GenServer.server(), String.t()) :: String.t() | nil
  def get_state(store \\ @default_store, key) do
    case select_rows(store, "SELECT value FROM memory_sync_state WHERE key = ?", [key]) do
      [%{"value" => value}] -> value
      [] -> nil
    end
  end

  @spec put_state(GenServer.server(), String.t(), String.t()) :: :ok | {:error, term()}
  def put_state(store \\ @default_store, key, value) do
    with {:ok, _} <-
           tx(store, fn conn ->
             exec!(conn, "DELETE FROM memory_sync_state WHERE key = ?", [key])
             exec!(conn, "INSERT INTO memory_sync_state(key, value) VALUES (?, ?)", [key, value])
           end),
         do: :ok
  end

  @spec stats(GenServer.server()) :: map()
  def stats(store \\ @default_store) do
    [counts] =
      select_rows(
        store,
        """
        SELECT
          (SELECT COUNT(*) FROM memory_outbox WHERE state = 'pending') AS outbox_pending,
          (SELECT COUNT(*) FROM memory_outbox WHERE state = 'failed') AS outbox_failed,
          (SELECT COUNT(*) FROM local_records) AS local_records
        """,
        []
      )

    last_failed_error =
      case select_rows(
             store,
             "SELECT last_error FROM memory_outbox WHERE state = 'failed' ORDER BY updated_at DESC, seq DESC LIMIT 1",
             []
           ) do
        [%{"last_error" => error}] -> truncate_error(error)
        [] -> nil
      end

    Map.merge(counts, %{
      "last_sync_at" => get_state(store, "last_sync_at"),
      "last_error" => get_state(store, "last_error"),
      "last_failed_error" => last_failed_error
    })
  end

  # -- internals --

  defp do_upsert(conn, record, subjects) do
    id = record["id"]
    prov = record["provenance"] || %{}
    request_key = record["request_key"]
    {target, duplicate} = upsert_target(conn, id, request_key)
    merge_duplicate(conn, target, duplicate)

    row = %{
      "local_id" => (target && target["local_id"]) || UUID7.generate(),
      "remote_id" => id,
      "request_key" => (target && target["request_key"]) || request_key,
      "kind" => record["kind"] || "note",
      "title" => record["title"],
      "content" => record["content"],
      "subjects" => encode(subjects),
      "subject_keys" => subject_keys(subjects),
      "property" => record["property"],
      "tags" => encode(record["tags"] || []),
      "status" => record["status"] || "active",
      "superseded_by" => record["superseded_by"],
      "forgotten_reason" => record["forgotten_reason"],
      "writer" => prov["writer"] || "agent",
      "agent_id" => prov["agent"],
      "integration" => prov["integration"],
      "session_id" => prov["session"],
      "observed_at" => record["observed_at"] || now(),
      "updated_at" => record["updated_at"] || now(),
      "sync_state" => "synced",
      "host_id" => prov["host"],
      "client_id" => prov["client"],
      "source_event_ids" => encode(prov["source_event_ids"] || [])
    }

    row = keep_local_forget(conn, target, duplicate, row)

    if target do
      sets = @columns -- ["local_id"]

      exec!(
        conn,
        "UPDATE local_records SET #{Enum.map_join(sets, ", ", &"#{&1} = ?")} WHERE local_id = ?",
        Enum.map(sets, &row[&1]) ++ [row["local_id"]]
      )
    else
      insert_row(conn, row)
    end

    to_map(row)
  end

  # The row matching the remote id and the row matching the request key can be
  # different (a pulled copy cached before its pending remember completed, or
  # data from before pulls carried request_key). The request_key row wins: it
  # keeps its local_id and absorbs the other row and its outbox entries.
  defp upsert_target(conn, id, request_key) do
    by_remote = is_binary(id) && find_by(conn, "remote_id", id)
    by_key = is_binary(request_key) && find_by(conn, "request_key", request_key)

    case {by_remote || nil, by_key || nil} do
      {nil, key_row} -> {key_row, nil}
      {remote_row, nil} -> {remote_row, nil}
      {%{"local_id" => same}, %{"local_id" => same} = key_row} -> {key_row, nil}
      {remote_row, key_row} -> {key_row, remote_row}
    end
  end

  defp merge_duplicate(_conn, _target, nil), do: :ok

  defp merge_duplicate(conn, target, duplicate) do
    exec!(conn, "UPDATE memory_outbox SET local_id = ? WHERE local_id = ?", [
      target["local_id"],
      duplicate["local_id"]
    ])

    exec!(conn, "DELETE FROM local_records WHERE local_id = ?", [duplicate["local_id"]])
  end

  # A locally forgotten record whose forget has not synced must not be
  # resurrected by a remote copy that still says active.
  defp keep_local_forget(_conn, nil, _duplicate, row), do: row

  defp keep_local_forget(conn, target, duplicate, row) do
    forgotten = Enum.find([target, duplicate], &(&1 && &1["status"] == "forgotten")) || target

    case select_rows(
           conn,
           "SELECT state FROM memory_outbox WHERE local_id = ? AND op = 'forget' ORDER BY seq DESC LIMIT 1",
           [target["local_id"]]
         ) do
      [%{"state" => state}] ->
        %{
          row
          | "status" => forgotten["status"],
            "forgotten_reason" => forgotten["forgotten_reason"],
            "sync_state" => if(state == "failed", do: "failed", else: "pending")
        }

      [] ->
        row
    end
  end

  defp insert_row(conn, row) do
    exec!(
      conn,
      "INSERT INTO local_records(#{Enum.join(@columns, ", ")}) VALUES (#{Enum.map_join(@columns, ", ", fn _ -> "?" end)})",
      Enum.map(@columns, &row[&1])
    )
  end

  defp enqueue(conn, op, local_id, payload, now) do
    exec!(
      conn,
      "INSERT INTO memory_outbox(op, local_id, payload, inserted_at, updated_at) VALUES (?, ?, ?, ?, ?)",
      [op, local_id, encode(payload), now, now]
    )
  end

  defp find(conn, id) do
    case select_rows(
           conn,
           "SELECT * FROM local_records WHERE remote_id = ? OR local_id = ? LIMIT 1",
           [id, id]
         ) do
      [row] -> row
      [] -> nil
    end
  end

  defp find_by(conn, column, value) when column in ~w(remote_id request_key) do
    case select_rows(conn, "SELECT * FROM local_records WHERE #{column} = ?", [value]) do
      [row] -> row
      [] -> nil
    end
  end

  defp to_map(row) do
    %{
      "id" => row["remote_id"] || row["local_id"],
      "local_id" => row["local_id"],
      "sync" => row["sync_state"],
      "kind" => row["kind"],
      "title" => row["title"],
      "content" => row["content"],
      "subjects" => decode(row["subjects"]),
      "property" => row["property"],
      "tags" => decode(row["tags"]),
      "status" => row["status"],
      "superseded_by" => row["superseded_by"],
      "forgotten_reason" => row["forgotten_reason"],
      "observed_at" => row["observed_at"],
      "updated_at" => row["updated_at"],
      "provenance" => %{
        "writer" => row["writer"],
        "host" => row["host_id"],
        "agent" => row["agent_id"],
        "integration" => row["integration"],
        "session" => row["session_id"],
        "client" => row["client_id"],
        "source_event_ids" => decode(row["source_event_ids"])
      }
    }
  end

  defp filter_clauses(filters) do
    subject = normalize_subject_key(filters["subject"])

    [
      {"subject", "(' ' || subject_keys || ' ') LIKE ? ESCAPE '\\'",
       subject && "% " <> escape_like(subject) <> " %"},
      {"kind", "kind = ?", filters["kind"]},
      {"agent", "agent_id = ?", filters["agent"]},
      {"since", "observed_at >= ?", filters["since"]}
    ]
    |> Enum.reject(fn {_, _, v} -> is_nil(v) end)
    |> Enum.map(fn {_, sql, v} -> {sql, v} end)
    |> Enum.unzip()
  end

  defp status_clause(true), do: []
  defp status_clause(_), do: ["status = 'active'"]

  defp where_sql(""), do: ""
  defp where_sql(where), do: "WHERE " <> where

  defp normalize_subjects(nil), do: {:ok, []}

  defp normalize_subjects(subjects) when is_list(subjects) do
    if Enum.all?(subjects, &is_map/1) do
      {:ok,
       subjects
       |> Enum.map(fn s -> {norm(s["type"]), norm(s["key"])} end)
       |> Enum.reject(fn {t, k} -> t == "" or k == "" end)
       |> Enum.uniq()
       |> Enum.sort()
       |> Enum.map(fn {t, k} -> %{"type" => t, "key" => k} end)}
    else
      {:error, :invalid_subjects}
    end
  end

  defp normalize_subjects(_), do: {:error, :invalid_subjects}

  defp subject_keys(subjects), do: Enum.map_join(subjects, " ", &"#{&1["type"]}:#{&1["key"]}")

  defp norm(nil), do: ""
  defp norm(v), do: v |> to_string() |> String.trim() |> String.downcase()

  defp normalize_subject_key(nil), do: nil
  defp normalize_subject_key(s) when is_binary(s), do: s |> String.trim() |> String.downcase()

  defp clamp(n, _default, max) when is_integer(n) and n > 0, do: min(n, max)
  defp clamp(_, default, _max), do: default

  defp escape_like(term) do
    term |> String.replace("\\", "\\\\") |> String.replace("%", "\\%") |> String.replace("_", "\\_")
  end

  defp encode(value), do: Jason.encode!(value)
  defp decode(nil), do: []
  defp decode(json), do: Jason.decode!(json)

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp select_rows(conn, sql, params) do
    {:ok, %Result{rows: rows}} = Store.query(conn, sql, params)
    rows
  end

  defp exec!(conn, sql, params) do
    case Store.execute(conn, sql, params) do
      {:ok, _} -> :ok
      {:error, reason} -> Store.rollback(conn, reason)
    end
  end

  # Runs `fun` in a transaction; a bare return is wrapped as {:ok, value},
  # rollbacks surface as {:error, reason}.
  defp tx(store, fun) do
    Store.transaction(store, fun)
  end
end

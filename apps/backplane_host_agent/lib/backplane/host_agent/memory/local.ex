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
  @columns ~w(local_id remote_id request_key kind title content subjects property tags status
              superseded_by forgotten_reason writer agent_id integration session_id observed_at
              updated_at sync_state)

  @spec queue_remember(GenServer.server(), map(), String.t()) :: {:ok, map()} | {:error, term()}
  def queue_remember(store \\ @default_store, args, request_key) when is_map(args) do
    now = now()
    local_id = UUID7.generate()

    row = %{
      "local_id" => local_id,
      "remote_id" => nil,
      "request_key" => request_key,
      "kind" => args["kind"] || "note",
      "title" => args["title"],
      "content" => args["content"],
      "subjects" => encode(normalize_subjects(args["subjects"])),
      "property" => args["property"],
      "tags" => encode(args["tags"] || []),
      "status" => "active",
      "superseded_by" => nil,
      "forgotten_reason" => nil,
      "writer" => if(args["writer"] == "user", do: "user", else: "agent"),
      "agent_id" => args["agent"],
      "integration" => args["integration"],
      "session_id" => args["session_id"],
      "observed_at" => now,
      "updated_at" => now,
      "sync_state" => "pending"
    }

    tx(store, fn conn ->
      insert_row(conn, row)
      enqueue(conn, "remember", local_id, Map.put(args, "request_key", request_key), now)
      to_map(row)
    end)
  end

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
    tx(store, fn conn -> do_upsert(conn, record) end)
  end

  @spec search(GenServer.server(), String.t(), map()) :: [map()]
  def search(store, query, filters \\ %{}) do
    terms =
      query |> String.split() |> Enum.filter(&(String.length(&1) >= 2))

    {term_sql, term_params} =
      Enum.reduce(terms, {[], []}, fn term, {sqls, params} ->
        like = "%" <> escape_like(term) <> "%"

        {["(title LIKE ? ESCAPE '\\' OR content LIKE ? ESCAPE '\\' OR subjects LIKE ? ESCAPE '\\')" | sqls],
         params ++ [like, like, like]}
      end)

    {filter_sql, filter_params} = filter_clauses(filters)
    subject = normalize_subject_key(filters["subject"])
    limit = clamp(filters["limit"], 10, 50)

    where = Enum.join(term_sql ++ filter_sql ++ status_clause(filters["include_inactive"]), " AND ")

    rows =
      select_rows(
        store,
        "SELECT * FROM local_records #{where_sql(where)} ORDER BY observed_at DESC, local_id DESC" <>
          if(subject, do: "", else: " LIMIT #{limit}"),
        term_params ++ filter_params
      )

    rows
    |> Enum.map(&to_map/1)
    |> Enum.filter(fn r -> is_nil(subject) or subject_match?(r, subject) end)
    |> Enum.take(limit)
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
  def pending_outbox(store \\ @default_store, limit) do
    store
    |> select_rows(
      "SELECT * FROM memory_outbox WHERE state = 'pending' ORDER BY seq LIMIT #{limit}",
      []
    )
    |> Enum.map(&Map.update!(&1, "payload", fn p -> Jason.decode!(p) end))
  end

  @spec complete(GenServer.server(), integer(), map()) :: :ok | {:error, term()}
  def complete(store \\ @default_store, seq, remote) do
    with {:ok, _} <-
           tx(store, fn conn ->
             exec!(conn, "DELETE FROM memory_outbox WHERE seq = ?", [seq])
             do_upsert(conn, remote)
           end),
         do: :ok
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
                   [reason, now, seq]
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
               [reason, now(), seq]
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

    Map.merge(counts, %{
      "last_sync_at" => get_state(store, "last_sync_at"),
      "last_error" => get_state(store, "last_error")
    })
  end

  # -- internals --

  defp do_upsert(conn, record) do
    id = record["id"]
    prov = record["provenance"] || %{}
    request_key = record["request_key"]

    target =
      find_by(conn, "remote_id", id) ||
        (request_key && find_by(conn, "request_key", request_key))

    row = %{
      "local_id" => (target && target["local_id"]) || UUID7.generate(),
      "remote_id" => id,
      "request_key" => (target && target["request_key"]) || request_key,
      "kind" => record["kind"] || "note",
      "title" => record["title"],
      "content" => record["content"],
      "subjects" => encode(record["subjects"] || []),
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
      "sync_state" => "synced"
    }

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
        "host" => nil,
        "agent" => row["agent_id"],
        "integration" => row["integration"],
        "session" => row["session_id"],
        "client" => nil,
        "source_event_ids" => []
      }
    }
  end

  defp filter_clauses(filters) do
    [
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

  defp normalize_subjects(subjects) when is_list(subjects) do
    subjects
    |> Enum.map(fn s -> {norm(s["type"]), norm(s["key"])} end)
    |> Enum.reject(fn {t, k} -> t == "" or k == "" end)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn {t, k} -> %{"type" => t, "key" => k} end)
  end

  defp normalize_subjects(_), do: []

  defp norm(nil), do: ""
  defp norm(v), do: v |> to_string() |> String.trim() |> String.downcase()

  defp normalize_subject_key(nil), do: nil
  defp normalize_subject_key(s) when is_binary(s), do: s |> String.trim() |> String.downcase()

  defp subject_match?(record, key) do
    Enum.any?(record["subjects"], fn s -> "#{s["type"]}:#{s["key"]}" == key end)
  end

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

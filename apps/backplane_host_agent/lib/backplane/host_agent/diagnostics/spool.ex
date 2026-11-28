defmodule Backplane.HostAgent.Diagnostics.Spool do
  @moduledoc "Host-owned diagnostics storage with durable identities and independently bounded bodies."

  use GenServer

  alias Backplane.DiagnosticsClient.{Envelope, Receipt, Redaction}

  @day 86_400
  @default_max_bytes 256 * 1024 * 1024
  @default_source_max_bytes 64 * 1024 * 1024
  @filesystem_reserve 1024 * 1024
  @critical_types ~w(exception worker_exit run_finished process_exit collector_health source_gap)

  @schema [
    """
    CREATE TABLE IF NOT EXISTS diagnostics_entries (
      source_id TEXT NOT NULL, event_id TEXT NOT NULL, epoch TEXT NOT NULL, sequence INTEGER NOT NULL,
      ingress_digest TEXT NOT NULL, forward_digest TEXT NOT NULL, body TEXT, bytes INTEGER NOT NULL,
      priority INTEGER NOT NULL, state TEXT NOT NULL, first_seen INTEGER NOT NULL,
      due_at INTEGER NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, disposed_at INTEGER, reason TEXT,
      PRIMARY KEY (source_id, event_id), UNIQUE (source_id, epoch, sequence)
    )
    """,
    "CREATE INDEX IF NOT EXISTS diagnostics_ready ON diagnostics_entries (due_at, priority, first_seen) WHERE state = 'pending'",
    "CREATE INDEX IF NOT EXISTS diagnostics_bodies ON diagnostics_entries (source_id, bytes, priority) WHERE bytes > 0",
    """
    CREATE TABLE IF NOT EXISTS diagnostics_sealed_epochs (
      source_id TEXT NOT NULL, epoch TEXT NOT NULL, sealed_at INTEGER NOT NULL,
      PRIMARY KEY (source_id, epoch)
    )
    """
  ]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  def ingest(server, source, batch_id, entries),
    do: GenServer.call(server, {:ingest, source, batch_id, entries}, :infinity)

  def ready(server, limit), do: GenServer.call(server, {:ready, limit})

  def settle(server, source_id, dispositions),
    do: GenServer.call(server, {:settle, source_id, dispositions})

  def maintain(server), do: GenServer.call(server, :maintain)

  def health(server, source_id \\ nil, timeout \\ 250),
    do: GenServer.call(server, {:health, source_id}, timeout)

  def seal_epoch(server, source_id, epoch), do: GenServer.call(server, {:seal, source_id, epoch})
  def dead_letters(server, source_id), do: GenServer.call(server, {:dead_letters, source_id})

  def requeue(server, source_id, event_id),
    do: GenServer.call(server, {:requeue, source_id, event_id})

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)
    disk_max_bytes = Keyword.get(opts, :disk_max_bytes, max(max_bytes, 8 * @filesystem_reserve))

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.touch(path),
         :ok <- File.chmod(path, 0o600),
         {:ok, db} <- Turso.start_link(database: path, pool_size: 1),
         :ok <- configure(db, disk_max_bytes) do
      {:ok,
       %{
         db: db,
         path: path,
         max_bytes: max_bytes,
         source_max_bytes: Keyword.get(opts, :source_max_bytes, @default_source_max_bytes),
         disk_max_bytes: disk_max_bytes,
         max_age: Keyword.get(opts, :max_age_seconds, 7 * @day),
         clock: Keyword.get(opts, :clock, fn -> System.system_time(:second) end),
         redact: Keyword.get(opts, :redact, &Redaction.project/1)
       }}
    else
      {:error, _} -> {:stop, :diagnostics_storage_unavailable}
    end
  end

  @impl true
  def handle_call({:ingest, source, batch_id, entries}, _from, state) do
    receipts = Enum.map(entries, &ingest_entry(state, source, &1))
    {:reply, Receipt.response(:local, batch_id, receipts), state}
  end

  def handle_call({:ready, limit}, _from, state) when is_integer(limit) and limit in 1..100 do
    sql = """
    SELECT source_id, event_id, forward_digest, body, attempts FROM diagnostics_entries
    WHERE state = 'pending' AND due_at <= ? AND source_id = (
      SELECT source_id FROM diagnostics_entries WHERE state = 'pending' AND due_at <= ?
      ORDER BY priority DESC, due_at, first_seen, source_id, event_id LIMIT 1
    ) ORDER BY priority DESC, due_at, first_seen, event_id LIMIT ?
    """

    now = state.clock.()
    {:reply, query(state.db, sql, [now, now, limit]), state}
  end

  def handle_call({:settle, source_id, dispositions}, _from, state) do
    result =
      transact(state.db, fn conn ->
        now = state.clock.()
        Enum.each(dispositions, &apply_disposition(conn, source_id, &1, now))
        prune_retired(conn, state, now)
      end)

    {:reply, result, state}
  end

  def handle_call(:maintain, _from, state) do
    result =
      transact(state.db, fn conn ->
        now = state.clock.()

        rows!(
          conn,
          """
          UPDATE diagnostics_entries SET state = 'expired', disposed_at = ?, reason = 'maximum_pending_age'
          WHERE rowid IN (SELECT rowid FROM diagnostics_entries WHERE state = 'pending' AND first_seen <= ? LIMIT 100)
          """,
          [now, now - state.max_age]
        )

        prune_retired(conn, state, now)
      end)

    with {:ok, :ok} <- result,
         {:ok, _rows} <- query(state.db, "PRAGMA wal_checkpoint(TRUNCATE)") do
      {:reply, result, state}
    else
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call({:health, source_id}, _from, state) do
    result =
      query(
        state.db,
        """
        SELECT state, count(*) AS count, COALESCE(sum(bytes), 0) AS bytes,
               min(first_seen) AS oldest, max(disposed_at) AS last_disposition
        FROM diagnostics_entries WHERE (? IS NULL OR source_id = ?) GROUP BY state
        """,
        [source_id, source_id]
      )

    {:reply, result, state}
  end

  def handle_call({:seal, source_id, epoch}, _from, state) do
    result =
      transact(state.db, fn conn ->
        if rows!(
             conn,
             "SELECT 1 FROM diagnostics_entries WHERE source_id = ? AND epoch = ? AND state = 'pending' LIMIT 1",
             [source_id, epoch]
           ) == [] do
          rows!(conn, "INSERT OR IGNORE INTO diagnostics_sealed_epochs VALUES (?, ?, ?)", [
            source_id,
            epoch,
            state.clock.()
          ])

          :ok
        else
          DBConnection.rollback(conn, :delivery_pending)
        end
      end)

    {:reply, result, state}
  end

  def handle_call({:dead_letters, source_id}, _from, state) do
    sql = """
    SELECT event_id, epoch, state, reason, attempts, first_seen, disposed_at, bytes
    FROM diagnostics_entries WHERE source_id = ? AND state IN ('dead_letter', 'expired')
    ORDER BY disposed_at DESC, event_id LIMIT 50
    """

    {:reply, query(state.db, sql, [source_id]), state}
  end

  def handle_call({:requeue, source_id, event_id}, _from, state) do
    result =
      transact(state.db, fn conn ->
        now = state.clock.()

        case rows!(
               conn,
               """
               SELECT epoch FROM diagnostics_entries
               WHERE source_id = ? AND event_id = ? AND state = 'dead_letter'
                 AND body IS NOT NULL AND first_seen > ?
               """,
               [source_id, event_id, now - state.max_age]
             ) do
          [%{"epoch" => epoch}] ->
            assert_empty(
              conn,
              "SELECT 1 FROM diagnostics_sealed_epochs WHERE source_id = ? AND epoch = ?",
              [source_id, epoch],
              :epoch_sealed
            )

            rows!(
              conn,
              """
              UPDATE diagnostics_entries SET state = 'pending', due_at = ?, reason = 'operator_requeue', disposed_at = NULL
              WHERE source_id = ? AND event_id = ?
              """,
              [now, source_id, event_id]
            )

            :ok

          [] ->
            DBConnection.rollback(conn, :not_recoverable)
        end
      end)

    {:reply, result, state}
  end

  defp ingest_entry(state, %{id: source_id} = source, entry) do
    with {:ok, %{"source_id" => ^source_id} = event, _, digest} <- Receipt.validate_entry(entry),
         true <- permits?(event, source),
         {:ok, status} <- transact(state.db, &store(&1, state, source, event, digest)) do
      Receipt.result(entry, status)
    else
      {:ok, _, _, _} ->
        Receipt.result(entry, "permanent_rejection", :unauthorized_source)

      false ->
        Receipt.result(entry, "permanent_rejection", :unauthorized_source)

      {:error, :unsupported_schema} ->
        Receipt.result(entry, "unsupported_schema")

      {:error, reason} when reason in [:identity_conflict, :source_sequence_conflict] ->
        Receipt.result(entry, "identity_conflict", reason)

      {:error, reason}
      when reason in [:quota_exceeded, :disk_capacity, :persistence_unavailable] ->
        Receipt.result(entry, "retryable_rejection", reason)

      {:error, reason} ->
        Receipt.result(entry, "permanent_rejection", reason)
    end
  end

  defp permits?(event, source) do
    event["application"] == source.application and
      match_value?(Map.get(source, :repository), get_in(event, ["version", "repository"])) and
      match_value?(Map.get(source, :service_instance), event["service_instance"])
  end

  defp match_value?(nil, _), do: true
  defp match_value?(expected, actual), do: expected == actual

  defp store(conn, state, source, event, digest) do
    sql =
      "SELECT ingress_digest, state FROM diagnostics_entries WHERE source_id = ? AND event_id = ?"

    case rows!(conn, sql, [source.id, event["event_id"]]) do
      [%{"ingress_digest" => ^digest, "state" => "expired"}] ->
        DBConnection.rollback(conn, :expired)

      [%{"ingress_digest" => ^digest, "state" => "dead_letter"}] ->
        DBConnection.rollback(conn, :dead_letter)

      [%{"ingress_digest" => ^digest}] ->
        "duplicate"

      [_other] ->
        DBConnection.rollback(conn, :identity_conflict)

      [] ->
        store_new(conn, state, source, event, digest)
    end
  end

  defp store_new(conn, state, source, event, digest) do
    epoch = event["producer_epoch"]
    sequence = event["source_sequence"]

    assert_empty(
      conn,
      "SELECT 1 FROM diagnostics_sealed_epochs WHERE source_id = ? AND epoch = ?",
      [source.id, epoch],
      :epoch_sealed
    )

    assert_empty(
      conn,
      "SELECT 1 FROM diagnostics_entries WHERE source_id = ? AND epoch = ? AND sequence = ?",
      [source.id, epoch, sequence],
      :source_sequence_conflict
    )

    case event |> state.redact.() |> Envelope.seal() do
      {:ok, bytes, forward_digest} ->
        now = state.clock.()
        size = byte_size(bytes)

        priority =
          if Map.get(source, :critical, false) and event["event_type"] in @critical_types,
            do: 1,
            else: 0

        assert_capacity(conn, state, source.id, size, priority)

        rows!(
          conn,
          """
          INSERT INTO diagnostics_entries
          (source_id, event_id, epoch, sequence, ingress_digest, forward_digest, body, bytes, priority, state, first_seen, due_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?, ?)
          """,
          [
            source.id,
            event["event_id"],
            epoch,
            sequence,
            digest,
            forward_digest,
            bytes,
            size,
            priority,
            now,
            now
          ]
        )

        "stored"

      {:error, reason} ->
        DBConnection.rollback(conn, reason)
    end
  end

  defp assert_capacity(conn, state, source_id, size, priority) do
    [used] =
      rows!(
        conn,
        """
        SELECT COALESCE(sum(bytes), 0) AS total,
               COALESCE(sum(CASE WHEN priority = 0 THEN bytes ELSE 0 END), 0) AS ordinary,
               COALESCE(sum(CASE WHEN source_id = ? THEN bytes ELSE 0 END), 0) AS source
        FROM diagnostics_entries WHERE bytes > 0
        """,
        [source_id]
      )

    cond do
      used["total"] + size > state.max_bytes or used["source"] + size > state.source_max_bytes ->
        DBConnection.rollback(conn, :quota_exceeded)

      priority == 0 and used["ordinary"] + size > div(state.max_bytes * 3, 4) ->
        DBConnection.rollback(conn, :quota_exceeded)

      disk_bytes(state.path) + size + @filesystem_reserve > state.disk_max_bytes ->
        DBConnection.rollback(conn, :disk_capacity)

      true ->
        :ok
    end
  end

  defp disk_bytes(path) do
    Enum.reduce([path, path <> "-wal", path <> "-shm"], 0, fn file, total ->
      case File.stat(file) do
        {:ok, %{size: size}} ->
          total + size

        {:error, :enoent} ->
          total

        {:error, reason} ->
          raise File.Error, reason: reason, action: "stat diagnostics spool", path: file
      end
    end)
  end

  defp assert_empty(conn, sql, parameters, reason) do
    if rows!(conn, sql, parameters) != [], do: DBConnection.rollback(conn, reason)
  end

  defp apply_disposition(conn, source_id, {id, digest, {:ack, status}}, now)
       when status in ~w(stored duplicate) do
    rows!(
      conn,
      """
      UPDATE diagnostics_entries SET state = 'confirmed', body = NULL, bytes = 0, disposed_at = ?, reason = ?
      WHERE source_id = ? AND event_id = ? AND forward_digest = ? AND state = 'pending'
      """,
      [now, status, source_id, id, digest]
    )
  end

  defp apply_disposition(conn, source_id, {id, digest, {:dead_letter, reason}}, now) do
    rows!(
      conn,
      """
      UPDATE diagnostics_entries SET state = 'dead_letter', disposed_at = ?, reason = ?
      WHERE source_id = ? AND event_id = ? AND forward_digest = ? AND state = 'pending'
      """,
      [now, reason, source_id, id, digest]
    )
  end

  defp apply_disposition(conn, source_id, {id, digest, {:retry, delay_seconds, reason}}, now) do
    rows!(
      conn,
      """
      UPDATE diagnostics_entries SET due_at = ?, attempts = attempts + 1, reason = ?
      WHERE source_id = ? AND event_id = ? AND forward_digest = ? AND state = 'pending'
      """,
      [now + delay_seconds, reason, source_id, id, digest]
    )
  end

  defp prune_retired(conn, state, now) do
    rows!(
      conn,
      """
      UPDATE diagnostics_entries SET body = NULL, bytes = 0 WHERE bytes > 0 AND state IN ('dead_letter', 'expired')
      AND (disposed_at <= ? OR rowid IN (
        SELECT rowid FROM (
          SELECT rowid, SUM(bytes) OVER (ORDER BY disposed_at DESC, rowid DESC) AS retained
          FROM diagnostics_entries WHERE bytes > 0 AND state IN ('dead_letter', 'expired')
        ) WHERE retained > ?
      ))
      """,
      [now - 7 * @day, div(state.max_bytes, 10)]
    )

    :ok
  end

  defp configure(db, disk_max_bytes) do
    with {:ok, [%{"journal_mode" => "wal"}]} <- query(db, "PRAGMA journal_mode=WAL"),
         {:ok, _} <- query(db, "PRAGMA synchronous=FULL"),
         {:ok, [%{"synchronous" => 2}]} <- query(db, "PRAGMA synchronous"),
         {:ok, [%{"page_size" => page_size}]} <- query(db, "PRAGMA page_size"),
         pages = max(1, div(disk_max_bytes - @filesystem_reserve, page_size)),
         {:ok, [%{"max_page_count" => ^pages}]} <- query(db, "PRAGMA max_page_count=#{pages}"),
         {:ok, _} <- query(db, "PRAGMA wal_autocheckpoint=100") do
      Enum.reduce_while(@schema, :ok, fn statement, :ok ->
        case query(db, statement) do
          {:ok, _} -> {:cont, :ok}
          {:error, _} = error -> {:halt, error}
        end
      end)
    else
      _ -> {:error, :storage_configuration_failed}
    end
  end

  defp transact(db, fun) do
    case DBConnection.transaction(db, fun) do
      {:error, reason} when not is_atom(reason) -> {:error, :persistence_unavailable}
      result -> result
    end
  rescue
    _error in [Turso.Error, DBConnection.ConnectionError, File.Error] ->
      {:error, :persistence_unavailable}
  end

  defp rows!(conn, sql, params) do
    case query(conn, sql, params) do
      {:ok, rows} -> rows
      {:error, reason} -> DBConnection.rollback(conn, reason)
    end
  end

  defp query(db, sql, params \\ []) do
    case Turso.query(db, sql, params) do
      {:ok, %Turso.Result{rows: rows}} -> {:ok, rows}
      {:error, _error} -> {:error, :persistence_unavailable}
    end
  end
end

defmodule Backplane.HostAgent.Memory.Spool.Turso do
  @moduledoc "Turso-backed durable spool for canonical host-capture envelopes."
  use GenServer
  @behaviour Backplane.HostAgent.Memory.Spool

  alias Backplane.HostAgent.Memory.{EventEnvelope, PrivacyFilter, Store}
  alias Backplane.HostAgent.Memory.Spool.Cipher
  alias Backplane.HostAgent.Telemetry
  alias Turso.Result

  @encryption_rewrite_key "encryption_rewrite_version"
  @encryption_rewrite_version "1"
  @encryption_verifier_key "encryption_key_verifier_v1"

  @schema [
    "CREATE TABLE IF NOT EXISTS capture_session_sequences (session_id TEXT PRIMARY KEY, sequence INTEGER NOT NULL)",
    """
    CREATE TABLE IF NOT EXISTS capture_event_spool (
      enqueue_id INTEGER PRIMARY KEY AUTOINCREMENT,
      event_id TEXT NOT NULL UNIQUE,
      idempotency_key TEXT NOT NULL UNIQUE,
      session_id TEXT,
      sequence INTEGER,
      envelope_json TEXT NOT NULL,
      envelope_bytes INTEGER NOT NULL,
      state TEXT NOT NULL DEFAULT 'pending',
      reason TEXT,
      attempts INTEGER NOT NULL DEFAULT 0,
      occurred_at TEXT NOT NULL,
      captured_at TEXT,
      enqueued_at TEXT NOT NULL,
      acknowledged_at TEXT,
      next_attempt_at TEXT
    )
    """,
    "CREATE INDEX IF NOT EXISTS capture_event_spool_pending_idx ON capture_event_spool(state, enqueue_id)",
    "CREATE INDEX IF NOT EXISTS capture_event_spool_session_idx ON capture_event_spool(session_id, sequence)",
    """
    CREATE TABLE IF NOT EXISTS capture_import_fingerprints (
      idempotency_key TEXT PRIMARY KEY,
      event_id TEXT NOT NULL UNIQUE,
      envelope_json TEXT NOT NULL,
      recorded_at TEXT NOT NULL
    )
    """,
    "CREATE INDEX IF NOT EXISTS capture_import_fingerprints_recorded_idx ON capture_import_fingerprints(recorded_at)",
    "CREATE TABLE IF NOT EXISTS capture_spool_counters (name TEXT PRIMARY KEY, value INTEGER NOT NULL DEFAULT 0)",
    "CREATE TABLE IF NOT EXISTS capture_spool_metadata (name TEXT PRIMARY KEY, value TEXT NOT NULL)"
  ]

  def child_spec(opts),
    do: %{id: Keyword.get(opts, :id, __MODULE__), start: {__MODULE__, :start_link, [opts]}}

  def start_link(opts) do
    case GenServer.start(__MODULE__, opts, name_option(opts)) do
      {:ok, pid} ->
        Process.link(pid)
        {:ok, pid}

      {:error, _reason} = error ->
        error
    end
  end

  def append(envelope), do: append(__MODULE__, envelope)

  @impl true
  def append(spool, envelope), do: GenServer.call(spool, {:append, envelope}, 15_000)

  def next_batch(max_events, max_bytes), do: next_batch(__MODULE__, max_events, max_bytes)

  @impl true
  def next_batch(spool, max_events, max_bytes),
    do: GenServer.call(spool, {:next_batch, max_events, max_bytes})

  def acknowledge(event_ids), do: acknowledge(__MODULE__, event_ids)

  @impl true
  def acknowledge(spool, event_ids), do: GenServer.call(spool, {:acknowledge, event_ids})

  def reject(event_id, reason, permanent?), do: reject(__MODULE__, event_id, reason, permanent?)

  @impl true
  def reject(spool, event_id, reason, permanent?),
    do: GenServer.call(spool, {:reject, event_id, reason, permanent?})

  def stats, do: stats(__MODULE__)

  @impl true
  def stats(spool), do: GenServer.call(spool, :stats)

  @doc "Returns transport state for one spooled event without exposing storage details."
  def event_status(event_id), do: event_status(__MODULE__, event_id)
  def event_status(spool, event_id), do: GenServer.call(spool, {:event_status, event_id})

  @impl true
  def init(opts) do
    store_opts =
      Keyword.drop(opts, [
        :id,
        :name,
        :checkpoint_fun,
        :encryption_key_env,
        :max_spool_bytes,
        :max_event_age_days,
        :retry_base_ms,
        :retry_max_ms,
        :compaction_batch_size,
        :compaction_grace_ms,
        :max_import_fingerprints,
        :clock,
        :jitter_fun
      ])

    with {:ok, cipher} <- Cipher.resolve(Keyword.get(opts, :encryption_key_env)) do
      checkpoint_fun = Keyword.get(opts, :checkpoint_fun, &checkpoint_truncate/1)
      start_store(store_opts, opts, cipher, checkpoint_fun)
    end
  end

  defp start_store(store_opts, opts, cipher, checkpoint_fun) do
    case Store.start_link(store_opts) do
      {:ok, store} ->
        Process.unlink(store)

        case safely_prepare_store(store, store_opts, cipher, checkpoint_fun) do
          {:ok, prepared_store} ->
            Process.link(prepared_store)

            state = %{
              store: prepared_store,
              store_ref: Process.monitor(prepared_store),
              cipher: cipher,
              max_spool_bytes: Keyword.get(opts, :max_spool_bytes, 64 * 1024 * 1024),
              max_event_age_ms: Keyword.get(opts, :max_event_age_days, 30) * 24 * 60 * 60 * 1_000,
              retry_base_ms: Keyword.get(opts, :retry_base_ms, 1_000),
              retry_max_ms: Keyword.get(opts, :retry_max_ms, 300_000),
              compaction_batch_size: Keyword.get(opts, :compaction_batch_size, 100),
              compaction_grace_ms: Keyword.get(opts, :compaction_grace_ms, 60_000),
              max_import_fingerprints: Keyword.get(opts, :max_import_fingerprints, 100_000),
              compaction_timer: nil,
              clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
              jitter_fun: Keyword.get(opts, :jitter_fun, &default_jitter/1)
            }

            {:ok, schedule_next_acknowledged(state)}

          {:error, reason} ->
            stop_store(store)
            {:stop, reason}
        end

      {:error, reason} ->
        {:stop, reason}
    end
  end

  defp safely_prepare_store(store, store_opts, cipher, checkpoint_fun) do
    try do
      prepare_store(store, store_opts, cipher, checkpoint_fun)
    rescue
      error -> {:error, {:spool_encryption_preparation_failed, error}}
    catch
      kind, reason -> {:error, {:spool_encryption_preparation_failed, {kind, reason}}}
    end
  end

  @impl true
  def terminate(_reason, %{store: store, store_ref: store_ref} = state) do
    if is_reference(state.compaction_timer), do: Process.cancel_timer(state.compaction_timer)
    Process.demonitor(store_ref, [:flush])
    if Process.alive?(store), do: GenServer.stop(store)
    :ok
  end

  @impl true
  def handle_call({:append, attrs}, _from, %{store: store} = state) do
    reply =
      case filter_payload(attrs) do
        {:ok, filtered_attrs} ->
          case duplicate(store, filtered_attrs, state.cipher) do
            {:ok, nil} ->
              insert(
                store,
                filtered_attrs,
                state.max_spool_bytes,
                state.max_import_fingerprints,
                state.clock,
                state.cipher
              )

            {:ok, envelope} ->
              {:duplicate, envelope}

            {:error, _} = error ->
              error
          end

        {:error, _} = error ->
          error
      end

    case reply do
      {:ok, envelope} -> Telemetry.capture_event(envelope["privacy"])
      _ -> :ok
    end

    {:reply, reply, state}
  end

  def handle_call({:next_batch, max_events, max_bytes}, _from, %{store: store} = state) do
    sql =
      "SELECT event.event_id, event.envelope_json FROM capture_event_spool AS event WHERE event.state = 'pending' AND (event.next_attempt_at IS NULL OR event.next_attempt_at <= ?) AND (event.session_id IS NULL OR NOT EXISTS (SELECT 1 FROM capture_event_spool AS earlier WHERE earlier.state = 'pending' AND earlier.session_id = event.session_id AND earlier.enqueue_id < event.enqueue_id AND earlier.next_attempt_at IS NOT NULL AND earlier.next_attempt_at > ?)) ORDER BY event.enqueue_id LIMIT ?"

    now = iso8601(state.clock.())

    events =
      case safe_query(store, sql, [now, now, max_events]) do
        {:ok, %Result{rows: rows}} ->
          select_batch(rows, max_bytes, state.cipher)

        {:error, reason} ->
          {:error, reason}
      end

    {:reply, events, state}
  end

  def handle_call({:acknowledge, []}, _from, state), do: {:reply, :ok, state}

  def handle_call({:acknowledge, event_ids}, _from, %{store: store} = state) do
    placeholders = Enum.map_join(event_ids, ",", fn _ -> "?" end)
    now = state.clock.() |> iso8601()

    result =
      safe_execute(
        store,
        "UPDATE capture_event_spool SET state = 'acknowledged', acknowledged_at = ? WHERE event_id IN (#{placeholders})",
        [now | event_ids]
      )

    state = if match?({:ok, _}, result), do: schedule_compaction(state), else: state

    {:reply, ok_result(result), state}
  end

  def handle_call({:reject, event_id, reason, permanent?}, _from, %{store: store} = state) do
    result = reject_event(store, event_id, reason, permanent?, state)

    if result == :updated do
      Telemetry.capture_rejection(permanent?)
    end

    reply = if result in [:updated, :not_found], do: :ok, else: result
    {:reply, reply, state}
  end

  def handle_call({:event_status, event_id}, _from, %{store: store} = state) do
    reply =
      case safe_query(
             store,
             "SELECT state, reason, attempts, occurred_at, next_attempt_at FROM capture_event_spool WHERE event_id = ?",
             [event_id]
           ) do
        {:ok, %Result{rows: [row]}} ->
          {:ok,
           %{
             state: decode_state(row["state"]),
             reason: row["reason"],
             attempts: number(row["attempts"]),
             next_attempt_at: row["next_attempt_at"],
             age_warning: age_warning?(row["occurred_at"], state)
           }}

        {:ok, %Result{rows: []}} ->
          {:error, :not_found}

        {:error, reason} ->
          {:error, reason}
      end

    {:reply, reply, state}
  end

  def handle_call(:stats, _from, %{store: store} = state) do
    sql = """
    SELECT
      SUM(CASE WHEN state = 'pending' THEN 1 ELSE 0 END) AS pending_depth,
      COALESCE(SUM(CASE WHEN state = 'pending' THEN envelope_bytes ELSE 0 END), 0) AS pending_bytes,
      MIN(CASE WHEN state = 'pending' THEN occurred_at END) AS oldest_occurred_at,
      MIN(CASE WHEN state = 'pending' THEN captured_at END) AS oldest_captured_at,
      MIN(CASE WHEN state = 'pending' THEN enqueued_at END) AS oldest_enqueued_at,
      COALESCE((SELECT value FROM capture_spool_counters WHERE name = 'retry_count'), 0) AS retry_count,
      SUM(CASE WHEN state = 'dead_letter' THEN 1 ELSE 0 END) AS dead_letter_count,
      COALESCE((SELECT value FROM capture_spool_counters WHERE name = 'captured_count'), 0) AS captured_count,
      COALESCE((SELECT value FROM capture_spool_counters WHERE name = 'redacted_count'), 0) AS redacted_count,
      COALESCE((SELECT value FROM capture_spool_counters WHERE name = 'rejected_count'), 0) AS rejected_count
    FROM capture_event_spool
    """

    stats =
      case safe_query(store, sql) do
        {:ok, %Result{rows: [row]}} ->
          %{
            pending_depth: number(row["pending_depth"]),
            pending_bytes: number(row["pending_bytes"]),
            oldest_occurred_at: row["oldest_occurred_at"],
            oldest_captured_at: row["oldest_captured_at"],
            oldest_enqueued_at: row["oldest_enqueued_at"],
            retry_count: number(row["retry_count"]),
            dead_letter_count: number(row["dead_letter_count"]),
            captured_count: number(row["captured_count"]),
            redacted_count: number(row["redacted_count"]),
            rejected_count: number(row["rejected_count"])
          }

        {:error, reason} ->
          {:error, reason}
      end

    stats =
      if is_map(stats) do
        Map.put(stats, :age_warning, age_warning?(stats.oldest_occurred_at, state))
      else
        stats
      end

    if is_map(stats), do: Telemetry.capture_spool(stats)

    {:reply, stats, state}
  end

  @impl true
  def handle_info(
        {:DOWN, store_ref, :process, store, reason},
        %{store: store, store_ref: store_ref} = state
      ) do
    {:stop, {:owned_store_down, reason}, state}
  end

  def handle_info(:compact_acknowledged, state) do
    state = clear_compaction_timer(state)
    cutoff = DateTime.add(state.clock.(), -state.compaction_grace_ms, :millisecond) |> iso8601()

    case compact_acknowledged(state.store, state.compaction_batch_size, cutoff) do
      {:ok, count} when count > 0 ->
        send(self(), :compact_acknowledged)
        {:noreply, %{state | compaction_timer: :queued}}

      {:ok, 0} ->
        {:noreply, schedule_next_acknowledged(state)}

      {:error, _reason} ->
        {:noreply, schedule_compaction(state)}
    end
  end

  defp select_batch(rows, max_bytes, cipher) do
    Enum.reduce_while(rows, {[], 0}, fn row, {acc, bytes} ->
      with {:ok, json} <- decode_storage(row["envelope_json"], row["event_id"], cipher),
           {:ok, event} <- Jason.decode(json) do
        event_bytes = byte_size(EventEnvelope.encode!(event))
        separator_bytes = if acc == [], do: 0, else: 1
        candidate_bytes = bytes + separator_bytes + event_bytes

        cond do
          acc == [] and event_bytes > max_bytes -> {:halt, {:oversized, event}}
          candidate_bytes <= max_bytes -> {:cont, {[event | acc], candidate_bytes}}
          true -> {:halt, {acc, bytes}}
        end
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:oversized, event} -> {:oversized, event}
      {:error, reason} -> {:error, reason}
      {events, _bytes} -> Enum.reverse(events)
    end
  end

  defp insert(store, attrs, max_spool_bytes, max_import_fingerprints, clock, cipher) do
    case safe_transaction(store, fn conn ->
           insert_transaction(
             conn,
             attrs,
             max_spool_bytes,
             max_import_fingerprints,
             clock,
             cipher
           )
         end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_transaction(conn, attrs, max_spool_bytes, max_import_fingerprints, clock, cipher) do
    session_id = value(attrs, :session_id)

    sequence =
      if session_id,
        do: reserve_sequence(conn, session_id, value(attrs, :sequence)),
        else: value(attrs, :sequence)

    attrs = put_value(attrs, :sequence, sequence)

    case EventEnvelope.build(attrs) do
      {:ok, envelope} ->
        json = EventEnvelope.encode!(envelope)
        stored_envelope = encode_storage(json, envelope["event_id"], cipher)
        now = clock.() |> iso8601()

        with :ok <- ensure_capacity(conn, byte_size(json), max_spool_bytes) do
          params = [
            envelope["event_id"],
            envelope["idempotency_key"],
            envelope["session_id"],
            envelope["sequence"],
            stored_envelope,
            byte_size(json),
            envelope["occurred_at"],
            envelope["captured_at"],
            now
          ]

          case Store.execute(
                 conn,
                 "INSERT INTO capture_event_spool(event_id,idempotency_key,session_id,sequence,envelope_json,envelope_bytes,occurred_at,captured_at,enqueued_at) VALUES (?,?,?,?,?,?,?,?,?)",
                 params
               ) do
            {:ok, _} ->
              with :ok <- increment_counter(conn, "captured_count", 1),
                   :ok <- increment_counter(conn, "redacted_count", redacted_count(envelope)),
                   :ok <- record_import_fingerprint(conn, envelope, stored_envelope, now),
                   :ok <- prune_import_fingerprints(conn, max_import_fingerprints) do
                {:ok, envelope}
              else
                {:error, reason} -> DBConnection.rollback(conn, reason)
              end

            {:error, reason} ->
              DBConnection.rollback(conn, reason)
          end
        else
          {:error, reason} -> DBConnection.rollback(conn, reason)
        end

      {:error, errors} ->
        DBConnection.rollback(conn, errors)
    end
  end

  defp reserve_sequence(store, session_id, sequence) when is_integer(sequence) and sequence > 0 do
    {:ok, _} =
      Store.execute(
        store,
        "INSERT INTO capture_session_sequences(session_id,sequence) VALUES (?,?) ON CONFLICT(session_id) DO UPDATE SET sequence = MAX(capture_session_sequences.sequence, excluded.sequence)",
        [session_id, sequence]
      )

    sequence
  end

  defp reserve_sequence(store, session_id, _sequence), do: next_sequence(store, session_id)

  defp next_sequence(store, session_id) do
    {:ok, %Result{rows: rows}} =
      Store.query(store, "SELECT sequence FROM capture_session_sequences WHERE session_id = ?", [
        session_id
      ])

    sequence =
      case rows do
        [%{"sequence" => value}] -> number(value) + 1
        [] -> 1
      end

    {:ok, _} =
      Store.execute(
        store,
        "INSERT INTO capture_session_sequences(session_id,sequence) VALUES (?,?) ON CONFLICT(session_id) DO UPDATE SET sequence = excluded.sequence",
        [session_id, sequence]
      )

    sequence
  end

  defp duplicate(store, attrs, cipher) do
    case safe_query(
           store,
           "SELECT event_id, idempotency_key, envelope_json FROM capture_event_spool WHERE event_id = ? OR idempotency_key = ?",
           [value(attrs, :event_id), value(attrs, :idempotency_key)]
         ) do
      {:ok, %Result{rows: []}} -> import_duplicate(store, attrs, cipher)
      {:ok, %Result{rows: [row]}} -> compare_duplicate(row, attrs, cipher)
      {:ok, %Result{rows: _rows}} -> {:error, :identity_collision}
      {:error, reason} -> {:error, reason}
    end
  end

  defp import_duplicate(store, attrs, cipher) do
    if value(attrs, :integration) == "claude_code_import" do
      case safe_query(
             store,
             "SELECT event_id, idempotency_key, envelope_json FROM capture_import_fingerprints WHERE event_id = ? OR idempotency_key = ?",
             [value(attrs, :event_id), value(attrs, :idempotency_key)]
           ) do
        {:ok, %Result{rows: []}} -> {:ok, nil}
        {:ok, %Result{rows: [row]}} -> compare_duplicate(row, attrs, cipher)
        {:ok, %Result{rows: _rows}} -> {:error, :identity_collision}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, nil}
    end
  end

  defp record_import_fingerprint(
         conn,
         %{"integration" => "claude_code_import"} = envelope,
         stored,
         now
       ) do
    case Store.execute(
           conn,
           "INSERT INTO capture_import_fingerprints(idempotency_key,event_id,envelope_json,recorded_at) VALUES (?,?,?,?)",
           [envelope["idempotency_key"], envelope["event_id"], stored, now]
         ) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp record_import_fingerprint(_conn, _envelope, _stored, _now), do: :ok

  defp prune_import_fingerprints(conn, limit) when is_integer(limit) and limit > 0 do
    with {:ok, %Result{rows: [%{"count" => count}]}} <-
           Store.query(conn, "SELECT COUNT(*) AS count FROM capture_import_fingerprints", []),
         excess when excess > 0 <- number(count) - limit,
         {:ok, _result} <-
           Store.execute(
             conn,
             "DELETE FROM capture_import_fingerprints WHERE idempotency_key IN (SELECT idempotency_key FROM capture_import_fingerprints ORDER BY recorded_at, idempotency_key LIMIT ?)",
             [excess]
           ) do
      :ok
    else
      excess when excess <= 0 -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp prune_import_fingerprints(_conn, _limit), do: {:error, :invalid_import_fingerprint_limit}

  defp compare_duplicate(row, attrs, cipher) do
    with {:ok, json} <- decode_storage(row["envelope_json"], row["event_id"], cipher),
         {:ok, stored} <- Jason.decode(json) do
      same_identity? =
        Enum.all?(~w(integration session_id event_type payload_hash), fn field ->
          stored[field] == value(attrs, String.to_atom(field))
        end)

      if same_identity?, do: {:ok, stored}, else: {:error, :identity_collision}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp prepare_store(store, store_opts, cipher, checkpoint_fun) do
    with :ok <- create_schema(store),
         {:ok, rewrite_required?} <- prepare_envelopes(store, cipher),
         :ok <- checkpoint_encrypted(store, cipher, checkpoint_fun),
         :ok <- seed_counters(store, cipher),
         {:ok, prepared_store} <-
           maybe_rewrite_database(store, store_opts, rewrite_required?, checkpoint_fun) do
      {:ok, prepared_store}
    end
  end

  defp create_schema(store) do
    with :ok <-
           Enum.reduce_while(@schema, :ok, fn sql, :ok ->
             case Store.execute(store, sql) do
               {:ok, _} -> {:cont, :ok}
               {:error, reason} -> {:halt, {:error, reason}}
             end
           end) do
      ensure_column(store, "next_attempt_at", "TEXT")
    end
  end

  defp prepare_envelopes(store, cipher) do
    case safe_transaction(store, fn conn -> prepare_envelopes_transaction(conn, cipher) end) do
      {:ok, rewrite_required?} -> {:ok, rewrite_required?}
      {:error, reason} -> {:error, reason}
    end
  end

  defp prepare_envelopes_transaction(conn, cipher) do
    with {:ok, %Result{rows: rows}} <-
           Store.query(
             conn,
             "SELECT event_id, envelope_json FROM capture_event_spool ORDER BY enqueue_id"
           ),
         {:ok, rewrite_status} <- encryption_rewrite_status(conn),
         {:ok, verifier} <- encryption_verifier(conn),
         :ok <- verify_encryption_mode(cipher, verifier),
         {:ok, {migrated_count, authenticated_count}} <-
           prepare_envelope_rows(conn, rows, cipher),
         :ok <-
           persist_encryption_verifier(
             conn,
             cipher,
             verifier,
             rewrite_status,
             authenticated_count
           ) do
      persist_rewrite_requirement(conn, cipher, rows, rewrite_status, migrated_count)
    else
      {:error, reason} -> DBConnection.rollback(conn, reason)
    end
  end

  defp prepare_envelope_rows(conn, rows, cipher) do
    Enum.reduce_while(rows, {:ok, {0, 0}}, fn row, {:ok, {migrated_count, authenticated_count}} ->
      case prepare_envelope(conn, row, cipher) do
        {:ok, :migrated} -> {:cont, {:ok, {migrated_count + 1, authenticated_count}}}
        {:ok, :authenticated} -> {:cont, {:ok, {migrated_count, authenticated_count + 1}}}
        {:ok, :plaintext} -> {:cont, {:ok, {migrated_count, authenticated_count}}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp encryption_rewrite_status(conn) do
    case Store.query(conn, "SELECT value FROM capture_spool_metadata WHERE name = ?", [
           @encryption_rewrite_key
         ]) do
      {:ok, %Result{rows: [%{"value" => value}]}} -> {:ok, value}
      {:ok, %Result{rows: []}} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp encryption_verifier(conn) do
    case Store.query(conn, "SELECT value FROM capture_spool_metadata WHERE name = ?", [
           @encryption_verifier_key
         ]) do
      {:ok, %Result{rows: [%{"value" => value}]}} -> {:ok, value}
      {:ok, %Result{rows: []}} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_encryption_mode(nil, nil), do: :ok
  defp verify_encryption_mode(nil, _verifier), do: {:error, :spool_encryption_required}
  defp verify_encryption_mode(_cipher, nil), do: :ok
  defp verify_encryption_mode(cipher, verifier), do: Cipher.verify(cipher, verifier)

  defp persist_encryption_verifier(
         _conn,
         _cipher,
         verifier,
         _rewrite_status,
         _authenticated_count
       )
       when is_binary(verifier),
       do: :ok

  defp persist_encryption_verifier(
         _conn,
         _cipher,
         nil,
         rewrite_status,
         0
       )
       when is_binary(rewrite_status),
       do: {:error, :spool_encryption_verifier_missing}

  defp persist_encryption_verifier(_conn, nil, nil, _rewrite_status, _authenticated_count),
    do: :ok

  defp persist_encryption_verifier(
         conn,
         cipher,
         nil,
         _rewrite_status,
         _authenticated_count
       ) do
    put_metadata(conn, @encryption_verifier_key, Cipher.encrypt_verifier(cipher))
  end

  defp persist_rewrite_requirement(_conn, nil, _rows, _status, _migrated_count),
    do: false

  defp persist_rewrite_requirement(conn, _cipher, rows, status, migrated_count) do
    rewrite_required? =
      migrated_count > 0 or status == "pending" or
        (rows != [] and status != @encryption_rewrite_version)

    target_status = if rewrite_required?, do: "pending", else: @encryption_rewrite_version

    case put_rewrite_status(conn, target_status) do
      :ok -> rewrite_required?
      {:error, reason} -> DBConnection.rollback(conn, reason)
    end
  end

  defp put_rewrite_status(store, status) do
    put_metadata(store, @encryption_rewrite_key, status)
  end

  defp put_metadata(store, name, value) do
    case Store.execute(
           store,
           "INSERT INTO capture_spool_metadata(name,value) VALUES (?,?) ON CONFLICT(name) DO UPDATE SET value = excluded.value",
           [name, value]
         ) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp prepare_envelope(_conn, %{"envelope_json" => stored}, nil) do
    cond do
      Cipher.encrypted?(stored) -> {:error, :spool_encryption_required}
      Cipher.ciphertext?(stored) -> {:error, :unsupported_spool_ciphertext_version}
      true -> {:ok, :plaintext}
    end
  end

  defp prepare_envelope(conn, %{"event_id" => event_id, "envelope_json" => stored}, cipher) do
    cond do
      Cipher.encrypted?(stored) ->
        with {:ok, json} <- Cipher.decrypt(cipher, stored, event_id),
             {:ok, _envelope} <- Jason.decode(json) do
          {:ok, :authenticated}
        end

      Cipher.ciphertext?(stored) ->
        {:error, :unsupported_spool_ciphertext_version}

      true ->
        encrypted = Cipher.encrypt(cipher, stored, event_id)

        case Store.execute(
               conn,
               "UPDATE capture_event_spool SET envelope_json = ? WHERE event_id = ?",
               [encrypted, event_id]
             ) do
          {:ok, _result} -> {:ok, :migrated}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp checkpoint_encrypted(_store, nil, _checkpoint_fun), do: :ok

  defp checkpoint_encrypted(store, _cipher, checkpoint_fun),
    do: run_checkpoint(store, checkpoint_fun)

  defp run_checkpoint(store, checkpoint_fun) do
    try do
      case checkpoint_fun.(store) do
        :ok -> :ok
        {:error, reason} -> {:error, {:spool_encryption_maintenance_failed, reason}}
        other -> {:error, {:spool_encryption_maintenance_failed, {:unexpected_result, other}}}
      end
    rescue
      error -> {:error, {:spool_encryption_maintenance_failed, error}}
    catch
      kind, reason -> {:error, {:spool_encryption_maintenance_failed, {kind, reason}}}
    end
  end

  defp maybe_rewrite_database(store, _store_opts, false, _checkpoint_fun),
    do: {:ok, store}

  defp maybe_rewrite_database(store, store_opts, true, checkpoint_fun) do
    database = Keyword.fetch!(store_opts, :database)
    rewrite_path = rewrite_path(database)

    try do
      with {:ok, _result} <- vacuum_into(store, rewrite_path),
           :ok <- stop_store(store),
           :ok <- remove_sqlite_sidecars(database),
           :ok <- File.rename(rewrite_path, database),
           {:ok, rewritten_store} <- Store.start_link(store_opts) do
        Process.unlink(rewritten_store)

        case finalize_rewrite(rewritten_store, checkpoint_fun) do
          :ok ->
            {:ok, rewritten_store}

          {:error, reason} ->
            stop_store(rewritten_store)
            {:error, reason}
        end
      else
        {:error, reason} -> {:error, {:spool_encryption_rewrite_failed, reason}}
      end
    after
      File.rm(rewrite_path)
    end
  end

  defp vacuum_into(store, rewrite_path) do
    escaped_path = String.replace(rewrite_path, "'", "''")
    safe_execute(store, "VACUUM INTO '#{escaped_path}'", [])
  end

  defp finalize_rewrite(store, checkpoint_fun) do
    with :ok <- put_rewrite_status(store, @encryption_rewrite_version),
         :ok <- run_checkpoint(store, checkpoint_fun) do
      :ok
    end
  end

  defp rewrite_path(database) do
    suffix = System.unique_integer([:positive, :monotonic])
    Path.join(Path.dirname(database), ".#{Path.basename(database)}.encryption-rewrite-#{suffix}")
  end

  defp remove_sqlite_sidecars(database) do
    Enum.reduce_while([database <> "-wal", database <> "-shm"], :ok, fn path, :ok ->
      case File.rm(path) do
        :ok -> {:cont, :ok}
        {:error, :enoent} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {path, reason}}}
      end
    end)
  end

  defp stop_store(store) do
    if Process.alive?(store), do: GenServer.stop(store)
    :ok
  end

  defp checkpoint_truncate(store) do
    case safe_query(store, "PRAGMA wal_checkpoint(TRUNCATE)") do
      {:ok, %Result{rows: [%{"busy" => busy}]}} ->
        if number(busy) != 0,
          do: {:error, :checkpoint_busy},
          else: :ok

      {:ok, %Result{rows: []}} ->
        :ok

      {:ok, %Result{rows: _unexpected}} ->
        {:error, :unexpected_checkpoint_result}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp encode_storage(json, _event_id, nil), do: json
  defp encode_storage(json, event_id, cipher), do: Cipher.encrypt(cipher, json, event_id)

  defp decode_storage(stored, _event_id, nil) do
    cond do
      Cipher.encrypted?(stored) -> {:error, :spool_encryption_required}
      Cipher.ciphertext?(stored) -> {:error, :unsupported_spool_ciphertext_version}
      true -> {:ok, stored}
    end
  end

  defp decode_storage(stored, event_id, cipher) do
    cond do
      Cipher.encrypted?(stored) -> Cipher.decrypt(cipher, stored, event_id)
      Cipher.ciphertext?(stored) -> {:error, :unsupported_spool_ciphertext_version}
      true -> {:ok, stored}
    end
  end

  defp ensure_column(store, column, type) do
    case Store.query(store, "PRAGMA table_info(capture_event_spool)") do
      {:ok, %Result{rows: rows}} ->
        if Enum.any?(rows, &(&1["name"] == column)) do
          :ok
        else
          case Store.execute(
                 store,
                 "ALTER TABLE capture_event_spool ADD COLUMN #{column} #{type}"
               ) do
            {:ok, _} -> :ok
            {:error, reason} -> {:error, reason}
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_capacity(store, event_bytes, max_spool_bytes) do
    case Store.query(
           store,
           "SELECT COALESCE(SUM(envelope_bytes), 0) AS used_bytes FROM capture_event_spool WHERE state != 'acknowledged'"
         ) do
      {:ok, %Result{rows: [%{"used_bytes" => used_bytes}]}} ->
        if number(used_bytes) + event_bytes <= max_spool_bytes,
          do: :ok,
          else: {:error, :spool_full}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp retry_due_at(_attempts, true, _state), do: nil

  defp retry_due_at(attempts, false, state) do
    exponent = min(attempts - 1, 30)
    base_delay = min(state.retry_base_ms * Integer.pow(2, exponent), state.retry_max_ms)
    jitter = bounded_jitter(state.jitter_fun.(base_delay), base_delay)
    delay = min(base_delay + jitter, state.retry_max_ms)

    state.clock.()
    |> DateTime.add(delay, :millisecond)
    |> iso8601()
  end

  defp reject_event(store, event_id, reason, permanent?, state) do
    case safe_transaction(store, fn conn ->
           case Store.query(conn, "SELECT attempts FROM capture_event_spool WHERE event_id = ?", [
                  event_id
                ]) do
             {:ok, %Result{rows: []}} ->
               :not_found

             {:ok, %Result{rows: [%{"attempts" => attempts}]}} ->
               attempt = number(attempts) + 1
               target_state = if permanent?, do: "dead_letter", else: "pending"
               next_attempt_at = retry_due_at(attempt, permanent?, state)

               with {:ok, _} <-
                      Store.execute(
                        conn,
                        "UPDATE capture_event_spool SET state = ?, reason = ?, attempts = ?, next_attempt_at = ? WHERE event_id = ?",
                        [target_state, encode_reason(reason), attempt, next_attempt_at, event_id]
                      ),
                    :ok <- increment_counter(conn, "rejected_count", 1),
                    :ok <- increment_counter(conn, "retry_count", if(permanent?, do: 0, else: 1)) do
                 :updated
               else
                 {:error, update_reason} -> DBConnection.rollback(conn, update_reason)
               end

             {:error, query_reason} ->
               DBConnection.rollback(conn, query_reason)
           end
         end) do
      {:ok, result} -> result
      {:error, transaction_reason} -> {:error, transaction_reason}
    end
  end

  defp bounded_jitter(value, delay) when is_integer(value),
    do: value |> max(0) |> min(div(delay, 4))

  defp bounded_jitter(_value, _delay), do: 0

  defp default_jitter(delay) when delay > 0, do: :rand.uniform(max(div(delay, 4), 1)) - 1
  defp default_jitter(_delay), do: 0

  defp compact_acknowledged(store, batch_size, cutoff) do
    case safe_execute(
           store,
           "DELETE FROM capture_event_spool WHERE enqueue_id IN (SELECT enqueue_id FROM capture_event_spool WHERE state = 'acknowledged' AND acknowledged_at <= ? ORDER BY enqueue_id LIMIT ?)",
           [cutoff, batch_size]
         ) do
      {:ok, %Result{num_rows: count}} -> {:ok, count}
      {:error, reason} -> {:error, reason}
    end
  end

  defp schedule_compaction(%{compaction_timer: nil} = state) do
    timer = Process.send_after(self(), :compact_acknowledged, state.compaction_grace_ms)
    %{state | compaction_timer: timer}
  end

  defp schedule_compaction(state), do: state

  defp schedule_next_acknowledged(state) do
    case safe_query(
           state.store,
           "SELECT MIN(acknowledged_at) AS acknowledged_at FROM capture_event_spool WHERE state = 'acknowledged'"
         ) do
      {:ok, %Result{rows: [%{"acknowledged_at" => nil}]}} ->
        state

      {:ok, %Result{rows: [%{"acknowledged_at" => acknowledged_at}]}} ->
        delay = compaction_delay(acknowledged_at, state)
        timer = Process.send_after(self(), :compact_acknowledged, delay)
        %{state | compaction_timer: timer}

      {:error, _reason} ->
        schedule_compaction(state)
    end
  end

  defp compaction_delay(acknowledged_at, state) do
    case DateTime.from_iso8601(acknowledged_at) do
      {:ok, acknowledged, _offset} ->
        deadline = DateTime.add(acknowledged, state.compaction_grace_ms, :millisecond)
        max(DateTime.diff(deadline, state.clock.(), :millisecond), 0)

      _ ->
        state.compaction_grace_ms
    end
  end

  defp clear_compaction_timer(%{compaction_timer: timer} = state) when is_reference(timer) do
    Process.cancel_timer(timer)
    %{state | compaction_timer: nil}
  end

  defp clear_compaction_timer(state), do: %{state | compaction_timer: nil}

  defp age_warning?(nil, _state), do: false

  defp age_warning?(occurred_at, state) do
    case DateTime.from_iso8601(occurred_at) do
      {:ok, occurred, _offset} ->
        DateTime.diff(state.clock.(), occurred, :millisecond) > state.max_event_age_ms

      _ ->
        false
    end
  end

  defp iso8601(%DateTime{} = datetime) do
    %{datetime | microsecond: {elem(datetime.microsecond, 0), 6}}
    |> DateTime.to_iso8601()
  end

  defp increment_counter(_store, _name, 0), do: :ok

  defp increment_counter(store, name, amount) do
    case Store.execute(
           store,
           "INSERT INTO capture_spool_counters(name,value) VALUES (?,?) ON CONFLICT(name) DO UPDATE SET value = value + excluded.value",
           [name, amount]
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp seed_counters(store, cipher) do
    sources = [
      {"captured_count", "SELECT COUNT(*) AS value FROM capture_event_spool"},
      {"redacted_count", :encrypted_envelopes},
      {"rejected_count", "SELECT COALESCE(SUM(attempts), 0) AS value FROM capture_event_spool"},
      {"retry_count",
       "SELECT COALESCE(SUM(CASE WHEN state != 'dead_letter' THEN attempts ELSE 0 END), 0) AS value FROM capture_event_spool"}
    ]

    Enum.reduce_while(sources, :ok, fn {name, source}, :ok ->
      case Store.query(store, "SELECT value FROM capture_spool_counters WHERE name = ?", [name]) do
        {:ok, %Result{rows: [_row]}} ->
          {:cont, :ok}

        {:ok, %Result{rows: []}} ->
          with {:ok, value} <- counter_seed_value(store, source, cipher),
               {:ok, _result} <-
                 Store.execute(
                   store,
                   "INSERT INTO capture_spool_counters(name,value) VALUES (?,?)",
                   [name, value]
                 ) do
            {:cont, :ok}
          else
            {:error, reason} -> {:halt, {:error, reason}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp counter_seed_value(store, select_sql, _cipher) when is_binary(select_sql) do
    case Store.query(store, select_sql) do
      {:ok, %Result{rows: [%{"value" => value}]}} -> {:ok, number(value)}
      {:ok, %Result{rows: rows}} -> {:error, {:unexpected_counter_seed_result, rows}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp counter_seed_value(store, :encrypted_envelopes, cipher) do
    case Store.query(store, "SELECT event_id, envelope_json FROM capture_event_spool") do
      {:ok, %Result{rows: rows}} ->
        Enum.reduce_while(rows, {:ok, 0}, fn row, {:ok, count} ->
          with {:ok, json} <- decode_storage(row["envelope_json"], row["event_id"], cipher),
               {:ok, envelope} <- Jason.decode(json) do
            {:cont, {:ok, count + redacted_count(envelope)}}
          else
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp redacted_count(envelope) do
    if get_in(envelope, ["privacy", "redaction_count"]) > 0, do: 1, else: 0
  end

  defp safe_query(store, sql, params \\ []) do
    try do
      Store.query(store, sql, params)
    rescue
      error -> {:error, error}
    catch
      :exit, reason -> {:error, reason}
    end
  end

  defp safe_execute(store, sql, params) do
    try do
      Store.execute(store, sql, params)
    rescue
      error -> {:error, error}
    catch
      :exit, reason -> {:error, reason}
    end
  end

  defp safe_transaction(store, fun) do
    try do
      Store.transaction(store, fun)
    rescue
      error -> {:error, error}
    catch
      :exit, reason -> {:error, reason}
    end
  end

  defp value(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))

  defp filter_payload(attrs) do
    case value(attrs, :payload) do
      payload when is_map(payload) ->
        if EventEnvelope.valid_payload?(payload) do
          filter_valid_payload(attrs, payload)
        else
          {:error, [:payload]}
        end

      _ ->
        {:ok, attrs}
    end
  end

  defp filter_valid_payload(attrs, payload) do
    {filtered_payload, payload_privacy} = PrivacyFilter.filter(payload)
    {filtered_trace, trace_privacy} = filter_trace(value(attrs, :trace))
    privacy = merge_privacy(payload_privacy, trace_privacy)

    attrs =
      attrs
      |> put_value(:payload, filtered_payload)
      |> put_value(:privacy, privacy)
      |> put_value(:payload_hash, EventEnvelope.payload_hash(filtered_payload))

    attrs = if is_nil(filtered_trace), do: attrs, else: put_value(attrs, :trace, filtered_trace)
    {:ok, attrs}
  end

  defp filter_trace(nil), do: {nil, empty_privacy()}

  defp filter_trace(trace) when is_map(trace) do
    {filtered, privacy} = PrivacyFilter.filter(trace)

    trace =
      Enum.reduce(~w(correlation_id causation_id), %{}, fn key, acc ->
        case Map.get(filtered, key) || Map.get(filtered, String.to_atom(key)) do
          value when is_binary(value) ->
            if valid_trace_identifier?(key, value), do: Map.put(acc, key, value), else: acc

          _value ->
            acc
        end
      end)

    {trace, privacy}
  end

  defp filter_trace(_trace), do: {%{}, empty_privacy()}

  defp valid_trace_identifier?("causation_id", value), do: uuid?(value)

  defp valid_trace_identifier?("correlation_id", value),
    do: Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\z/, value)

  defp uuid?(value),
    do:
      Regex.match?(
        ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}\z/,
        value
      )

  defp merge_privacy(payload_privacy, trace_privacy) do
    payload_privacy
    |> Map.update!("redaction_count", &(&1 + trace_privacy["redaction_count"]))
    |> Map.update!(
      "private_blocks_removed",
      &(&1 + trace_privacy["private_blocks_removed"])
    )
  end

  defp empty_privacy do
    %{
      "filtered" => true,
      "filter_version" => "1",
      "redaction_count" => 0,
      "private_blocks_removed" => 0
    }
  end

  defp put_value(map, key, value) when is_map_key(map, key), do: Map.put(map, key, value)
  defp put_value(map, key, value), do: Map.put(map, to_string(key), value)
  defp ok_result({:ok, _}), do: :ok
  defp ok_result({:error, reason}), do: {:error, reason}
  defp number(nil), do: 0
  defp number(value) when is_integer(value), do: value
  defp number(value) when is_binary(value), do: String.to_integer(value)
  defp encode_reason(reason) when is_binary(reason), do: reason
  defp encode_reason(reason), do: inspect(reason)
  defp decode_state("pending"), do: :pending
  defp decode_state("acknowledged"), do: :acknowledged
  defp decode_state("dead_letter"), do: :dead_letter

  defp name_option(opts) do
    case Keyword.fetch(opts, :name) do
      :error -> [name: __MODULE__]
      {:ok, nil} -> []
      {:ok, name} -> [name: name]
    end
  end
end

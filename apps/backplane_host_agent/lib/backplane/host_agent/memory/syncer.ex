defmodule Backplane.HostAgent.Memory.Syncer do
  @moduledoc """
  Drains local host-agent memory outbox rows to the hub channel.
  """

  use GenServer

  alias Backplane.HostAgent.{Channel, MemoryProxy}
  alias Backplane.HostAgent.Memory.{Reducer, Store}
  alias Turso.Result

  @protocol "host_memory.v1"
  @default_batch_size 50
  @max_batch_size 50
  @max_payload_bytes 512 * 1024
  @default_interval_ms 5_000
  @default_max_attempts 5
  @max_retry_delay_ms :timer.minutes(5)

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  def start_link(opts) do
    name = Keyword.get(opts, :name)

    if name do
      GenServer.start_link(__MODULE__, opts, name: name)
    else
      GenServer.start_link(__MODULE__, opts)
    end
  end

  @impl true
  def init(opts) do
    state = normalize_opts(opts)

    case recover_inflight(state) do
      :ok ->
        schedule_drain(state)
        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_info(:drain, state) do
    _ = drain_once(state)
    schedule_drain(state)
    {:noreply, state}
  end

  @doc "Drains one batch of pending outbox rows if a channel is available."
  def drain_once(opts \\ []) do
    opts = normalize_opts(opts)

    with :ok <- recover_inflight(opts),
         {:ok, channel} <- connected_channel(opts),
         {:ok, outbox_rows} <- claim_pending(opts.store, opts.batch_size, now(opts)) do
      if outbox_rows == [] do
        {:ok, %{"drained" => 0}}
      else
        with {:ok, {items, failed_rows}} <- build_payload_items(opts, outbox_rows),
             pushed_rows = outbox_rows -- failed_rows,
             {items, deferred_rows} = fit_payload(items, pushed_rows),
             pushed_rows = pushed_rows -- deferred_rows,
             :ok <- reset_pending(opts, Enum.map(deferred_rows, & &1["seq"])) do
          payload = %{"protocol" => @protocol, "items" => items}

          if items == [] do
            {:ok, %{"drained" => 0}}
          else
            case push_sync(opts.channel_module, channel, payload) do
              {:ok, %{"items" => ack_items}} ->
                if valid_acks?(pushed_rows, ack_items) do
                  case apply_acks(opts, pushed_rows, ack_items) do
                    :ok -> {:ok, %{"drained" => length(items)}}
                    {:error, reason} -> {:error, reason}
                  end
                else
                  case retry_rows(opts, pushed_rows, "invalid acknowledgement") do
                    :ok -> {:error, :invalid_ack}
                    {:error, reason} -> {:error, reason}
                  end
                end

              {:ok, _reply} ->
                retry_result(opts, pushed_rows, "invalid acknowledgement", :invalid_ack)

              {:error, reason} ->
                retry_result(opts, pushed_rows, reason, reason)
            end
          end
        else
          {:error, reason} -> {:error, reason}
        end
      end
    else
      {:error, :not_connected} -> {:ok, %{"drained" => 0, "status" => "disconnected"}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Returns the host-agent channel join payload containing memory scope hashes."
  def join_payload(opts \\ []) do
    opts = normalize_opts(opts)

    scopes =
      opts.store
      |> active_scopes(opts.config)
      |> Enum.map(fn scope ->
        %{"scope" => scope, "fact_set_hash" => fact_set_hash(opts.store, scope)}
      end)

    %{"memory" => %{"protocol" => @protocol, "scopes" => scopes}}
  end

  @doc "Returns the SHA-256 hash of canonical facts for one scope."
  def fact_set_hash(store, scope) do
    sql = """
    SELECT id, content, content_hash, tags, metadata, updated_at
    FROM facts
    WHERE scope = ?
    ORDER BY id, updated_at
    """

    case safe_query(store, sql, [scope]) do
      {:ok, %Result{rows: rows}} ->
        rows
        |> Enum.map(fn row ->
          %{
            "id" => row["id"],
            "content" => row["content"],
            "content_hash" => row["content_hash"],
            "tags" => Reducer.decode_json(row["tags"], []),
            "metadata" => Reducer.decode_json(row["metadata"], %{}),
            "updated_at" => row["updated_at"]
          }
        end)
        |> Jason.encode!()
        |> sha256()

      {:error, _reason} ->
        empty_fact_set_hash()
    end
  end

  defp claim_pending(store, batch_size, now) do
    transaction(store, fn conn ->
      case Store.query(
             conn,
             """
             SELECT seq, op, memory_id, attempts
             FROM memory_outbox
             WHERE state = 'pending' OR (state = 'retry_wait' AND next_attempt_at <= ?)
             ORDER BY seq
             LIMIT ?
             """,
             [now, batch_size]
           ) do
        {:ok, %Result{rows: []}} ->
          []

        {:ok, %Result{rows: rows}} ->
          seqs = Enum.map(rows, & &1["seq"])
          placeholders = placeholders(seqs)

          case Store.execute(
                 conn,
                 "UPDATE memory_outbox SET state = 'inflight', next_attempt_at = NULL, updated_at = ? WHERE seq IN (#{placeholders}) AND state IN ('pending', 'retry_wait')",
                 [now | seqs]
               ) do
            {:ok, _result} -> rows
            {:error, reason} -> DBConnection.rollback(conn, {:storage_error, reason})
          end

        {:error, reason} ->
          DBConnection.rollback(conn, {:storage_error, reason})
      end
    end)
  end

  defp recover_inflight(opts) do
    with {:ok, %Result{rows: rows}} <-
           Store.query(
             opts.store,
             "SELECT seq, attempts FROM memory_outbox WHERE state = 'inflight' ORDER BY seq"
           ),
         :ok <-
           retry_rows(
             opts,
             Enum.map(rows, &Map.put(&1, "memory_id", nil)),
             "recovered after restart"
           ) do
      :ok
    else
      {:error, reason} -> {:error, {:storage_error, reason}}
    end
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end

  defp build_payload_items(opts, outbox_rows) do
    Enum.reduce_while(outbox_rows, {:ok, {[], []}}, fn row, {:ok, {items, failed_rows}} ->
      case payload_item(opts.store, row) do
        {:ok, item} ->
          {:cont, {:ok, {[item | items], failed_rows}}}

        {:error, reason} ->
          case dead_letter(opts.store, row["seq"], reason, now(opts)) do
            {:ok, _} -> {:cont, {:ok, {items, [row | failed_rows]}}}
            {:error, error} -> {:halt, {:error, {:storage_error, error}}}
          end
      end
    end)
    |> then(fn
      {:ok, {items, failed_rows}} -> {:ok, {Enum.reverse(items), failed_rows}}
      error -> error
    end)
  end

  defp payload_item(store, %{"op" => "remember", "seq" => seq, "memory_id" => memory_id}) do
    with {:ok, row} <- fetch_memory(store, memory_id) do
      {:ok,
       %{
         "seq" => seq,
         "op" => "remember",
         "id" => row["id"],
         "content" => row["content"],
         "content_hash" => row["content_hash"],
         "scope" => row["scope"],
         "agent_id" => row["agent_id"],
         "session_id" => row["session_id"],
         "tags" => Reducer.decode_json(row["tags"], []),
         "metadata" => Reducer.decode_json(row["metadata"], %{}),
         "confidence" => row["confidence"],
         "inserted_at" => row["inserted_at"],
         "updated_at" => row["updated_at"]
       }}
    end
  end

  defp payload_item(store, %{"op" => "forget", "seq" => seq, "memory_id" => memory_id}) do
    with {:ok, row} <- fetch_memory(store, memory_id) do
      {:ok,
       %{
         "seq" => seq,
         "op" => "forget",
         "id" => row["id"],
         "remote_id" => row["remote_id"],
         "content_hash" => row["content_hash"],
         "scope" => row["scope"],
         "inserted_at" => row["inserted_at"],
         "updated_at" => row["updated_at"],
         "deleted_at" => row["deleted_at"]
       }}
    end
  end

  defp fetch_memory(store, memory_id) do
    case Store.query(
           store,
           """
           SELECT id, content, content_hash, scope, agent_id, session_id, tags, metadata,
                  confidence, sync_state, remote_id, synced_at, deleted_at, inserted_at, updated_at
           FROM memories
           WHERE id = ?
           LIMIT 1
           """,
           [memory_id]
         ) do
      {:ok, %Result{rows: [row]}} -> {:ok, row}
      {:ok, %Result{rows: []}} -> {:error, "memory row not found for outbox item #{memory_id}"}
      {:error, reason} -> {:error, "memory row lookup failed: #{inspect(reason)}"}
    end
  end

  defp push_sync(channel_module, channel, payload) do
    channel_module.push(channel, "memory_sync", payload)
  catch
    :exit, reason -> {:error, reason}
  end

  defp apply_acks(opts, outbox_rows, ack_items) do
    transaction(opts.store, fn conn ->
      Enum.reduce_while(Enum.zip(outbox_rows, ack_items), :ok, fn {row, ack}, :ok ->
        case apply_ack(conn, opts, row, ack) do
          :ok -> {:cont, :ok}
          {:error, reason} -> DBConnection.rollback(conn, reason)
        end
      end)
    end)
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_ack(conn, opts, row, %{"status" => status} = ack)
       when status in ["ok", "duplicate"] do
    mark_done(conn, row, ack["canonical_id"], now(opts))
  end

  defp apply_ack(conn, opts, row, %{"status" => "error"} = ack) do
    case dead_letter(conn, row["seq"], ack["error"] || "validation error", now(opts)) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:storage_error, reason}}
    end
  end

  defp apply_ack(conn, opts, row, _ack), do: retry_row(conn, opts, row, "missing acknowledgement")

  defp mark_done(conn, row, canonical_id, now) do
    with {:ok, %Result{num_rows: updated}} <-
           Store.execute(
             conn,
             "UPDATE memory_outbox SET state = 'done', completed_at = ?, next_attempt_at = NULL, last_error = NULL, dead_lettered_at = NULL, updated_at = ? WHERE seq = ? AND state = 'inflight'",
             [now, now, row["seq"]]
           ),
         true <- updated > 0,
         {:ok, _} <-
           Store.execute(
             conn,
             """
             UPDATE memories
             SET sync_state = 'synced',
                 remote_id = COALESCE(?, remote_id),
                 synced_at = ?
             WHERE id = ?
             """,
             [canonical_id, now, row["memory_id"]]
           ) do
      :ok
    else
      false -> :ok
      {:error, reason} -> {:error, {:storage_error, reason}}
    end
  end

  defp dead_letter(store, seq, error, now) do
    Store.execute(
      store,
      """
      UPDATE memory_outbox
      SET state = 'dead_letter',
          attempts = attempts + 1,
          last_error = ?,
          dead_lettered_at = ?,
          next_attempt_at = NULL,
          updated_at = ?
      WHERE seq = ? AND state = 'inflight'
      """,
      [to_string(error), now, now, seq]
    )
  end

  defp retry_rows(opts, rows, error) do
    transaction(opts.store, fn conn ->
      Enum.reduce_while(rows, :ok, fn row, :ok ->
        case retry_row(conn, opts, row, error) do
          {:ok, _} -> {:cont, :ok}
          {:error, reason} -> DBConnection.rollback(conn, {:storage_error, reason})
        end
      end)
    end)
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp retry_result(opts, rows, error, result) do
    case retry_rows(opts, rows, error) do
      :ok -> {:error, result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp retry_row(store, opts, row, error) do
    attempts = row["attempts"] + 1
    now = now(opts)

    if attempts >= opts.max_attempts do
      Store.execute(
        store,
        "UPDATE memory_outbox SET state = 'dead_letter', attempts = ?, last_error = ?, dead_lettered_at = ?, next_attempt_at = NULL, updated_at = ? WHERE seq = ? AND state = 'inflight'",
        [attempts, to_string(error), now, now, row["seq"]]
      )
    else
      Store.execute(
        store,
        "UPDATE memory_outbox SET state = 'retry_wait', attempts = ?, last_error = ?, next_attempt_at = ?, updated_at = ? WHERE seq = ? AND state = 'inflight'",
        [attempts, to_string(error), retry_at(now, attempts, opts), now, row["seq"]]
      )
    end
  end

  defp reset_pending(_opts, []), do: :ok

  defp reset_pending(opts, seqs) do
    case Store.execute(
           opts.store,
           "UPDATE memory_outbox SET state = 'pending', updated_at = ? WHERE seq IN (#{placeholders(seqs)}) AND state = 'inflight'",
           [now(opts) | seqs]
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:storage_error, reason}}
    end
  end

  defp active_scopes(store, config) do
    bound_scope = config_value(config, :bound_scope) || "proj_local"

    store_scopes =
      case safe_query(
             store,
             """
             SELECT DISTINCT scope
             FROM (
               SELECT scope FROM memories
               UNION ALL SELECT scope FROM facts
               UNION ALL SELECT scope FROM tombstones
               UNION ALL SELECT scope FROM slots
             )
             ORDER BY scope
             """,
             []
           ) do
        {:ok, %Result{rows: rows}} -> Enum.map(rows, & &1["scope"])
        {:error, _reason} -> []
      end

    [bound_scope | store_scopes]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp safe_query(store, sql, params) do
    Store.query(store, sql, params)
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end

  defp connected_channel(%{channel: channel}) when is_pid(channel), do: {:ok, channel}

  defp connected_channel(%{channel_provider: channel_provider}) do
    if function_exported?(channel_provider, :channel, 0) do
      case channel_provider.channel() do
        channel when is_pid(channel) -> {:ok, channel}
        _ -> {:error, :not_connected}
      end
    else
      {:error, :not_connected}
    end
  end

  defp transaction(store, fun) do
    case Store.transaction(store, fun) do
      {:ok, value} -> {:ok, value}
      {:error, {:storage_error, _reason} = error} -> {:error, error}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_opts(opts) when is_list(opts) do
    config =
      Keyword.get(opts, :config, Application.get_env(:backplane_host_agent, :memory_config, %{}))

    %{
      store:
        Keyword.get(
          opts,
          :store,
          Application.get_env(:backplane_host_agent, :memory_store, Store)
        ),
      config: config,
      channel: Keyword.get(opts, :channel),
      channel_module: Keyword.get(opts, :channel_module, Channel),
      channel_provider: Keyword.get(opts, :channel_provider, MemoryProxy),
      batch_size:
        opts
        |> Keyword.get(:batch_size, config_value(config, :sync_batch_size) || @default_batch_size)
        |> clamp_batch_size(),
      interval_ms:
        Keyword.get(
          opts,
          :interval_ms,
          config_value(config, :sync_interval_ms) || @default_interval_ms
        ),
      max_attempts:
        Keyword.get(
          opts,
          :max_attempts,
          config_value(config, :max_attempts) || @default_max_attempts
        ),
      now_fun: Keyword.get(opts, :now_fun, &timestamp/0),
      jitter_fun: Keyword.get(opts, :jitter_fun, &:rand.uniform/0)
    }
  end

  defp normalize_opts(%{} = opts) do
    opts
    |> Map.to_list()
    |> normalize_opts()
  end

  defp clamp_batch_size(value) when is_integer(value), do: min(max(value, 1), @max_batch_size)
  defp clamp_batch_size(_value), do: @default_batch_size

  defp fit_payload(items, rows) do
    items
    |> Enum.zip(rows)
    |> Enum.reduce_while({[], []}, fn {item, _row}, {accepted, _deferred} ->
      candidate = Enum.reverse([item | accepted])

      if encoded_payload_bytes(candidate) <= @max_payload_bytes do
        {:cont, {[item | accepted], []}}
      else
        {:halt, {accepted, Enum.drop(rows, length(accepted))}}
      end
    end)
    |> then(fn {accepted, deferred} -> {Enum.reverse(accepted), deferred} end)
  end

  defp encoded_payload_bytes(items) do
    Jason.encode!(%{"protocol" => @protocol, "items" => items}) |> byte_size()
  end

  defp schedule_drain(%{interval_ms: interval_ms})
       when is_integer(interval_ms) and interval_ms > 0 do
    Process.send_after(self(), :drain, interval_ms)
  end

  defp schedule_drain(_state), do: :ok

  defp placeholders(values), do: values |> Enum.map(fn _ -> "?" end) |> Enum.join(",")

  defp config_value(config, key) when is_map(config) do
    Map.get(config, key, Map.get(config, Atom.to_string(key)))
  end

  defp config_value(_config, _key), do: nil

  defp timestamp do
    DateTime.utc_now()
    |> DateTime.truncate(:microsecond)
    |> DateTime.to_iso8601()
  end

  defp now(%{now_fun: fun}), do: fun.()

  defp retry_at(now, attempts, opts) do
    delay = min(1_000 * Integer.pow(2, attempts - 1), @max_retry_delay_ms)
    jitter = opts.jitter_fun.() |> min(1.0) |> max(0.0)
    {:ok, value, _offset} = DateTime.from_iso8601(now)

    value
    |> DateTime.add(min(round(delay * (0.5 + jitter)), @max_retry_delay_ms), :millisecond)
    |> DateTime.to_iso8601()
  end

  defp valid_acks?(rows, acks) when is_list(acks) do
    length(rows) == length(acks) and
      Enum.zip(rows, acks)
      |> Enum.all?(fn
        {row, %{"id" => id, "status" => status}} when status in ["ok", "duplicate", "error"] ->
          id == row["memory_id"]

        _ ->
          false
      end)
  end

  defp valid_acks?(_rows, _acks), do: false

  defp sha256(content) do
    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
  end

  defp empty_fact_set_hash, do: sha256("[]")
end

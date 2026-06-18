defmodule Backplane.HostAgent.Memory.Syncer do
  @moduledoc """
  Drains local host-agent memory outbox rows to the hub channel.
  """

  use GenServer

  alias Backplane.HostAgent.{Channel, MemoryProxy}
  alias Backplane.HostAgent.Memory.{Reducer, Store}
  alias ExTurso.Result

  @protocol "host_memory.v1"
  @default_batch_size 50
  @default_interval_ms 5_000
  @default_max_attempts 5

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
    schedule_drain(state)
    {:ok, state}
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

    with {:ok, channel} <- connected_channel(opts),
         {:ok, outbox_rows} <- claim_pending(opts.store, opts.batch_size) do
      if outbox_rows == [] do
        {:ok, %{"drained" => 0}}
      else
        items = Enum.map(outbox_rows, &payload_item!(opts.store, &1))
        payload = %{"protocol" => @protocol, "items" => items}

        case push_sync(opts.channel_module, channel, payload) do
          {:ok, %{"items" => ack_items}} ->
            apply_acks(opts.store, outbox_rows, ack_items, opts.max_attempts)
            {:ok, %{"drained" => length(items)}}

          {:ok, _reply} ->
            reset_pending(opts.store, Enum.map(outbox_rows, & &1["seq"]))
            {:error, :invalid_ack}

          {:error, reason} ->
            reset_pending(opts.store, Enum.map(outbox_rows, & &1["seq"]))
            {:error, reason}
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

  defp claim_pending(store, batch_size) do
    transaction(store, fn conn ->
      case Store.query(
             conn,
             """
             SELECT seq, op, memory_id
             FROM memory_outbox
             WHERE state = 'pending'
             ORDER BY seq
             LIMIT ?
             """,
             [batch_size]
           ) do
        {:ok, %Result{rows: []}} ->
          []

        {:ok, %Result{rows: rows}} ->
          seqs = Enum.map(rows, & &1["seq"])
          placeholders = placeholders(seqs)

          case Store.execute(
                 conn,
                 "UPDATE memory_outbox SET state = 'inflight', updated_at = ? WHERE seq IN (#{placeholders}) AND state = 'pending'",
                 [timestamp() | seqs]
               ) do
            {:ok, _result} -> rows
            {:error, reason} -> DBConnection.rollback(conn, {:storage_error, reason})
          end

        {:error, reason} ->
          DBConnection.rollback(conn, {:storage_error, reason})
      end
    end)
  end

  defp payload_item!(store, %{"op" => "remember", "seq" => seq, "memory_id" => memory_id}) do
    row = fetch_memory!(store, memory_id)

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
    }
  end

  defp payload_item!(store, %{"op" => "forget", "seq" => seq, "memory_id" => memory_id}) do
    row = fetch_memory!(store, memory_id)

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
    }
  end

  defp fetch_memory!(store, memory_id) do
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
      {:ok, %Result{rows: [row]}} -> row
      {:ok, %Result{rows: []}} -> raise "memory row not found for outbox item #{memory_id}"
      {:error, reason} -> raise "memory row lookup failed: #{inspect(reason)}"
    end
  end

  defp push_sync(channel_module, channel, payload) do
    channel_module.push(channel, "memory_sync", payload)
  catch
    :exit, reason -> {:error, reason}
  end

  defp apply_acks(store, outbox_rows, ack_items, max_attempts) do
    acks_by_id = Map.new(ack_items, &{&1["id"], &1})

    Enum.each(outbox_rows, fn row ->
      ack = Map.get(acks_by_id, row["memory_id"])
      apply_ack(store, row, ack, max_attempts)
    end)
  end

  defp apply_ack(store, row, %{"status" => status} = ack, _max_attempts)
       when status in ["ok", "duplicate"] do
    mark_done(store, row, ack["canonical_id"])
  end

  defp apply_ack(store, row, %{"status" => "error"} = ack, max_attempts) do
    mark_failed(store, row["seq"], ack["error"] || "validation error", max_attempts)
  end

  defp apply_ack(store, row, _ack, _max_attempts) do
    reset_pending(store, [row["seq"]])
  end

  defp mark_done(store, row, canonical_id) do
    now = timestamp()

    transaction(store, fn conn ->
      with {:ok, _} <-
             Store.execute(
               conn,
               "UPDATE memory_outbox SET state = 'done', updated_at = ? WHERE seq = ?",
               [now, row["seq"]]
             ),
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
        {:error, reason} -> DBConnection.rollback(conn, {:storage_error, reason})
      end
    end)
  end

  defp mark_failed(store, seq, error, max_attempts) do
    Store.execute(
      store,
      """
      UPDATE memory_outbox
      SET state = 'failed',
          attempts = min(attempts + 1, ?),
          last_error = ?,
          updated_at = ?
      WHERE seq = ?
      """,
      [max_attempts, to_string(error), timestamp(), seq]
    )
  end

  defp reset_pending(_store, []), do: :ok

  defp reset_pending(store, seqs) do
    Store.execute(
      store,
      "UPDATE memory_outbox SET state = 'pending', updated_at = ? WHERE seq IN (#{placeholders(seqs)})",
      [timestamp() | seqs]
    )
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
        Keyword.get(
          opts,
          :batch_size,
          config_value(config, :sync_batch_size) || @default_batch_size
        ),
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
        )
    }
  end

  defp normalize_opts(%{} = opts) do
    opts
    |> Map.to_list()
    |> normalize_opts()
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

  defp sha256(content) do
    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
  end

  defp empty_fact_set_hash, do: sha256("[]")
end

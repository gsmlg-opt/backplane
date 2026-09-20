defmodule Backplane.HostAgent.Memory.Diagnostics do
  @moduledoc """
  Read-only diagnostics and operator recovery helpers for host-agent memory.
  """

  alias Backplane.HostAgent.Memory.{Edge.Protection, Store, Syncer}
  alias Backplane.HostAgent.Memory.Edge.{Eviction, Telemetry}
  alias Turso.Result

  @doc "Returns a JSON-compatible diagnostic snapshot of the local memory store."
  def snapshot(opts \\ []) do
    opts = normalize_opts(opts)

    with {:ok, memories} <- grouped_counts(opts.store, "memories", "sync_state", "1 = 1"),
         {:ok, outbox} <- grouped_counts(opts.store, "memory_outbox", "state", "1 = 1"),
         {:ok, oldest_pending_seq} <- oldest_pending_seq(opts.store),
         {:ok, failed_outbox} <- failed_outbox(opts.store),
         {:ok, facts} <- fact_summary(opts.store),
         {:ok, tombstones} <- scalar_count(opts.store, "tombstones"),
         {:ok, last_successful_sync} <- max_value(opts.store, "memories", "synced_at"),
         {:ok, last_reconcile_at} <- max_value(opts.store, "facts", "updated_at") do
      edge = edge_summary(opts, outbox)
      Telemetry.state(atomize_edge(edge))

      {:ok,
       %{
         "store" => %{"status" => "ok", "db_path" => opts.db_path},
         "memories" => memories,
         "outbox" => outbox,
         "oldest_pending_seq" => oldest_pending_seq,
         "failed_outbox" => failed_outbox,
         "facts" => facts,
         "tombstones" => tombstones,
         "last_successful_sync" => last_successful_sync,
         "last_reconcile_at" => last_reconcile_at,
         "edge_protection" => Atom.to_string(Protection.status(opts.host_sync_v2)),
         "edge" => edge
       }}
    end
  end

  @doc "Requeues selected or all dead-lettered outbox rows for another sync attempt."
  def requeue_failed_outbox(opts \\ []) do
    opts = normalize_opts(opts)
    now = timestamp()
    seqs = Map.get(opts, :seqs, :all)

    {where, params} =
      case seqs do
        :all ->
          {"state = 'dead_letter'", []}

        values when is_list(values) and values != [] ->
          {"state = 'dead_letter' AND seq IN (#{placeholders(values)})", values}

        _ ->
          {"1 = 0", []}
      end

    case Store.execute(
           opts.store,
           """
           UPDATE memory_outbox
           SET state = 'pending', attempts = 0, next_attempt_at = NULL, last_error = NULL,
               dead_lettered_at = NULL, updated_at = ?
           WHERE #{where}
           """,
           [now | params]
         ) do
      {:ok, %Result{num_rows: requeued}} ->
        {:ok, %{"requeued" => requeued}}

      {:error, reason} ->
        {:error, {:storage_error, reason}}
    end
  end

  @doc "Purges all local wipe tombstones. This is explicit operator recovery only."
  def purge_tombstones(opts \\ []) do
    opts = normalize_opts(opts)

    case Store.execute(opts.store, "DELETE FROM tombstones") do
      {:ok, %Result{num_rows: purged}} -> {:ok, %{"purged" => purged}}
      {:error, reason} -> {:error, {:storage_error, reason}}
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
      db_path: Keyword.get(opts, :db_path, config_value(config, :db_path)),
      host_sync_v2: Keyword.get(opts, :host_sync_v2, config_value(config, :host_sync_v2) || %{}),
      edge_store: Keyword.get(opts, :edge_store, Backplane.HostAgent.Memory.Edge.Store),
      seqs: Keyword.get(opts, :seqs, :all)
    }
  end

  defp normalize_opts(%{} = opts) do
    opts
    |> Map.to_list()
    |> normalize_opts()
  end

  defp edge_summary(opts, outbox) do
    protection = Protection.status(opts.host_sync_v2)

    base = %{
      "protection_mode" => Atom.to_string(protection),
      "items" => 0,
      "bytes" => 0,
      "revision" => 0,
      "lag" => nil,
      "lag_status" => "unavailable",
      "stale_age_seconds" => nil,
      "retry_count" => Map.get(outbox, "retry_wait", 0),
      "dead_letter_count" => Map.get(outbox, "dead_letter", 0),
      "partitions" => []
    }

    if protection == :plaintext_development and edge_available?(opts.edge_store) do
      with {:ok, stats} <- Eviction.stats(opts.edge_store) do
        partitions =
          Enum.map(stats.partitions, fn partition ->
            Map.put(partition, "stale_age_seconds", stale_age(partition["last_sync_at"]))
          end)

        stale_age =
          if Enum.any?(partitions, &is_nil(&1["stale_age_seconds"])),
            do: nil,
            else: partitions |> Enum.map(& &1["stale_age_seconds"]) |> Enum.max(fn -> nil end)

        base
        |> Map.merge(%{
          "items" => stats.items,
          "bytes" => stats.bytes,
          "revision" => stats.revision,
          "partitions" => partitions
        })
        |> Map.put("stale_age_seconds", stale_age)
      else
        _ -> base
      end
    else
      base
    end
  end

  defp edge_available?(pid) when is_pid(pid), do: Process.alive?(pid)
  defp edge_available?(name) when is_atom(name), do: Process.whereis(name) != nil
  defp edge_available?(_), do: false

  defp stale_age(nil), do: nil

  defp stale_age(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _} -> max(DateTime.diff(DateTime.utc_now(), datetime), 0)
      _ -> 0
    end
  end

  defp atomize_edge(edge),
    do: Map.new(edge, fn {key, value} -> {String.to_existing_atom(key), value} end)

  defp grouped_counts(store, table, column, where) do
    case Store.query(
           store,
           "SELECT #{column} AS name, COUNT(*) AS count FROM #{table} WHERE #{where} GROUP BY #{column}"
         ) do
      {:ok, %Result{rows: rows}} ->
        {:ok, Map.new(rows, fn row -> {row["name"], row["count"]} end)}

      {:error, reason} ->
        {:error, {:storage_error, reason}}
    end
  end

  defp oldest_pending_seq(store) do
    case Store.query(
           store,
           "SELECT MIN(seq) AS seq FROM memory_outbox WHERE state IN ('pending', 'retry_wait')"
         ) do
      {:ok, %Result{rows: [%{"seq" => seq}]}} -> {:ok, seq}
      {:error, reason} -> {:error, {:storage_error, reason}}
    end
  end

  defp failed_outbox(store) do
    sql = """
    SELECT seq, op, memory_id, attempts, last_error, updated_at
    FROM memory_outbox
    WHERE state = 'dead_letter'
    ORDER BY seq
    """

    case Store.query(store, sql) do
      {:ok, %Result{rows: rows}} -> {:ok, rows}
      {:error, reason} -> {:error, {:storage_error, reason}}
    end
  end

  defp fact_summary(store) do
    with {:ok, count} <- scalar_count(store, "facts"),
         {:ok, scopes} <- fact_scopes(store) do
      {:ok, %{"count" => count, "scopes" => scopes}}
    end
  end

  defp fact_scopes(store) do
    sql = """
    SELECT scope, COUNT(*) AS count
    FROM facts
    GROUP BY scope
    ORDER BY scope
    """

    case Store.query(store, sql) do
      {:ok, %Result{rows: rows}} ->
        scopes =
          Enum.map(rows, fn row ->
            %{
              "scope" => row["scope"],
              "count" => row["count"],
              "fact_set_hash" => Syncer.fact_set_hash(store, row["scope"])
            }
          end)

        {:ok, scopes}

      {:error, reason} ->
        {:error, {:storage_error, reason}}
    end
  end

  defp scalar_count(store, table) do
    case Store.query(store, "SELECT COUNT(*) AS count FROM #{table}") do
      {:ok, %Result{rows: [%{"count" => count}]}} -> {:ok, count}
      {:error, reason} -> {:error, {:storage_error, reason}}
    end
  end

  defp max_value(store, table, column) do
    case Store.query(store, "SELECT MAX(#{column}) AS value FROM #{table}") do
      {:ok, %Result{rows: [%{"value" => value}]}} -> {:ok, value}
      {:error, reason} -> {:error, {:storage_error, reason}}
    end
  end

  defp config_value(config, key) when is_map(config) do
    Map.get(config, key, Map.get(config, Atom.to_string(key)))
  end

  defp config_value(_config, _key), do: nil

  defp timestamp do
    DateTime.utc_now()
    |> DateTime.truncate(:microsecond)
    |> DateTime.to_iso8601()
  end

  defp placeholders(values), do: values |> Enum.map(fn _ -> "?" end) |> Enum.join(",")
end

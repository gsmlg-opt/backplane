defmodule Backplane.HostAgent.Memory.Diagnostics do
  @moduledoc """
  Read-only diagnostics and operator recovery helpers for host-agent memory.
  """

  alias Backplane.HostAgent.Memory.{Store, Syncer}
  alias ExTurso.Result

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
         "last_reconcile_at" => last_reconcile_at
       }}
    end
  end

  @doc "Requeues failed outbox rows for another sync attempt."
  def requeue_failed_outbox(opts \\ []) do
    opts = normalize_opts(opts)
    now = timestamp()

    case Store.execute(
           opts.store,
           """
           UPDATE memory_outbox
           SET state = 'pending', last_error = NULL, updated_at = ?
           WHERE state = 'failed'
           """,
           [now]
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
      db_path: Keyword.get(opts, :db_path, config_value(config, :db_path))
    }
  end

  defp normalize_opts(%{} = opts) do
    opts
    |> Map.to_list()
    |> normalize_opts()
  end

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
    case Store.query(store, "SELECT MIN(seq) AS seq FROM memory_outbox WHERE state = 'pending'") do
      {:ok, %Result{rows: [%{"seq" => seq}]}} -> {:ok, seq}
      {:error, reason} -> {:error, {:storage_error, reason}}
    end
  end

  defp failed_outbox(store) do
    sql = """
    SELECT seq, op, memory_id, attempts, last_error, updated_at
    FROM memory_outbox
    WHERE state = 'failed'
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
end

defmodule Backplane.HostAgent.Memory.Diagnostics do
  @moduledoc """
  Read-only diagnostics and operator recovery helpers for host-agent memory.
  """

  alias Backplane.HostAgent.Memory.{Access, Edge.Protection, Store, Syncer}
  alias Backplane.HostAgent.Memory.Edge.{Eviction, Telemetry}
  alias Turso.Result

  @doc "Returns a JSON-compatible diagnostic snapshot of the local memory store."
  def snapshot(opts \\ []) do
    opts = normalize_opts(opts)

    with {:ok, memories} <- grouped_counts(opts.store, "memories", "sync_state", "1 = 1"),
         {:ok, outbox} <- grouped_counts(opts.store, "memory_outbox", "state", "1 = 1"),
         {:ok, oldest_pending_seq} <- oldest_pending_seq(opts.store),
         {:ok, failed_outbox} <- failed_outbox(opts.store, opts.metadata_limit),
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

  @doc "Returns bounded transport metadata through the running stores' owning connections."
  def targeted(request, opts \\ [])

  def targeted(
        %{"memory_access_id" => id, "command_ids" => commands, "mirror_ids" => mirrors} = request,
        opts
      ) do
    valid =
      Map.drop(request, ~w(memory_access_id command_ids mirror_ids include_edge_sync)) == %{} and
        is_boolean(Map.get(request, "include_edge_sync", false)) and
        diagnostic_id?(id) and is_list(commands) and is_list(mirrors) and
        length(commands) + length(mirrors) <= 32 and
        Enum.all?(commands ++ mirrors, &diagnostic_id?/1)

    if valid do
      Access.run_local(
        :all,
        :diagnostics,
        fn context -> shared_targeted(context, id, commands, mirrors) end,
        Keyword.get(opts, :access_server, Access)
      )
      |> include_edge_sync(request, opts)
    else
      {:error, :invalid_diagnostic_request}
    end
  end

  def targeted(request, opts) do
    config =
      Keyword.get(opts, :config, Application.get_env(:backplane_host_agent, :memory_config, %{}))

    resolve =
      Keyword.get(opts, :edge_context, &Backplane.HostAgent.Memory.Edge.Syncer.read_context/1)

    store =
      Keyword.get(opts, :store, Application.get_env(:backplane_host_agent, :memory_store, Store))

    capture =
      Keyword.get(
        opts,
        :capture_runtime,
        Application.get_env(:backplane_host_agent, :capture_runtime, %{})
      )

    with :ok <- validate_targeted(request),
         partition = request["partition"],
         true <-
           config_value(config, :enabled) == true and
             config_value(config, :bound_scope) == partition["scope"],
         {:ok, %{edge_partition: ^partition, edge_store: edge}} <- resolve.(partition),
         edge = edge || Backplane.HostAgent.Memory.Edge.Store,
         {:ok, commands} <- targeted_commands(store, request["command_ids"], partition["scope"]),
         {:ok, tombstones} <- targeted_tombstones(store, partition["scope"]),
         {:ok, events} <- targeted_capture(capture, request["event_ids"]),
         {:ok, mirror} <- targeted_mirror(edge, partition, request["mirror_ids"]) do
      {:ok,
       %{
         "observation_source" => "owner_connection",
         "commands" => commands,
         "capture" => events,
         "mirror" => mirror,
         "tombstones" => tombstones
       }}
    else
      false -> {:error, :diagnostic_partition_mismatch}
      {:error, :invalid_diagnostic_request} = error -> error
      {:error, :partition_mismatch} -> {:error, :diagnostic_partition_mismatch}
      _ -> {:error, :diagnostic_unavailable}
    end
  rescue
    _ -> {:error, :diagnostic_unavailable}
  catch
    :exit, _ -> {:error, :diagnostic_unavailable}
  end

  defp include_edge_sync({:ok, result}, %{"include_edge_sync" => true}, opts) do
    # Query after releasing the access owner: the syncer may itself await that owner.
    diagnostic =
      Backplane.HostAgent.Memory.Edge.Syncer.diagnostics(
        Keyword.get(opts, :edge_syncer, Backplane.HostAgent.Memory.Edge.Syncer)
      )

    {:ok, Map.put(result, "edge_sync", diagnostic)}
  end

  defp include_edge_sync(result, _request, _opts), do: result

  defp shared_targeted(context, id, commands, mirrors) do
    case context.accesses[id] do
      nil ->
        {:error, :diagnostic_partition_mismatch}

      entry ->
        admitted = context.negotiated and not context.global_fenced and entry.status != "fenced"
        current = Map.merge(entry, %{owner: self()})

        complete =
          admitted and entry.status == "active" and "read" in entry.capabilities and
            "deliver" in entry.capabilities and
            Backplane.HostAgent.Memory.Mirror.Store.complete?(context.edge_store, current)

        with {:ok, %Result{rows: counts}} <-
               Store.query(
                 context.store,
                 "SELECT state,COUNT(*) AS count FROM memory_outbox WHERE access_id=? GROUP BY state",
                 [id]
               ),
             {:ok, %Result{rows: rows}} <-
               Store.query(
                 context.store,
                 "SELECT command_id,authority_version,state,ack_canonical_id,ack_revision,last_error IS NOT NULL AS has_error FROM memory_outbox WHERE access_id=? AND command_id IN (#{if commands == [], do: "NULL", else: placeholders(commands)}) ORDER BY seq LIMIT 32",
                 [id | commands]
               ) do
          mirror =
            if complete do
              case targeted_mirror(context.edge_store, entry.partition, mirrors) do
                {:ok, result} -> Map.put(result, "status", "complete")
                _ -> %{"status" => "unavailable"}
              end
            else
              %{"status" => if(admitted, do: "incomplete", else: "closed")}
            end

          {:ok,
           %{
             "observation_source" => "authority_owner",
             "access" => %{
               "access_id" => id,
               "authority_version" => entry.authority_version,
               "capabilities" => entry.capabilities,
               "status" => if(admitted, do: entry.status, else: "closed"),
               "fence_reason" =>
                 if(context.negotiated, do: entry.fence_reason, else: "not_negotiated"),
               "offline_read_lease_seconds" => entry.offline_read_lease_seconds,
               "lease_remaining_ms" =>
                 if(admitted and entry.deadline,
                   do: max(entry.deadline - context.now_ms, 0),
                   else: 0
                 )
             },
             "commands" => %{
               "counts" => Map.new(counts, &{&1["state"], &1["count"]}),
               "rows" => rows
             },
             "mirror" => mirror
           }}
        end
    end
  end

  defp validate_targeted(
         %{
           "partition" => partition,
           "command_ids" => commands,
           "event_ids" => events,
           "mirror_ids" => mirror
         } = request
       )
       when is_map(partition) and is_list(commands) and is_list(events) and is_list(mirror) do
    valid =
      map_size(request) == 4 and map_size(partition) == 3 and
        Enum.all?(~w(memory_space_id scope namespace), fn key ->
          is_binary(partition[key]) and byte_size(partition[key]) in 1..256
        end) and length(commands) + length(events) + length(mirror) <= 32 and
        Enum.all?(commands ++ events ++ mirror, &diagnostic_id?/1)

    if valid, do: :ok, else: {:error, :invalid_diagnostic_request}
  end

  defp validate_targeted(_), do: {:error, :invalid_diagnostic_request}

  defp diagnostic_id?(id) when is_binary(id),
    do: Regex.match?(~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/, id)

  defp diagnostic_id?(_), do: false

  defp targeted_commands(_store, [], _scope), do: {:ok, %{"outbox" => [], "memories" => []}}

  defp targeted_commands(store, ids, scope) do
    marks = placeholders(ids)

    with {:ok, %Result{rows: outbox}} <-
           Store.query(
             store,
             "SELECT seq,op,memory_id,state,attempts,ack_canonical_id,ack_revision FROM memory_outbox WHERE memory_id IN (#{marks}) AND memory_id IN (SELECT id FROM memories WHERE scope=?) ORDER BY seq LIMIT 100",
             ids ++ [scope]
           ),
         {:ok, %Result{rows: memories}} <-
           Store.query(
             store,
             "SELECT id,remote_id,sync_state,deleted_at IS NOT NULL AS deleted FROM memories WHERE scope=? AND id IN (#{marks}) ORDER BY id LIMIT 32",
             [scope | ids]
           ) do
      {:ok,
       %{
         "outbox" => outbox,
         "memories" => Enum.map(memories, &Map.update!(&1, "deleted", fn value -> value == 1 end))
       }}
    end
  end

  defp targeted_tombstones(store, scope) do
    with {:ok, %Result{rows: rows}} <-
           Store.query(
             store,
             "SELECT content_hash FROM tombstones WHERE scope=? ORDER BY content_hash LIMIT 10001",
             [scope]
           ),
         true <- length(rows) <= 10000 do
      data = Enum.map(rows, fn row -> [Jason.encode!(row["content_hash"]), "\n"] end)

      {:ok,
       %{
         "count" => length(rows),
         "digest" => Base.encode16(:crypto.hash(:sha256, data), case: :lower)
       }}
    end
  end

  defp targeted_capture(_runtime, []),
    do: {:ok, %{"rows" => [], "expected" => 0, "missing_or_compacted" => 0}}

  defp targeted_capture(%{spool: spool}, ids) when not is_nil(spool) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, rows} ->
      case Backplane.HostAgent.Memory.Spool.Turso.event_status(spool, id) do
        {:ok, status} ->
          row = %{
            "event_id" => id,
            "state" => Atom.to_string(status.state),
            "attempts" => status.attempts,
            "acknowledged" => status.acknowledged
          }

          {:cont, {:ok, [row | rows]}}

        {:error, :not_found} ->
          {:cont, {:ok, rows}}

        _ ->
          {:halt, {:error, :diagnostic_unavailable}}
      end
    end)
    |> case do
      {:ok, rows} ->
        {:ok,
         %{
           "rows" => Enum.reverse(rows),
           "expected" => length(ids),
           "missing_or_compacted" => length(ids) - length(rows)
         }}

      error ->
        error
    end
  end

  defp targeted_capture(_, _), do: {:error, :diagnostic_unavailable}

  defp targeted_mirror(store, partition, ids) do
    keys = Enum.map(~w(memory_space_id scope namespace), &partition[&1])

    with {:ok, %Result{rows: rows}} <-
           Store.query(
             store,
             "SELECT applied_revision,active_generation,snapshot_id,snapshot_revision,sync_status FROM edge_partitions WHERE memory_space_id=? AND scope=? AND namespace=?",
             keys
           ),
         {:ok, active} <- targeted_active_ids(store, keys, rows, ids) do
      {:ok, %{"partition" => List.first(rows), "active_target_ids" => active}}
    end
  end

  defp targeted_active_ids(_store, _keys, [], _ids), do: {:ok, []}
  defp targeted_active_ids(_store, _keys, _rows, []), do: {:ok, []}

  defp targeted_active_ids(store, keys, [row], ids) do
    case Store.query(
           store,
           "SELECT canonical_id FROM edge_memories WHERE memory_space_id=? AND scope=? AND namespace=? AND generation=? AND lifecycle_state='active' AND canonical_id IN (#{placeholders(ids)}) ORDER BY canonical_id LIMIT 32",
           keys ++ [row["active_generation"] | ids]
         ) do
      {:ok, %Result{rows: rows}} -> {:ok, Enum.map(rows, & &1["canonical_id"])}
      error -> error
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
           WHERE access_id IS NULL AND #{where}
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
      seqs: Keyword.get(opts, :seqs, :all),
      metadata_limit: metadata_limit(Keyword.get(opts, :metadata_limit, 50))
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
      "status" => "unavailable",
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
      with {:ok, stats} <- Eviction.stats(opts.edge_store, partition_limit: opts.metadata_limit) do
        partitions =
          Enum.map(stats.partitions, fn partition ->
            Map.put(partition, "stale_age_seconds", stale_age(partition["last_sync_at"]))
          end)

        stale_age = stale_age(stats.oldest_sync_at)

        base
        |> Map.merge(%{
          "status" => "available",
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
      _ -> nil
    end
  end

  defp atomize_edge(edge) do
    # These atoms must exist before Telemetry is loaded on a cold host startup.
    keys = ~w(protection_mode items bytes revision lag lag_status stale_age_seconds
              retry_count dead_letter_count partitions)a

    Map.new(keys, fn key -> {key, Map.fetch!(edge, Atom.to_string(key))} end)
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
    case Store.query(
           store,
           "SELECT MIN(seq) AS seq FROM memory_outbox WHERE state IN ('pending', 'retry_wait')"
         ) do
      {:ok, %Result{rows: [%{"seq" => seq}]}} -> {:ok, seq}
      {:error, reason} -> {:error, {:storage_error, reason}}
    end
  end

  defp failed_outbox(store, limit) do
    sql = """
    SELECT seq, op, memory_id, attempts, last_error, updated_at
    FROM memory_outbox
    WHERE state = 'dead_letter'
    ORDER BY seq LIMIT ?
    """

    case Store.query(store, sql, [limit]) do
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

  defp metadata_limit(value) when is_integer(value) and value > 0, do: min(value, 50)
  defp metadata_limit(_value), do: 50

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

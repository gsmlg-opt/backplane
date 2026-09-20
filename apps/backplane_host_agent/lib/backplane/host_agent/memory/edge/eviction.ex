defmodule Backplane.HostAgent.Memory.Edge.Eviction do
  @moduledoc "Deterministic local-only quota enforcement for the canonical edge cache."

  alias Backplane.HostAgent.Memory.Edge.Store

  @defaults %{
    max_items: 10_000,
    max_bytes: 64 * 1024 * 1024,
    max_items_per_partition: 5_000,
    type_quotas: %{}
  }

  def enforce(store, config, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now()) |> DateTime.to_iso8601()
    scope = Keyword.get(opts, :scope, :active)

    Store.transaction(store, fn conn -> enforce!(conn, config, now, scope) end)
  end

  @doc false
  def enforce!(conn, config, now \\ DateTime.to_iso8601(DateTime.utc_now()), scope \\ :active) do
    limits = limits(config)
    rows = rows!(conn, scope)
    {expired, rows} = Enum.split_with(rows, &expired?(&1, now, limits.max_age_seconds))
    delete!(conn, expired)

    {type_evicted, rows} = enforce_types(conn, rows, limits.type_quotas)
    {partition_evicted, rows} = enforce_partitions(conn, rows, limits.max_items_per_partition)
    {global_evicted, rows} = enforce_global(conn, rows, limits.max_items, limits.max_bytes)

    %{
      expired: length(expired),
      evicted: length(type_evicted) + length(partition_evicted) + length(global_evicted),
      items: length(rows),
      bytes: Enum.sum(Enum.map(rows, & &1["byte_size"]))
    }
  end

  def stats(store) do
    Store.transaction(store, fn conn ->
      [%{"items" => items, "bytes" => bytes}] =
        query_rows!(conn, """
        SELECT COUNT(*) AS items, COALESCE(SUM(e.byte_size),0) AS bytes
        FROM edge_memories e
        WHERE EXISTS (
          SELECT 1 FROM edge_partitions p
          WHERE p.memory_space_id=e.memory_space_id AND p.scope=e.scope
            AND p.namespace=e.namespace AND p.active_generation=e.generation
        )
        """)

      partitions =
        query_rows!(conn, """
        SELECT memory_space_id,scope,namespace,applied_revision,last_sync_at
        FROM edge_partitions ORDER BY memory_space_id,scope,namespace
        """)

      %{
        items: items,
        bytes: bytes,
        revision: Enum.max(Enum.map(partitions, & &1["applied_revision"]), fn -> 0 end),
        partitions: partitions
      }
    end)
  end

  defp query_rows!(conn, sql) do
    case Store.query(conn, sql) do
      {:ok, %{rows: rows}} -> rows
      {:error, reason} -> DBConnection.rollback(conn, reason)
    end
  end

  defp limits(config) do
    config = if is_map(config), do: config, else: %{}

    %{
      max_items: positive(config, :max_items, @defaults.max_items),
      max_bytes: positive(config, :max_bytes, @defaults.max_bytes),
      max_items_per_partition:
        positive(config, :max_items_per_partition, @defaults.max_items_per_partition),
      max_age_seconds:
        positive(config, :max_age_seconds, nil) || positive(config, :max_age_days, nil) |> days(),
      type_quotas: type_quotas(config)
    }
  end

  defp positive(config, key, default) do
    case Map.get(config, key, Map.get(config, Atom.to_string(key))) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end

  defp type_quotas(config) do
    case Map.get(config, :type_quotas, Map.get(config, "type_quotas", %{})) do
      quotas when is_map(quotas) ->
        Map.new(quotas, fn {key, value} -> {to_string(key), value} end)

      _ ->
        %{}
    end
  end

  defp days(nil), do: nil
  defp days(value), do: value * 86_400

  defp rows!(conn, :active) do
    case Store.query(conn, """
         SELECT memory_space_id,scope,namespace,generation,canonical_id,memory_type,lifecycle_state,
                edge_priority,last_accessed_at,updated_at,edge_expires_at,byte_size
         FROM edge_memories e
         WHERE EXISTS (
           SELECT 1 FROM edge_partitions p
           WHERE p.memory_space_id=e.memory_space_id AND p.scope=e.scope
             AND p.namespace=e.namespace AND p.active_generation=e.generation
         )
         """) do
      {:ok, %{rows: rows}} -> rows
      {:error, reason} -> DBConnection.rollback(conn, reason)
    end
  end

  defp rows!(conn, {:generation, partition, generation}) do
    case Store.query(
           conn,
           """
           SELECT memory_space_id,scope,namespace,generation,canonical_id,memory_type,lifecycle_state,
                  edge_priority,last_accessed_at,updated_at,edge_expires_at,byte_size
           FROM edge_memories
           WHERE memory_space_id=? AND scope=? AND namespace=?
             AND generation=?
           """,
           [partition["memory_space_id"], partition["scope"], partition["namespace"], generation]
         ) do
      {:ok, %{rows: rows}} -> rows
      {:error, reason} -> DBConnection.rollback(conn, reason)
    end
  end

  defp expired?(row, now, max_age_seconds) do
    explicit = is_binary(row["edge_expires_at"]) and row["edge_expires_at"] <= now

    aged =
      with true <- is_integer(max_age_seconds),
           updated when is_binary(updated) <- row["updated_at"],
           {:ok, updated_at} <- parse_timestamp(updated),
           {:ok, now_at} <- parse_timestamp(now),
           do: DateTime.diff(now_at, updated_at) > max_age_seconds

    explicit or aged == true
  end

  defp parse_timestamp(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        {:ok, datetime}

      {:error, _reason} ->
        with {:ok, naive} <- NaiveDateTime.from_iso8601(value),
             {:ok, datetime} <- DateTime.from_naive(naive, "Etc/UTC") do
          {:ok, datetime}
        end
    end
  end

  defp enforce_types(conn, rows, quotas) do
    quotas
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce({[], rows}, fn {type, quota}, {evicted, current} ->
      matching =
        Enum.filter(current, &(&1["lifecycle_state"] != "deleted" and &1["memory_type"] == type))

      selected = take_excess(matching, quota)
      delete!(conn, selected)
      {evicted ++ selected, current -- selected}
    end)
  end

  defp enforce_partitions(conn, rows, quota) do
    rows
    |> Enum.group_by(&partition_key/1)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce({[], rows}, fn {_partition, items}, {evicted, current} ->
      selected = take_excess(items, quota)
      delete!(conn, selected)
      {evicted ++ selected, current -- selected}
    end)
  end

  defp enforce_global(conn, rows, max_items, max_bytes) do
    sorted = Enum.sort_by(rows, &rank/1)
    remove_count = max(length(rows) - max_items, 0)
    {by_count, remaining} = Enum.split(sorted, remove_count)
    bytes = Enum.sum(Enum.map(remaining, & &1["byte_size"]))
    {by_bytes, kept, _} = trim_bytes(remaining, bytes, max_bytes, [])
    selected = by_count ++ by_bytes
    delete!(conn, selected)
    {selected, kept}
  end

  defp trim_bytes(rows, bytes, max_bytes, removed) when bytes <= max_bytes,
    do: {Enum.reverse(removed), rows, bytes}

  defp trim_bytes([row | rest], bytes, max_bytes, removed),
    do: trim_bytes(rest, bytes - row["byte_size"], max_bytes, [row | removed])

  defp trim_bytes([], bytes, _max_bytes, removed), do: {Enum.reverse(removed), [], bytes}

  defp take_excess(rows, quota) when is_integer(quota) and quota >= 0,
    do: rows |> Enum.sort_by(&rank/1) |> Enum.take(max(length(rows) - quota, 0))

  defp take_excess(_rows, _quota), do: []

  defp rank(row),
    do:
      {if(row["lifecycle_state"] == "deleted", do: 0, else: 1), row["edge_priority"] || 0,
       row["last_accessed_at"] || "", row["updated_at"] || "", row["canonical_id"]}

  defp partition_key(row), do: {row["memory_space_id"], row["scope"], row["namespace"]}

  defp delete!(_conn, []), do: :ok

  defp delete!(conn, rows) do
    Enum.each(rows, fn row ->
      case Store.execute(
             conn,
             "DELETE FROM edge_memories WHERE memory_space_id=? AND scope=? AND namespace=? AND generation=? AND canonical_id=?",
             [
               row["memory_space_id"],
               row["scope"],
               row["namespace"],
               row["generation"],
               row["canonical_id"]
             ]
           ) do
        {:ok, _} -> :ok
        {:error, reason} -> DBConnection.rollback(conn, reason)
      end
    end)
  end
end

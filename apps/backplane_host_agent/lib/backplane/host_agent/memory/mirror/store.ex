defmodule Backplane.HostAgent.Memory.Mirror.Store do
  @moduledoc "Transactional Turso adapter for canonical mirror generations and cursors."
  alias Backplane.HostAgent.Memory.Edge.Store, as: Edge
  @where "memory_space_id = ? AND scope = ? AND namespace = ?"
  @partition_keys ["memory_space_id", "scope", "namespace"]

  @callback offer(GenServer.server()) :: {:ok, map()} | {:error, term()}
  @callback apply_delivery(GenServer.server(), map()) :: {:ok, map()} | {:error, term()}
  @callback read(GenServer.server(), String.t(), map()) :: {:ok, map()} | {:error, term()}

  def offer(store) do
    transaction(store, fn conn ->
      partitions =
        rows!(
          conn,
          "SELECT * FROM edge_partitions ORDER BY memory_space_id, scope, namespace LIMIT 101",
          []
        )

      if length(partitions) > 100, do: DBConnection.rollback(conn, :too_many_partitions)

      %{
        "offers" => ["host_memory.v2"],
        "max_frame_bytes" => 524_288,
        "partitions" =>
          Enum.map(partitions, fn p ->
            Map.merge(Map.take(p, @partition_keys), %{
              "applied_revision" => p["applied_revision"],
              "status" => p["sync_status"],
              "snapshot" =>
                if(p["snapshot_id"],
                  do: %{
                    "snapshot_id" => p["snapshot_id"],
                    "next_chunk_index" => p["next_chunk_index"]
                  },
                  else: nil
                )
            })
          end)
      }
    end)
  end

  def apply_delivery(store, d) do
    result =
      transaction(store, fn conn ->
        p = d["partition"]

        execute!(
          conn,
          "INSERT INTO edge_partitions (memory_space_id, scope, namespace) VALUES (?, ?, ?) ON CONFLICT DO NOTHING",
          params(p)
        )

        state = partition!(conn, p)
        digest = hash(d)

        if state["last_batch_id"] == d["batch_id"] and state["last_delivery_hash"] != digest,
          do: DBConnection.rollback(conn, :delivery_conflict)

        case d["kind"] do
          "delta" -> delta!(conn, d, state, digest)
          "snapshot_chunk" -> snapshot!(conn, d, state, digest)
        end
      end)

    case result do
      {:ok, {:recovery, reason}} ->
        {:error, reason}

      {:ok, {:activated, ack}} ->
        # This separate transaction cannot remove the old generation before activation commits.
        transaction(store, fn conn ->
          active = partition!(conn, d["partition"])["active_generation"]

          execute!(
            conn,
            "DELETE FROM edge_memories WHERE #{@where} AND generation != ? AND generation != COALESCE((SELECT snapshot_id FROM edge_partitions WHERE #{@where}), '')",
            params(d["partition"]) ++ [active] ++ params(d["partition"])
          )
        end)

        {:ok, ack}

      other ->
        other
    end
  end

  defp delta!(conn, d, state, digest) do
    cond do
      d["to_revision"] <= state["applied_revision"] ->
        ack(d)

      state["snapshot_id"] != nil ->
        DBConnection.rollback(conn, :snapshot_restart_required)

      d["from_revision"] != state["applied_revision"] + 1 or
          state["sync_status"] == "snapshot_required" ->
        execute!(
          conn,
          "UPDATE edge_partitions SET sync_status = 'snapshot_required' WHERE #{@where}",
          params(d["partition"])
        )

        {:recovery, :snapshot_required}

      true ->
        Enum.each(d["changes"], fn change ->
          put_memory!(
            conn,
            d["partition"],
            state["active_generation"],
            change["payload"],
            change["revision"],
            change["op"]
          )
        end)

        execute!(
          conn,
          "UPDATE edge_partitions SET applied_revision = ?, last_batch_id = ?, last_delivery_hash = ?, last_sync_at = ?, sync_status = 'ready' WHERE #{@where}",
          [d["to_revision"], d["batch_id"], digest, now()] ++ params(d["partition"])
        )

        ack(d)
    end
  end

  defp snapshot!(conn, d, state, digest) do
    cond do
      state["last_batch_id"] == d["batch_id"] ->
        ack(d)

      d["to_revision"] < state["applied_revision"] ->
        DBConnection.rollback(conn, :snapshot_restart_required)

      state["active_generation"] == d["snapshot_id"] ->
        activated_snapshot_duplicate!(conn, d, state)

      state["snapshot_id"] == d["snapshot_id"] ->
        continue_snapshot!(conn, d, state, digest)

      d["chunk_index"] == 0 and d["base_revision"] == state["applied_revision"] ->
        # A fresh server snapshot can safely replace an interrupted staging generation.
        execute!(
          conn,
          "DELETE FROM edge_memories WHERE #{@where} AND generation = ?",
          params(d["partition"]) ++ [d["snapshot_id"]]
        )

        execute!(conn, "DELETE FROM edge_snapshot_chunks WHERE snapshot_id = ?", [
          d["snapshot_id"]
        ])

        execute!(
          conn,
          "UPDATE edge_partitions SET snapshot_id = ?, snapshot_revision = ?, next_chunk_index = 0, chunk_count = ?, integrity_hash = ? WHERE #{@where}",
          [d["snapshot_id"], d["to_revision"], d["chunk_count"], d["integrity_hash"]] ++
            params(d["partition"])
        )

        continue_snapshot!(conn, d, partition!(conn, d["partition"]), digest)

      true ->
        DBConnection.rollback(conn, :snapshot_restart_required)
    end
  end

  defp continue_snapshot!(conn, d, state, digest) do
    unless state["snapshot_revision"] == d["to_revision"] and
             state["chunk_count"] == d["chunk_count"] and
             state["integrity_hash"] == d["integrity_hash"] and
             state["applied_revision"] == d["base_revision"],
           do: DBConnection.rollback(conn, :delivery_conflict)

    prior =
      rows!(
        conn,
        "SELECT chunk_hash FROM edge_snapshot_chunks WHERE snapshot_id = ? AND chunk_index = ?",
        [d["snapshot_id"], d["chunk_index"]]
      )

    expected_hash = d["chunk_hash"]

    case prior do
      [%{"chunk_hash" => ^expected_hash}] ->
        ack(d)

      [_] ->
        DBConnection.rollback(conn, :delivery_conflict)

      [] ->
        if d["chunk_index"] != state["next_chunk_index"],
          do: DBConnection.rollback(conn, :snapshot_restart_required)

        Enum.each(d["items"], fn item ->
          put_memory!(conn, d["partition"], d["snapshot_id"], item, d["to_revision"], "snapshot")
        end)

        execute!(conn, "INSERT INTO edge_snapshot_chunks VALUES (?, ?, ?, ?)", [
          d["snapshot_id"],
          d["chunk_index"],
          d["chunk_hash"],
          now()
        ])

        if d["chunk_index"] + 1 == d["chunk_count"] do
          activate!(conn, d, digest)
        else
          execute!(
            conn,
            "UPDATE edge_partitions SET next_chunk_index = ?, last_batch_id = ?, last_delivery_hash = ? WHERE #{@where}",
            [d["chunk_index"] + 1, d["batch_id"], digest] ++ params(d["partition"])
          )

          ack(d)
        end
    end
  end

  defp activate!(conn, d, digest) do
    # Read manifest hashes in bounded pages; chunk data was integrity checked before insertion.
    context = manifest!(conn, d["snapshot_id"], 0, d["chunk_count"], :crypto.hash_init(:sha256))
    manifest = "sha256:" <> Base.encode16(:crypto.hash_final(context), case: :lower)

    [%{"count" => count}] =
      rows!(
        conn,
        "SELECT COUNT(*) AS count FROM edge_memories WHERE #{@where} AND generation = ?",
        params(d["partition"]) ++ [d["snapshot_id"]]
      )

    if manifest != d["integrity_hash"] or count != d["item_count"],
      do: DBConnection.rollback(conn, :integrity_failure)

    execute!(
      conn,
      "UPDATE edge_partitions SET active_generation = ?, applied_revision = ?, last_batch_id = ?, last_delivery_hash = ?, last_sync_at = ?, sync_status = 'ready', snapshot_id = NULL, snapshot_revision = NULL, next_chunk_index = NULL, chunk_count = NULL, integrity_hash = NULL WHERE #{@where}",
      [d["snapshot_id"], d["to_revision"], d["batch_id"], digest, now()] ++ params(d["partition"])
    )

    {:activated, ack(d)}
  end

  defp activated_snapshot_duplicate!(conn, d, state) do
    [chunk] =
      rows!(
        conn,
        "SELECT chunk_hash FROM edge_snapshot_chunks WHERE snapshot_id = ? AND chunk_index = ?",
        [d["snapshot_id"], d["chunk_index"]]
      )

    context = manifest!(conn, d["snapshot_id"], 0, d["chunk_count"], :crypto.hash_init(:sha256))
    manifest = "sha256:" <> Base.encode16(:crypto.hash_final(context), case: :lower)

    [%{"count" => count}] =
      rows!(
        conn,
        "SELECT COUNT(*) AS count FROM edge_memories WHERE #{@where} AND generation = ?",
        params(d["partition"]) ++ [d["snapshot_id"]]
      )

    if chunk["chunk_hash"] == d["chunk_hash"] and state["applied_revision"] == d["to_revision"] and
         manifest == d["integrity_hash"] and count == d["item_count"],
       do: ack(d),
       else: DBConnection.rollback(conn, :delivery_conflict)
  end

  defp manifest!(_conn, _id, count, count, context), do: context

  defp manifest!(conn, id, offset, count, context) do
    hashes =
      rows!(
        conn,
        "SELECT chunk_index, chunk_hash FROM edge_snapshot_chunks WHERE snapshot_id = ? AND chunk_index >= ? ORDER BY chunk_index LIMIT 100",
        [id, offset]
      )

    if hashes == [] or length(hashes) > count - offset,
      do: DBConnection.rollback(conn, :integrity_failure)

    context =
      Enum.with_index(hashes, offset)
      |> Enum.reduce(context, fn {row, index}, acc ->
        if row["chunk_index"] != index, do: DBConnection.rollback(conn, :integrity_failure)
        :crypto.hash_update(acc, row["chunk_hash"])
      end)

    manifest!(conn, id, offset + length(hashes), count, context)
  end

  defp put_memory!(conn, p, generation, item, revision, operation) do
    deleted = operation == "delete"

    values =
      params(p) ++
        [
          generation,
          item["canonical_id"],
          if(deleted, do: nil, else: item["memory_type"]),
          if(deleted, do: nil, else: item["content"]),
          if(deleted, do: nil, else: item["content_hash"]),
          if(deleted, do: nil, else: item["confidence"]),
          if(deleted, do: "deleted", else: item["lifecycle_state"]),
          Jason.encode!(if(deleted, do: [], else: item["tags"])),
          Jason.encode!(if(deleted, do: %{}, else: item["metadata"])),
          Jason.encode!(Map.get(item, "source_refs", [])),
          revision,
          item["edge_priority"],
          item["expires_at"],
          item["updated_at"],
          byte_size(Jason.encode!(item))
        ]

    conflict =
      if operation == "snapshot",
        do: "",
        else:
          " ON CONFLICT (memory_space_id, scope, namespace, generation, canonical_id) DO UPDATE SET memory_type = excluded.memory_type, content = excluded.content, content_hash = excluded.content_hash, confidence = excluded.confidence, lifecycle_state = excluded.lifecycle_state, tags = excluded.tags, metadata = excluded.metadata, source_refs = excluded.source_refs, server_revision = excluded.server_revision, edge_priority = excluded.edge_priority, edge_expires_at = excluded.edge_expires_at, updated_at = excluded.updated_at, byte_size = excluded.byte_size WHERE excluded.server_revision > edge_memories.server_revision"

    execute!(
      conn,
      "INSERT INTO edge_memories (memory_space_id, scope, namespace, generation, canonical_id, memory_type, content, content_hash, confidence, lifecycle_state, tags, metadata, source_refs, server_revision, edge_priority, edge_expires_at, updated_at, byte_size) VALUES (#{Enum.map_join(values, ",", fn _ -> "?" end)})" <>
        conflict,
      values
    )
  end

  def read(store, operation, args) do
    transaction(store, fn conn ->
      p = partition!(conn, args)

      if p == nil or p["last_sync_at"] == nil,
        do: DBConnection.rollback(conn, :mirror_unavailable)

      timestamp = now()

      filters =
        "#{@where} AND generation = ? AND lifecycle_state IN ('active', 'disputed') AND (edge_expires_at IS NULL OR edge_expires_at > ?)"

      values = params(args) ++ [p["active_generation"], timestamp]

      data =
        if operation == "stats" do
          [stats] =
            rows!(conn, "SELECT COUNT(*) AS count FROM edge_memories WHERE " <> filters, values)

          stats
        else
          query = if operation == "recall", do: Map.get(args, "query", ""), else: ""

          items =
            rows!(
              conn,
              "SELECT canonical_id, memory_type, content, content_hash, confidence, lifecycle_state, tags, metadata, source_refs, server_revision, edge_expires_at FROM edge_memories WHERE " <>
                filters <>
                " AND instr(lower(content), lower(?)) > 0 ORDER BY canonical_id LIMIT ?",
              values ++ [query, args["limit"]]
            )

          %{
            "items" =>
              Enum.map(items, fn item ->
                Enum.reduce(["tags", "metadata", "source_refs"], item, fn key, acc ->
                  Map.update!(acc, key, &Jason.decode!/1)
                end)
              end)
          }
        end

      {:ok, as_of, _} = DateTime.from_iso8601(p["last_sync_at"])

      result =
        Map.merge(data, %{
          "mode" => "offline",
          "authority" => "canonical",
          "source" => "edge_mirror",
          "consistency" => "bounded_stale",
          "stale" => true,
          "history_available" => true,
          "as_of" => p["last_sync_at"],
          "partition_revision" => p["applied_revision"],
          "last_sync_age_seconds" => max(DateTime.diff(DateTime.utc_now(), as_of), 0)
        })

      bound_result(result)
    end)
  end

  defp ack(%{"kind" => "delta"} = d),
    do:
      Map.merge(Map.take(d, ["protocol", "partition", "batch_id"]), %{
        "status" => "applied",
        "applied_revision" => d["to_revision"],
        "snapshot_id" => nil,
        "next_chunk_index" => nil,
        "chunk_hash" => nil,
        "integrity_hash" => nil
      })

  defp ack(d) do
    final = d["chunk_index"] + 1 == d["chunk_count"]

    Map.merge(
      Map.take(d, [
        "protocol",
        "partition",
        "batch_id",
        "snapshot_id",
        "chunk_hash",
        "integrity_hash"
      ]),
      %{
        "status" => if(final, do: "applied", else: "progress"),
        "applied_revision" => if(final, do: d["to_revision"], else: d["base_revision"]),
        "next_chunk_index" => d["chunk_index"] + 1
      }
    )
  end

  defp partition!(conn, p),
    do: List.first(rows!(conn, "SELECT * FROM edge_partitions WHERE #{@where}", params(p)))

  defp params(p), do: Enum.map(@partition_keys, &Map.fetch!(p, &1))
  defp now, do: DateTime.to_iso8601(DateTime.utc_now())

  defp rows!(conn, sql, params) do
    case Edge.query(conn, sql, params) do
      {:ok, %{rows: rows}} -> rows
      {:error, reason} -> DBConnection.rollback(conn, reason)
    end
  end

  defp execute!(conn, sql, params) do
    case Edge.execute(conn, sql, params) do
      {:ok, result} -> result
      {:error, reason} -> DBConnection.rollback(conn, reason)
    end
  end

  defp transaction(store, fun) do
    Edge.transaction(store, fun)
  rescue
    error -> {:error, {:storage_failure, error.__struct__}}
  catch
    :exit, _ -> {:error, :storage_unavailable}
  end

  # The transport ceiling applies to a complete offline response, not merely its
  # SQL row limit.  Rows are ordered deterministically above, so removing tail
  # rows preserves a stable bounded prefix.
  defp bound_result(%{"items" => items} = result) do
    items
    |> Enum.reduce_while([], fn item, accepted ->
      candidate = result |> Map.put("items", accepted ++ [item]) |> Jason.encode!()

      if byte_size(candidate) <= 524_288,
        do: {:cont, accepted ++ [item]},
        else: {:halt, accepted}
    end)
    |> then(&Map.put(result, "items", &1))
  end

  defp bound_result(result), do: result

  @doc false
  def hash(payload),
    do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, canonical(payload)), case: :lower)

  defp canonical(map) when is_map(map),
    do: [
      "{",
      map
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {key, value} -> [Jason.encode!(key), ":", canonical(value)] end)
      |> Enum.intersperse(","),
      "}"
    ]

  defp canonical(list) when is_list(list),
    do: ["[", list |> Enum.map(&canonical/1) |> Enum.intersperse(","), "]"]

  defp canonical(value), do: Jason.encode!(value)
end

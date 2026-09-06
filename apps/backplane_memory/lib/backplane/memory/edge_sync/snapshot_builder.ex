defmodule Backplane.Memory.EdgeSync.SnapshotBuilder do
  @moduledoc "Revision-pinned canonical snapshots streamed into bounded durable chunks."
  import Ecto.Query
  alias Backplane.Memory.EdgeSync
  alias EdgeSync.{PostgresStore, Snapshot, SnapshotChunk}
  alias Backplane.MemorySpaces.BackfillIssue

  @doc "Explicit deterministic rebuild, even when this partition's initial snapshot issue blocks delivery."
  def rebuild(host, partition, limits \\ %{max_changes: 100, max_frame_bytes: 524_288}) do
    EdgeSync.safe(fn ->
      result =
        repo().transaction(fn ->
          p = PostgresStore.authorize!(host, partition, true)
          snapshot = build_locked(p, limits)
          resolve_issue(p)
          snapshot
        end)

      case result do
        {:error, {:snapshot_build_unavailable, p, failed_revision}} ->
          record_failure(p, failed_revision)
          {:error, :snapshot_build_unavailable}

        other ->
          other
      end
    end)
  end

  @doc false
  def build_locked(p, limits) do
    revision = PostgresStore.lock_revision(p)
    build_at_revision(p, limits, revision.current_revision)
  end

  defp build_at_revision(p, limits, revision) do
    snapshot =
      repo().insert!(
        struct(
          Snapshot,
          Map.merge(p, %{
            revision: revision,
            status: "building",
            item_count: 0,
            chunk_count: 0,
            expires_at: DateTime.add(DateTime.utc_now(), 3600),
            inserted_at: DateTime.utc_now()
          })
        )
      )

    sql =
      "SELECT bpm_memory_edge_payload(m) FROM bpm_memories m WHERE memory_space_id=$1 AND scope=$2 AND namespace=$3 AND bpm_memory_edge_eligible(m) ORDER BY id"

    initial = %{items: [], count: 0, index: 0, hash: :crypto.hash_init(:sha256)}

    state =
      Ecto.Adapters.SQL.stream(
        repo(),
        sql,
        [Ecto.UUID.dump!(p.memory_space_id), p.scope, p.namespace],
        max_rows: limits.max_changes
      )
      |> Enum.reduce(initial, fn result, state ->
        Enum.reduce(result.rows, state, fn [item], acc -> append(snapshot, acc, item, limits) end)
      end)

    state = if state.items != [] or state.index == 0, do: flush(snapshot, state), else: state
    hash = "sha256:" <> Base.encode16(:crypto.hash_final(state.hash), case: :lower)

    snapshot
    |> Ecto.Changeset.change(
      status: "ready",
      chunk_count: state.index,
      item_count: state.count,
      integrity_hash: hash
    )
    |> repo().update!()
  rescue
    _error in [
      Postgrex.Error,
      DBConnection.ConnectionError,
      Ecto.InvalidChangesetError,
      Ecto.ConstraintError
    ] ->
      repo().rollback({:snapshot_build_unavailable, p, revision})
  end

  defp append(snapshot, state, item, limits) do
    items = state.items ++ [item]

    if length(items) <= limits.max_changes and fits?(snapshot, state.index, items, limits) do
      %{state | items: items}
    else
      if state.items == [], do: repo().rollback(:payload_too_large)
      state = flush(snapshot, state)
      if not fits?(snapshot, state.index, [item], limits), do: repo().rollback(:payload_too_large)
      %{state | items: [item]}
    end
  end

  defp fits?(snapshot, index, items, limits) do
    chunk = %SnapshotChunk{
      chunk_index: index,
      chunk_hash: "sha256:" <> String.duplicate("0", 64),
      payload: %{"items" => items}
    }

    conservative = %{
      snapshot
      | chunk_count: 2_147_483_647,
        item_count: 2_147_483_647,
        integrity_hash: chunk.chunk_hash
    }

    frame =
      frame(conservative, chunk, "00000000-0000-0000-0000-000000000000")
      |> Map.put("base_revision", 9_223_372_036_854_775_807)

    PostgresStore.bytes(frame) <= limits.max_frame_bytes
  end

  defp flush(snapshot, state) do
    payload = %{"items" => state.items}
    hash = hash(payload)

    repo().insert!(%SnapshotChunk{
      snapshot_id: snapshot.id,
      chunk_index: state.index,
      item_count: length(state.items),
      encoded_bytes: PostgresStore.bytes(payload),
      payload: payload,
      chunk_hash: hash
    })

    %{
      state
      | items: [],
        count: state.count + length(state.items),
        index: state.index + 1,
        hash: :crypto.hash_update(state.hash, hash)
    }
  end

  @doc "Canonical JSON hash, independent of PostgreSQL JSON object key ordering."
  def hash(payload),
    do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, canonical(payload)), case: :lower)

  defp canonical(map) when is_map(map),
    do: [
      "{",
      map
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {k, v} -> [Jason.encode!(k), ":", canonical(v)] end)
      |> Enum.intersperse(","),
      "}"
    ]

  defp canonical(list) when is_list(list),
    do: ["[", list |> Enum.map(&canonical/1) |> Enum.intersperse(","), "]"]

  defp canonical(value), do: Jason.encode!(value)

  @doc false
  def frame(snapshot, chunk, batch_id) do
    %{
      "protocol" => "host_memory.v2",
      "status" => "batch",
      "kind" => "snapshot_chunk",
      "batch_id" => batch_id,
      "partition" => PostgresStore.wire_partition(snapshot),
      "snapshot_id" => snapshot.id,
      "chunk_index" => chunk.chunk_index,
      "chunk_count" => snapshot.chunk_count,
      "item_count" => snapshot.item_count,
      "to_revision" => snapshot.revision,
      "chunk_hash" => chunk.chunk_hash,
      "integrity_hash" => snapshot.integrity_hash,
      "items" => chunk.payload["items"]
    }
  end

  @doc false
  def issue_id(p) do
    id = p[:memory_space_id] || p["memory_space_id"]
    scope = p[:scope] || p["scope"]
    namespace = p[:namespace] || p["namespace"]
    hash([id, scope, namespace])
  end

  @doc false
  def record_failure(p, failed_revision) do
    repo().transaction(fn ->
      PostgresStore.lock_revision(p)
      now = DateTime.utc_now()

      # Rollback released the build lock. A newer successful rebuild may have
      # completed before this bookkeeping acquired it again.
      ready? =
        repo().exists?(
          from(s in PostgresStore.partition_query(Snapshot, p),
            where:
              s.status == "ready" and s.revision >= ^failed_revision and
                s.expires_at > ^now
          )
        )

      unless ready?, do: put_failure(p, now)
    end)

    :ok
  end

  defp put_failure(p, now) do
    attrs = %{
      id: Ecto.UUID.generate(),
      source_table: "initial_snapshot",
      source_id: issue_id(p),
      reason: "initial_snapshot_build_failed",
      disposition: "pending",
      details: PostgresStore.wire_partition(p),
      inserted_at: now,
      updated_at: now
    }

    repo().insert_all(BackfillIssue, [attrs],
      conflict_target: [:source_table, :source_id],
      on_conflict: [set: [disposition: "pending", resolved_at: nil, updated_at: now]]
    )
  end

  defp resolve_issue(p) do
    details = PostgresStore.wire_partition(p)

    repo().update_all(
      from(i in BackfillIssue,
        where:
          i.source_table == "initial_snapshot" and fragment("? @> ?::jsonb", i.details, ^details)
      ),
      set: [
        disposition: "resolved",
        resolved_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      ]
    )
  end

  defp repo, do: PostgresStore.repo()
end

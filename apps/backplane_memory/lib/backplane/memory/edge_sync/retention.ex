defmodule Backplane.Memory.EdgeSync.Retention do
  @moduledoc "Bounded edge change and snapshot retention with a recoverable snapshot frontier."

  alias Backplane.Memory.EdgeSync.PostgresStore
  alias Backplane.Memory.EdgeSync.SnapshotBuilder

  def prune(opts \\ []) do
    max_changes = positive(opts[:max_changes_per_partition], 10_000)
    max_snapshots = positive(opts[:max_snapshots_per_partition], 2)
    delivery_days = positive(opts[:delivery_retention_days], 7)
    max_partitions = positive(opts[:max_partitions], 100)
    max_deletes = positive(opts[:max_deletes], 1_000)

    PostgresStore.repo().transaction(fn ->
      changes = prune_changes(max_changes, max_partitions, max_deletes)
      snapshots = prune_snapshots(max_snapshots, max_deletes)
      deliveries = prune_deliveries(delivery_days, max_deletes)

      %{
        changes: changes,
        snapshots: snapshots,
        deliveries: deliveries,
        continued:
          changes_remaining?(max_changes) or snapshots == max_deletes or
            deliveries == max_deletes
      }
    end)
  end

  defp prune_changes(max_changes, max_partitions, max_deletes) do
    partitions =
      sql!(
        """
        SELECT r.memory_space_id,r.scope,r.namespace
        FROM bpm_memory_partition_revisions r
        WHERE (SELECT count(*) FROM bpm_memory_changes c
               WHERE c.memory_space_id=r.memory_space_id AND c.scope=r.scope
                 AND c.namespace=r.namespace) > $1
        ORDER BY r.memory_space_id,r.scope,r.namespace
        LIMIT $2
        """,
        [max_changes, max_partitions]
      ).rows

    {deleted, _remaining} =
      Enum.reduce_while(partitions, {0, max_deletes}, fn
        _partition, {total, 0} ->
          {:halt, {total, 0}}

        [space, scope, namespace], {total, remaining} ->
          params = [space, scope, namespace]

          cutoff =
            case sql!(
                   "SELECT revision FROM bpm_memory_changes WHERE memory_space_id=$1 AND scope=$2 AND namespace=$3 ORDER BY revision DESC OFFSET $4 LIMIT 1",
                   params ++ [max_changes]
                 ).rows do
              [[value]] -> value
              _ -> nil
            end

          frontier =
            if cutoff, do: recoverable_frontier(space, scope, namespace, cutoff), else: nil

          prune_through = if frontier && cutoff, do: min(frontier, cutoff), else: nil

          if prune_through do
            revisions =
              sql!(
                "SELECT revision FROM bpm_memory_changes WHERE memory_space_id=$1 AND scope=$2 AND namespace=$3 AND revision <= $4 ORDER BY revision LIMIT $5",
                params ++ [prune_through, remaining]
              ).rows

            actual_prune_through =
              case List.last(revisions) do
                [revision] -> revision
                nil -> nil
              end

            if actual_prune_through do
              result =
                sql!(
                  "DELETE FROM bpm_memory_changes WHERE memory_space_id=$1 AND scope=$2 AND namespace=$3 AND revision <= $4",
                  params ++ [actual_prune_through]
                )

              sql!(
                "UPDATE bpm_memory_partition_revisions SET first_available_revision=GREATEST(first_available_revision,$4 + 1), updated_at=now() WHERE memory_space_id=$1 AND scope=$2 AND namespace=$3",
                params ++ [actual_prune_through]
              )

              {:cont, {total + result.num_rows, remaining - result.num_rows}}
            else
              {:cont, {total, remaining}}
            end
          else
            {:cont, {total, remaining}}
          end
      end)

    deleted
  end

  defp changes_remaining?(max_changes) do
    sql!(
      """
      SELECT EXISTS (
        SELECT 1 FROM bpm_memory_partition_revisions r
        WHERE (SELECT count(*) FROM bpm_memory_changes c
               WHERE c.memory_space_id=r.memory_space_id AND c.scope=r.scope
                 AND c.namespace=r.namespace) > $1
      )
      """,
      [max_changes]
    ).rows == [[true]]
  end

  defp recoverable_frontier(space, scope, namespace, cutoff) do
    params = [space, scope, namespace]

    frontier =
      case sql!(
             "SELECT MAX(revision) FROM bpm_memory_snapshots WHERE memory_space_id=$1 AND scope=$2 AND namespace=$3 AND status='ready' AND expires_at > now()",
             params
           ).rows do
        [[value]] -> value
        _ -> nil
      end

    if is_integer(frontier) and frontier >= cutoff do
      frontier
    else
      p = %{memory_space_id: Ecto.UUID.load!(space), scope: scope, namespace: namespace}
      SnapshotBuilder.build_locked(p, %{max_changes: 100, max_frame_bytes: 524_288}).revision
    end
  end

  defp prune_snapshots(max_snapshots, max_deletes) do
    sql!(
      """
      WITH protected AS (
        SELECT DISTINCT ON (memory_space_id,scope,namespace) id
        FROM bpm_memory_snapshots
        WHERE status='ready' AND expires_at > now()
        ORDER BY memory_space_id,scope,namespace,revision DESC,inserted_at DESC,id
      ), ranked AS (
        SELECT id, row_number() OVER (
          PARTITION BY memory_space_id,scope,namespace ORDER BY revision DESC, inserted_at DESC, id
        ) AS position
        FROM bpm_memory_snapshots
        WHERE status IN ('ready','expired')
      ), doomed AS (
        SELECT id FROM ranked
        WHERE position > $1
          AND id NOT IN (SELECT id FROM protected)
          AND id NOT IN (SELECT active_snapshot_id FROM bpm_host_memory_cursors WHERE active_snapshot_id IS NOT NULL)
          AND id NOT IN (SELECT snapshot_id FROM bpm_host_memory_deliveries WHERE snapshot_id IS NOT NULL AND status='issued')
        ORDER BY id LIMIT $2
      )
      DELETE FROM bpm_memory_snapshots s USING doomed d WHERE s.id=d.id
      """,
      [max_snapshots, max_deletes]
    ).num_rows
  end

  defp prune_deliveries(days, max_deletes) do
    sql!(
      """
      WITH doomed AS (
        SELECT id FROM bpm_host_memory_deliveries
        WHERE status IN ('acknowledged','progress','expired')
          AND COALESCE(acknowledged_at,issued_at) < now() - ($1 * interval '1 day')
        ORDER BY COALESCE(acknowledged_at,issued_at),id LIMIT $2
      )
      DELETE FROM bpm_host_memory_deliveries d USING doomed x WHERE d.id=x.id
      """,
      [days, max_deletes]
    ).num_rows
  end

  defp sql!(query, params), do: Ecto.Adapters.SQL.query!(PostgresStore.repo(), query, params)
  defp positive(value, _default) when is_integer(value) and value > 0, do: value
  defp positive(_value, default), do: default
end

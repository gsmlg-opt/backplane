defmodule Backplane.Memory.EdgeSync.RetentionTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.EdgeSync.Retention

  test "change pruning stops at the newest durable recoverable snapshot frontier" do
    space = "00000000-0000-0000-0000-000000000001"
    p = %{memory_space_id: space, scope: "retention", namespace: "private"}
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    insert_space(space, now)
    insert_revision(p, now)
    Enum.each(1..8, &insert_change(p, &1, now))

    assert {:ok, %{changes: 2, continued: true}} =
             Retention.prune(max_changes_per_partition: 2, max_deletes: 2)

    assert revisions(space) == [3, 4, 5, 6, 7, 8]

    assert [[3]] =
             repo().query!(
               "SELECT first_available_revision FROM bpm_memory_partition_revisions WHERE memory_space_id=$1",
               [Ecto.UUID.dump!(space)]
             ).rows

    assert {:ok, %{changes: 2, continued: true}} =
             Retention.prune(max_changes_per_partition: 2, max_deletes: 2)

    assert revisions(space) == [5, 6, 7, 8]

    assert {:ok, %{changes: 2}} =
             Retention.prune(max_changes_per_partition: 2, max_deletes: 2)

    assert revisions(space) == [7, 8]

    assert [[7]] =
             repo().query!(
               "SELECT first_available_revision FROM bpm_memory_partition_revisions WHERE memory_space_id=$1",
               [Ecto.UUID.dump!(space)]
             ).rows

    assert [[8, "ready"]] =
             repo().query!(
               "SELECT revision,status FROM bpm_memory_snapshots WHERE memory_space_id=$1",
               [Ecto.UUID.dump!(space)]
             ).rows

    active = insert_snapshot(p, 6, now)
    _obsolete = insert_snapshot(p, 7, now)
    _newer_expired = insert_snapshot(p, 9, now, "expired")
    issued = insert_snapshot(p, 5, now)
    host = Ecto.UUID.generate()

    repo().query!(
      "INSERT INTO bpm_host_memory_cursors (host_id,memory_space_id,scope,namespace,applied_revision,active_snapshot_id,snapshot_next_chunk_index) VALUES ($1,$2,$3,$4,0,$5,0)",
      [
        Ecto.UUID.dump!(host),
        Ecto.UUID.dump!(space),
        p.scope,
        p.namespace,
        Ecto.UUID.dump!(active)
      ]
    )

    delivery_host = Ecto.UUID.generate()

    repo().query!(
      "INSERT INTO bpm_host_memory_cursors (host_id,memory_space_id,scope,namespace,applied_revision) VALUES ($1,$2,$3,$4,0)",
      [Ecto.UUID.dump!(delivery_host), Ecto.UUID.dump!(space), p.scope, p.namespace]
    )

    repo().query!(
      "INSERT INTO bpm_memory_snapshot_chunks (snapshot_id,chunk_index,item_count,encoded_bytes,chunk_hash,payload) VALUES ($1,0,0,2,'chunk','{}')",
      [Ecto.UUID.dump!(issued)]
    )

    repo().query!(
      "INSERT INTO bpm_host_memory_deliveries (host_id,memory_space_id,scope,namespace,kind,snapshot_id,chunk_index,to_revision,payload,encoded_bytes,chunk_hash,integrity_hash,status) VALUES ($1,$2,$3,$4,'snapshot_chunk',$5,0,5,'{}',2,'chunk','hash','issued')",
      [
        Ecto.UUID.dump!(delivery_host),
        Ecto.UUID.dump!(space),
        p.scope,
        p.namespace,
        Ecto.UUID.dump!(issued)
      ]
    )

    assert {:ok, _} =
             Retention.prune(max_changes_per_partition: 2, max_snapshots_per_partition: 1)

    assert [[5], [6], [8], [9]] =
             repo().query!(
               "SELECT revision FROM bpm_memory_snapshots WHERE memory_space_id=$1 ORDER BY revision",
               [Ecto.UUID.dump!(space)]
             ).rows
  end

  defp insert_space(id, now) do
    repo().query!(
      "INSERT INTO bpm_memory_spaces (id,kind,status,inserted_at,updated_at) VALUES ($1,'private','active',$2,$2)",
      [Ecto.UUID.dump!(id), now]
    )
  end

  defp insert_revision(p, now) do
    repo().query!("INSERT INTO bpm_memory_partition_revisions VALUES ($1,$2,$3,8,1,$4)", [
      Ecto.UUID.dump!(p.memory_space_id),
      p.scope,
      p.namespace,
      now
    ])
  end

  defp insert_change(p, revision, now) do
    repo().query!("INSERT INTO bpm_memory_changes VALUES ($1,$2,$3,$4,'upsert',$5,'{}',2,$6)", [
      Ecto.UUID.dump!(p.memory_space_id),
      p.scope,
      p.namespace,
      revision,
      Ecto.UUID.dump!(Ecto.UUID.generate()),
      now
    ])
  end

  defp insert_snapshot(p, revision, now, status \\ "ready") do
    id = Ecto.UUID.generate()
    expires_at = if status == "ready", do: DateTime.add(now, 3600), else: DateTime.add(now, -3600)

    repo().query!(
      "INSERT INTO bpm_memory_snapshots (id,memory_space_id,scope,namespace,revision,item_count,chunk_count,integrity_hash,status,expires_at,inserted_at) VALUES ($1,$2,$3,$4,$5,0,1,'hash',$6,$7,$8)",
      [
        Ecto.UUID.dump!(id),
        Ecto.UUID.dump!(p.memory_space_id),
        p.scope,
        p.namespace,
        revision,
        status,
        expires_at,
        now
      ]
    )

    id
  end

  defp revisions(space) do
    repo().query!(
      "SELECT revision FROM bpm_memory_changes WHERE memory_space_id=$1 ORDER BY revision",
      [Ecto.UUID.dump!(space)]
    ).rows
    |> List.flatten()
  end
end

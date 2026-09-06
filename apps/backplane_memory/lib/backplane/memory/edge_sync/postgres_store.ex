defmodule Backplane.Memory.EdgeSync.PostgresStore do
  @moduledoc "PostgreSQL serialization, exact durable delivery retries and issued ACK binding."
  @behaviour Backplane.Memory.EdgeSync.Store
  import Ecto.Query

  alias Backplane.Memory.EdgeSync.{
    Change,
    Cursor,
    Delivery,
    PartitionRevision,
    Snapshot,
    SnapshotChunk,
    SnapshotBuilder
  }

  alias Backplane.MemorySpaces

  @impl true
  def negotiate(host, offer) do
    with {:ok, inventory} <- MemorySpaces.host_entitlements(host),
         {:ok, limits} <- Backplane.Memory.EdgeSync.limits(offer) do
      claims = Enum.map(offer["partitions"], &claim_status(host, inventory, &1))

      partitions =
        Enum.map(inventory, fn p ->
          revision = repo().one(partition_query(PartitionRevision, p))
          cursor = repo().one(host_query(Cursor, host, p))

          status =
            cond do
              not MemorySpaces.partition_ready?(host, p) ->
                "partition_not_ready"

              is_nil(cursor) or is_nil(cursor.acknowledged_at) or
                  not is_nil(cursor.active_snapshot_id) ->
                "snapshot_required"

              true ->
                "ready"
            end

          Map.merge(wire_partition(p), %{
            "current_revision" => if(revision, do: revision.current_revision, else: 0),
            "applied_revision" => if(cursor, do: cursor.applied_revision, else: 0),
            "status" => status
          })
        end)

      response = %{
        selected: "host_memory.v2",
        limits: limits,
        partitions: partitions,
        claims: claims
      }

      if bytes(response) <= limits.max_frame_bytes,
        do: {:ok, response},
        else: {:error, :payload_too_large}
    end
  end

  defp claim_status(host, inventory, claim) do
    case resolve_from(inventory, claim) do
      {:ok, p} ->
        if MemorySpaces.partition_ready?(host, p),
          do: %{partition: wire_partition(p), status: :ready},
          else: %{code: :partition_not_ready}

      {:error, code} ->
        %{code: code}
    end
  end

  @impl true
  def next(host, request, limits) do
    result =
      repo().transaction(fn ->
        p = authorize!(host, request["partition"])
        revision = lock_revision(p)
        cursor = lock_cursor(host, p)

        outstanding =
          repo().one(from(d in host_query(Delivery, host, p), where: d.status == "issued"))

        cond do
          outstanding && delivery_live?(outstanding) ->
            bounded!(outstanding.payload, limits)

          true ->
            if outstanding,
              do:
                repo().update_all(where(Delivery, id: ^outstanding.id), set: [status: "expired"])

            issue_next(host, p, revision, cursor, request, limits)
        end
      end)

    case result do
      {:error, {:snapshot_build_unavailable, p, failed_revision}} ->
        SnapshotBuilder.record_failure(p, failed_revision)
        {:error, :snapshot_build_unavailable}

      other ->
        other
    end
  end

  defp issue_next(host, p, revision, cursor, request, limits) do
    snapshot = if cursor.active_snapshot_id, do: repo().get(Snapshot, cursor.active_snapshot_id)

    cond do
      snapshot && snapshot_live?(snapshot) && continuation?(cursor, request) ->
        issue_chunk(host, p, cursor, snapshot, limits)

      snapshot || request["applied_revision"] != cursor.applied_revision ||
          is_nil(cursor.acknowledged_at) ->
        start_snapshot(host, p, cursor, limits)

      cursor.applied_revision > revision.current_revision ->
        start_snapshot(host, p, cursor, limits)

      cursor.applied_revision == revision.current_revision ->
        %{
          "protocol" => "host_memory.v2",
          "status" => "current",
          "partition" => wire_partition(p),
          "applied_revision" => cursor.applied_revision
        }
        |> bounded!(limits)

      cursor.applied_revision + 1 < revision.first_available_revision ->
        start_snapshot(host, p, cursor, limits)

      true ->
        issue_delta(host, p, cursor, revision, limits)
    end
  end

  defp continuation?(cursor, request) do
    request["snapshot_id"] == cursor.active_snapshot_id and
      request["next_chunk_index"] == cursor.snapshot_next_chunk_index
  end

  defp issue_delta(host, p, cursor, revision, limits) do
    changes =
      repo().all(
        from(c in partition_query(Change, p),
          where: c.revision > ^cursor.applied_revision,
          order_by: c.revision,
          limit: ^limits.max_changes
        )
      )

    if changes == [] or
         Enum.with_index(changes, cursor.applied_revision + 1)
         |> Enum.any?(fn {c, n} -> c.revision != n end) do
      start_snapshot(host, p, cursor, limits)
    else
      id = Ecto.UUID.generate()
      base = envelope(id, p, "delta", cursor.applied_revision + 1)

      {selected, _} =
        Enum.reduce_while(changes, {[], base}, fn c, {items, _} ->
          item = %{
            "revision" => c.revision,
            "op" => c.op,
            "memory_id" => c.memory_id,
            "payload" => c.payload
          }

          items = items ++ [item]
          frame = Map.merge(base, %{"changes" => items, "to_revision" => c.revision})

          if bytes(frame) <= limits.max_frame_bytes,
            do: {:cont, {items, frame}},
            else: {:halt, {Enum.drop(items, -1), frame}}
        end)

      if selected == [], do: repo().rollback(:payload_too_large)

      frame =
        Map.merge(base, %{"changes" => selected, "to_revision" => List.last(selected)["revision"]})

      if frame["to_revision"] > revision.current_revision,
        do: repo().rollback(:transaction_conflict)

      persist(host, p, frame)
    end
  end

  defp start_snapshot(host, p, cursor, limits) do
    snapshot = SnapshotBuilder.build_locked(p, limits)

    repo().update_all(host_query(Cursor, host, p),
      set: [active_snapshot_id: snapshot.id, snapshot_next_chunk_index: 0]
    )

    issue_chunk(
      host,
      p,
      %{cursor | active_snapshot_id: snapshot.id, snapshot_next_chunk_index: 0},
      snapshot,
      limits
    )
  end

  defp issue_chunk(host, p, cursor, snapshot, limits) do
    chunk =
      repo().one!(
        from(c in SnapshotChunk,
          where:
            c.snapshot_id == ^snapshot.id and c.chunk_index == ^cursor.snapshot_next_chunk_index
        )
      )

    frame =
      SnapshotBuilder.frame(snapshot, chunk, Ecto.UUID.generate())
      |> Map.put("base_revision", cursor.applied_revision)

    bounded!(frame, limits)
    persist(host, p, frame)
  end

  defp persist(host, p, frame) do
    repo().insert!(
      struct(
        Delivery,
        Map.merge(p, %{
          id: frame["batch_id"],
          host_id: host,
          kind: frame["kind"],
          snapshot_id: frame["snapshot_id"],
          chunk_index: frame["chunk_index"],
          from_revision: frame["from_revision"],
          to_revision: frame["to_revision"],
          payload: frame,
          encoded_bytes: bytes(frame),
          chunk_hash: frame["chunk_hash"],
          integrity_hash: frame["integrity_hash"],
          status: "issued",
          issued_at: DateTime.utc_now()
        })
      )
    )

    frame
  end

  @impl true
  def ack(host, request) do
    repo().transaction(fn ->
      delivery = repo().get(Delivery, request["batch_id"])
      if is_nil(delivery) or delivery.host_id != host, do: repo().rollback(:batch_not_found)
      p = authorize!(host, request["partition"])

      if Map.take(delivery, [:memory_space_id, :scope, :namespace]) != p,
        do: repo().rollback(:batch_conflict)

      lock_revision(p)
      cursor = lock_cursor(host, p)
      delivery = repo().get!(Delivery, delivery.id)
      expected = expected_ack(delivery, cursor)
      if Enum.any?(expected, fn {k, v} -> request[k] !== v end), do: repo().rollback(:invalid_ack)

      cond do
        delivery.status in ["acknowledged", "progress"] ->
          %{
            status: :duplicate,
            applied_revision: cursor.applied_revision,
            next_chunk_index: cursor.snapshot_next_chunk_index
          }

        delivery.status != "issued" or not delivery_live?(delivery) ->
          repo().rollback(:invalid_ack)

        delivery.kind == "delta" and
            (delivery.from_revision != cursor.applied_revision + 1 or
               cursor.active_snapshot_id != nil) ->
          repo().rollback(:invalid_ack)

        delivery.kind == "snapshot_chunk" and
            (cursor.active_snapshot_id != delivery.snapshot_id or
               cursor.snapshot_next_chunk_index != delivery.chunk_index) ->
          repo().rollback(:invalid_ack)

        true ->
          apply_ack(host, p, cursor, delivery, expected["status"])
      end
    end)
  end

  defp expected_ack(%Delivery{kind: "delta"} = d, _cursor) do
    %{
      "status" => "applied",
      "applied_revision" => d.to_revision,
      "snapshot_id" => nil,
      "next_chunk_index" => nil,
      "chunk_hash" => nil,
      "integrity_hash" => nil
    }
  end

  defp expected_ack(d, _cursor) do
    final = d.chunk_index + 1 == d.payload["chunk_count"]

    %{
      "status" => if(final, do: "applied", else: "progress"),
      "applied_revision" => if(final, do: d.to_revision, else: d.payload["base_revision"]),
      "snapshot_id" => d.snapshot_id,
      "next_chunk_index" => d.chunk_index + 1,
      "chunk_hash" => d.chunk_hash,
      "integrity_hash" => d.integrity_hash
    }
  end

  defp apply_ack(host, p, cursor, d, "progress") do
    now = DateTime.utc_now()
    repo().update_all(where(Delivery, id: ^d.id), set: [status: "progress", acknowledged_at: now])

    repo().update_all(host_query(Cursor, host, p),
      set: [snapshot_next_chunk_index: d.chunk_index + 1, last_acknowledged_batch_id: d.id]
    )

    %{
      status: :progress,
      applied_revision: cursor.applied_revision,
      next_chunk_index: d.chunk_index + 1
    }
  end

  defp apply_ack(host, p, _cursor, d, "applied") do
    now = DateTime.utc_now()

    repo().update_all(where(Delivery, id: ^d.id),
      set: [status: "acknowledged", acknowledged_at: now]
    )

    repo().update_all(host_query(Cursor, host, p),
      set: [
        applied_revision: d.to_revision,
        active_snapshot_id: nil,
        snapshot_next_chunk_index: nil,
        last_acknowledged_batch_id: d.id,
        acknowledged_at: now
      ]
    )

    %{status: :advanced, applied_revision: d.to_revision, next_chunk_index: nil}
  end

  @doc false
  def authorize!(host, claim, rebuilding_snapshot \\ false) do
    # Host lifecycle mutations take FOR UPDATE on this same row.
    case repo().query!("SELECT id FROM skill_hosts WHERE id=$1 FOR SHARE", [Ecto.UUID.dump!(host)]).rows do
      [] -> repo().rollback(:unauthorized)
      _ -> :ok
    end

    with {:ok, inventory} <- MemorySpaces.host_entitlements(host),
         {:ok, p} <- resolve_from(inventory, claim) do
      if MemorySpaces.partition_ready?(host, p, rebuilding_snapshot),
        do: p,
        else: repo().rollback(:partition_not_ready)
    else
      {:error, code} -> repo().rollback(code)
    end
  end

  defp resolve_from(inventory, claim) when is_map(claim) do
    scope = claim["scope"]
    namespace = claim["namespace"]
    id = claim["memory_space_id"]

    if not is_binary(scope) or String.trim(scope) == "" or not is_binary(namespace) or
         String.trim(namespace) == "" or (not is_nil(id) and Ecto.UUID.cast(id) == :error) do
      {:error, :invalid_request}
    else
      case Enum.filter(
             inventory,
             &(&1.scope == scope and &1.namespace == namespace and
                 (is_nil(id) or &1.memory_space_id == id))
           ) do
        [p] -> {:ok, p}
        [] -> {:error, :unauthorized}
        _ -> {:error, :ambiguous_partition}
      end
    end
  end

  defp resolve_from(_, _), do: {:error, :invalid_request}

  @doc false
  def lock_revision(p) do
    repo().insert_all(
      PartitionRevision,
      [
        Map.merge(p, %{
          current_revision: 0,
          first_available_revision: 1,
          updated_at: DateTime.utc_now()
        })
      ],
      on_conflict: :nothing
    )

    repo().one!(from(r in partition_query(PartitionRevision, p), lock: "FOR UPDATE"))
  end

  defp lock_cursor(host, p) do
    repo().insert_all(Cursor, [Map.merge(p, %{host_id: host, applied_revision: 0})],
      on_conflict: :nothing
    )

    repo().one!(from(c in host_query(Cursor, host, p), lock: "FOR UPDATE"))
  end

  defp delivery_live?(%Delivery{kind: "delta"}), do: true
  defp delivery_live?(d), do: snapshot_live?(repo().get(Snapshot, d.snapshot_id))
  defp snapshot_live?(nil), do: false

  defp snapshot_live?(s),
    do: s.status == "ready" and DateTime.compare(s.expires_at, DateTime.utc_now()) == :gt

  @doc false
  def partition_query(schema, p),
    do:
      from(r in schema,
        where:
          r.memory_space_id == ^p.memory_space_id and r.scope == ^p.scope and
            r.namespace == ^p.namespace
      )

  defp host_query(schema, host, p), do: where(partition_query(schema, p), [r], r.host_id == ^host)
  @doc false
  def wire_partition(p),
    do:
      Map.new(Map.take(p, [:memory_space_id, :scope, :namespace]), fn {k, v} ->
        {Atom.to_string(k), v}
      end)

  defp envelope(id, p, kind, from),
    do: %{
      "protocol" => "host_memory.v2",
      "status" => "batch",
      "batch_id" => id,
      "partition" => wire_partition(p),
      "kind" => kind,
      "from_revision" => from
    }

  defp bounded!(frame, limits) do
    items = frame["changes"] || frame["items"] || []

    if bytes(frame) > limits.max_frame_bytes or length(items) > limits.max_changes,
      do: repo().rollback(:payload_too_large),
      else: frame
  end

  @doc false
  def bytes(value), do: byte_size(Jason.encode!(value))
  @doc false
  def repo, do: Application.fetch_env!(:backplane_memory, :repo)
end

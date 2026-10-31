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
  alias Backplane.Memory.Authorization
  alias Backplane.MemorySpaces.{Entitlement, LegacyAlias, MemorySpace}

  @impl true
  def negotiate(%{kind: :host_agent} = auth, offer) do
    repo().transaction(fn ->
      lock_host_credential!(auth)

      if "memory_access.v1" in Map.get(offer, "extensions", []) do
        extended_inventory!(auth, offer)
      else
        case negotiate(auth.host_id, offer) do
          {:ok, response} -> response
          {:error, reason} -> repo().rollback(reason)
        end
      end
    end)
  end

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

      selected =
        cond do
          "host_memory.v2" in Map.get(offer, "offers", []) -> "host_memory.v2"
          "host_memory" in Map.get(offer, "offers", []) -> "host_memory"
          true -> "host_memory"
        end

      response = %{
        selected: selected,
        limits: limits,
        partitions: partitions,
        claims: claims
      }

      if bytes(response) <= limits.max_frame_bytes,
        do: {:ok, response},
        else: {:error, :payload_too_large}
    end
  end

  defp extended_inventory!(auth, offer) do
    {:ok, limits} = Backplane.Memory.EdgeSync.limits(offer)

    rows =
      repo().all(
        from e in Entitlement,
          join: s in MemorySpace,
          on: s.id == e.memory_space_id,
          where: e.host_id == ^auth.host_id and e.status == "active" and s.status == "active",
          order_by: e.id,
          limit: 1001
      )

    if length(rows) > 1000, do: repo().rollback(:payload_too_large)

    accesses =
      Enum.map(rows, fn row ->
        capabilities =
          for {cap, scope} <- [
                read: "host_agent.recall",
                deliver: "host_agent.recall",
                remember: "host_agent.import",
                forget: "host_agent.import"
              ],
              Atom.to_string(cap) in row.capabilities and scope in auth.scopes and
                (cap != :deliver or Backplane.Memory.Config.host_sync_enabled?()),
              do: cap

        capabilities = Enum.sort(capabilities)

        %{
          access_id: row.id,
          authority_version: row.authority_version,
          status: row.status,
          partition: Map.take(row, [:memory_space_id, :scope, :namespace]),
          capabilities: capabilities,
          offline_read_lease_seconds:
            if(:read in capabilities and :deliver in capabilities,
              do: row.offline_read_lease_seconds,
              else: 0
            )
        }
      end)

    partitions =
      for access <- accesses, :read in access.capabilities and :deliver in access.capabilities do
        p = access.partition
        revision = repo().one(partition_query(PartitionRevision, p))
        cursor = repo().one(host_query(Cursor, auth.host_id, p))

        status =
          cond do
            not MemorySpaces.partition_ready?(auth.host_id, p) ->
              "partition_not_ready"

            is_nil(cursor) or not binding_matches?(cursor, access) or
              is_nil(cursor.acknowledged_at) or
                not is_nil(cursor.active_snapshot_id) ->
              "snapshot_required"

            true ->
              "ready"
          end

        Map.merge(wire_partition(p), %{
          "access_id" => access.access_id,
          "authority_version" => access.authority_version,
          "current_revision" => if(revision, do: revision.current_revision, else: 0),
          "applied_revision" =>
            if(cursor && binding_matches?(cursor, access), do: cursor.applied_revision, else: 0),
          "status" => status
        })
      end

    private_space =
      repo().one(
        from a in LegacyAlias,
          where: a.alias_type == "host" and a.alias_value == ^("host:" <> auth.host_id),
          select: a.memory_space_id
      )

    default =
      Enum.find(
        rows,
        &(&1.default_capture and &1.memory_space_id == private_space and &1.namespace == "private")
      )

    extensions =
      Enum.filter(
        [
          "memory_access.v1",
          "memory_commands.v2",
          "memory_sources.v1",
          "hermes_capture.v1",
          "openclaw_source.v1",
          "openclaw_capture.v1"
        ],
        &(&1 in Map.get(offer, "extensions", []) and
            (&1 != "openclaw_capture.v1" or "host_agent.capture" in auth.scopes))
      )

    delivery_inventory =
      for access <- accesses,
          :read in access.capabilities and :deliver in access.capabilities,
          do: access.partition

    selected =
      cond do
        "host_memory.v2" in Map.get(offer, "offers", []) -> "host_memory.v2"
        "host_memory" in Map.get(offer, "offers", []) -> "host_memory"
        true -> "host_memory"
      end

    response = %{
      selected: selected,
      limits: limits,
      extensions: extensions,
      accesses: accesses,
      default_access_id: if(default, do: default.id),
      partitions: partitions,
      claims: Enum.map(offer["partitions"], &claim_status(auth.host_id, delivery_inventory, &1))
    }

    if bytes(response) > limits.max_frame_bytes, do: repo().rollback(:payload_too_large)
    response
  end

  defp lock_host_credential!(%{
         kind: :host_agent,
         host_id: host,
         auth_token_id: token,
         scopes: scopes
       })
       when is_list(scopes) do
    if Ecto.UUID.cast(host) == :error or Ecto.UUID.cast(token) == :error,
      do: repo().rollback(:unauthorized)

    if repo().query!("SELECT id FROM skill_hosts WHERE id=$1 FOR SHARE", [Ecto.UUID.dump!(host)]).num_rows !=
         1,
       do: repo().rollback(:unauthorized)

    assigned =
      repo().exists?(
        from a in Backplane.Skills.HostAgentToken,
          join: t in Backplane.Skills.HostAuthToken,
          on: t.id == a.auth_token_id,
          where: a.host_id == ^host and t.id == ^token
      )

    if not assigned, do: repo().rollback(:unauthorized)
    :ok
  end

  defp lock_host_credential!(_), do: repo().rollback(:unauthorized)

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
  def next(subject, request, limits) do
    result =
      delivery_transaction(subject, request, fn host, p, binding ->
        revision = lock_revision(p)
        cursor = lock_cursor(host, p, binding)

        if (binding.extended? and request["snapshot_id"]) &&
             request["snapshot_id"] != cursor.active_snapshot_id,
           do: repo().rollback(:authority_changed)

        outstanding =
          repo().one(from(d in host_query(Delivery, host, p), where: d.status == "issued"))

        cond do
          outstanding && binding_matches?(outstanding, binding) && delivery_live?(outstanding) ->
            bounded!(outstanding.payload, limits)

          true ->
            if outstanding,
              do:
                repo().update_all(where(Delivery, id: ^outstanding.id), set: [status: "expired"])

            issue_next(host, p, revision, cursor, request, limits, binding)
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

  defp issue_next(host, p, revision, cursor, request, limits, binding) do
    snapshot = if cursor.active_snapshot_id, do: repo().get(Snapshot, cursor.active_snapshot_id)

    cond do
      snapshot && snapshot_live?(snapshot) && continuation?(cursor, request) ->
        issue_chunk(host, p, cursor, snapshot, limits, binding)

      snapshot || request["applied_revision"] != cursor.applied_revision ||
          is_nil(cursor.acknowledged_at) ->
        start_snapshot(host, p, cursor, limits, binding)

      cursor.applied_revision > revision.current_revision ->
        start_snapshot(host, p, cursor, limits, binding)

      cursor.applied_revision == revision.current_revision ->
        %{
          "protocol" => "host_memory.v2",
          "status" => "current",
          "partition" => wire_partition(p),
          "applied_revision" => cursor.applied_revision
        }
        |> bind_frame(binding)
        |> bounded!(limits)

      cursor.applied_revision + 1 < revision.first_available_revision ->
        start_snapshot(host, p, cursor, limits, binding)

      true ->
        issue_delta(host, p, cursor, revision, limits, binding)
    end
  end

  defp continuation?(cursor, request) do
    request["snapshot_id"] == cursor.active_snapshot_id and
      request["next_chunk_index"] == cursor.snapshot_next_chunk_index
  end

  defp issue_delta(host, p, cursor, revision, limits, binding) do
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
      start_snapshot(host, p, cursor, limits, binding)
    else
      id = Ecto.UUID.generate()
      base = envelope(id, p, "delta", cursor.applied_revision + 1) |> bind_frame(binding)

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

      persist(host, p, frame, binding)
    end
  end

  defp start_snapshot(host, p, cursor, limits, binding) do
    overhead = if binding.extended?, do: bytes(%{"access" => wire_access(binding)}), else: 0
    snapshot_limits = %{limits | max_frame_bytes: limits.max_frame_bytes - overhead}
    if snapshot_limits.max_frame_bytes <= 0, do: repo().rollback(:payload_too_large)
    snapshot = SnapshotBuilder.build_locked(p, snapshot_limits)

    repo().update_all(host_query(Cursor, host, p),
      set: [active_snapshot_id: snapshot.id, snapshot_next_chunk_index: 0]
    )

    issue_chunk(
      host,
      p,
      %{cursor | active_snapshot_id: snapshot.id, snapshot_next_chunk_index: 0},
      snapshot,
      limits,
      binding
    )
  end

  defp issue_chunk(host, p, cursor, snapshot, limits, binding) do
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
      |> bind_frame(binding)

    bounded!(frame, limits)
    persist(host, p, frame, binding)
  end

  defp persist(host, p, frame, binding) do
    repo().insert!(
      struct(
        Delivery,
        Map.merge(p, %{
          id: frame["batch_id"],
          host_id: host,
          access_id: binding.access_id,
          authority_version: binding.authority_version,
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
  def ack(subject, request) do
    delivery_transaction(subject, request, fn host, p, binding ->
      delivery = repo().get(Delivery, request["batch_id"])
      if is_nil(delivery) or delivery.host_id != host, do: repo().rollback(:batch_not_found)

      if Map.take(delivery, [:memory_space_id, :scope, :namespace]) != p,
        do: repo().rollback(:batch_conflict)

      if not binding_matches?(delivery, binding), do: repo().rollback(:invalid_ack)

      lock_revision(p)
      cursor = lock_cursor(host, p, binding)
      delivery = repo().get!(Delivery, delivery.id)
      expected = expected_ack(delivery, cursor)
      if Enum.any?(expected, fn {k, v} -> request[k] !== v end), do: repo().rollback(:invalid_ack)

      result =
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

      if binding.extended? do
        Map.merge(result, %{
          access: request["access"],
          partition: wire_partition(p),
          batch_id: delivery.id,
          snapshot_id: request["snapshot_id"],
          chunk_hash: request["chunk_hash"],
          integrity_hash: request["integrity_hash"]
        })
      else
        result
      end
    end)
  end

  defp delivery_transaction(%{kind: :host_agent} = auth, request, fun) do
    with {:ok, selector, version, extended?} <- request_access(auth.host_id, request),
         {:ok, actor, access} <- Authorization.authorize_access(auth, selector, :deliver),
         true <- is_nil(version) or version == access.authority_version,
         true <- partition_matches?(request["partition"], access.partition, extended?) do
      MemorySpaces.with_host_access(
        actor,
        selector,
        :deliver,
        access.authority_version,
        fn current ->
          if not MemorySpaces.partition_ready?(auth.host_id, current.partition),
            do: repo().rollback(:partition_not_ready)

          binding = %{
            access_id: current.access_id,
            authority_version: current.authority_version,
            extended?: extended?
          }

          {:ok, fun.(auth.host_id, current.partition, binding)}
        end
      )
    else
      false ->
        case request["access"] do
          %{"authority_version" => version} ->
            case MemorySpaces.resolve_host_access(
                   auth.host_id,
                   {:access_id, request["access"]["access_id"]},
                   :deliver
                 ) do
              {:ok, access} when access.authority_version != version ->
                {:error, :authority_changed}

              _ ->
                {:error, :partition_mismatch}
            end

          _ ->
            {:error, :partition_mismatch}
        end

      {:error, _} = error ->
        error
    end
  end

  defp delivery_transaction(host, request, fun) do
    if Map.has_key?(request, "access") do
      {:error, :unsupported_protocol}
    else
      repo().transaction(fn ->
        p = authorize!(host, request["partition"])
        binding = legacy_binding!(host, p)
        fun.(host, p, binding)
      end)
    end
  end

  defp request_access(host, request) do
    case Map.fetch(request, "access") do
      {:ok, %{"access_id" => id, "authority_version" => version} = access}
      when map_size(access) == 2 and is_integer(version) and version > 0 ->
        case Ecto.UUID.cast(id) do
          {:ok, ^id} -> {:ok, {:access_id, id}, version, true}
          _ -> {:error, :invalid_request}
        end

      :error ->
        with {:ok, inventory} <- MemorySpaces.host_entitlements(host),
             {:ok, p} <- resolve_from(inventory, request["partition"]) do
          case repo().one(
                 from e in Entitlement,
                   where:
                     e.host_id == ^host and
                       e.memory_space_id == ^p.memory_space_id and e.scope == ^p.scope and
                       e.namespace == ^p.namespace,
                   select: e.id
               ) do
            nil -> {:error, :unauthorized}
            id -> {:ok, {:access_id, id}, nil, false}
          end
        end

      _ ->
        {:error, :invalid_request}
    end
  end

  defp partition_matches?(claim, partition, true), do: claim == wire_partition(partition)

  defp partition_matches?(claim, partition, false),
    do: resolve_from([partition], claim) == {:ok, partition}

  defp legacy_binding!(host, p) do
    row =
      repo().one!(
        from e in Entitlement,
          where:
            e.host_id == ^host and
              e.memory_space_id == ^p.memory_space_id and e.scope == ^p.scope and
              e.namespace == ^p.namespace,
          lock: "FOR SHARE"
      )

    %{access_id: row.id, authority_version: row.authority_version, extended?: false}
  end

  defp wire_access(binding),
    do: %{"access_id" => binding.access_id, "authority_version" => binding.authority_version}

  defp bind_frame(frame, %{extended?: true} = binding),
    do: Map.put(frame, "access", wire_access(binding))

  defp bind_frame(frame, _binding), do: frame

  defp binding_matches?(row, binding),
    do: row.access_id == binding.access_id and row.authority_version == binding.authority_version

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

  defp lock_cursor(host, p, binding) do
    repo().insert_all(
      Cursor,
      [
        Map.merge(p, %{
          host_id: host,
          applied_revision: 0,
          access_id: binding.access_id,
          authority_version: binding.authority_version
        })
      ],
      on_conflict: :nothing
    )

    cursor = repo().one!(from(c in host_query(Cursor, host, p), lock: "FOR UPDATE"))

    if binding_matches?(cursor, binding) do
      cursor
    else
      repo().update_all(
        from(d in host_query(Delivery, host, p), where: d.status in ["issued", "progress"]),
        set: [status: "expired"]
      )

      cursor
      |> Ecto.Changeset.change(
        access_id: binding.access_id,
        authority_version: binding.authority_version,
        applied_revision: 0,
        active_snapshot_id: nil,
        snapshot_next_chunk_index: nil,
        last_acknowledged_batch_id: nil,
        acknowledged_at: nil
      )
      |> repo().update!()
    end
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

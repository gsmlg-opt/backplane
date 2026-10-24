defmodule Backplane.Memory.Sources do
  @moduledoc "Atomic external source heads, immutable mutations and fenced complete snapshots."

  import Ecto.Query
  alias Backplane.Memory.{Memories, PartitionIdentity}
  alias Backplane.Memory.Sources.{Source, Entry, Mutation, Reconciliation, Page}
  alias Backplane.MemorySourceContract, as: Contract

  def mutate(args, authority) do
    with {:ok, args} <- Contract.validate("source_mutate", args),
         {:ok, partition} <- PartitionIdentity.validate_generator(authority) do
      transaction(fn ->
        partition =
          Map.put(partition, :agent_id, authority[:agent_id] || "host:" <> partition.host_id)

        lock_partition(partition)
        source = locked_source(args["source"], partition)
        apply_mutation(source, args, partition)
      end)
    end
  end

  def reconcile(args, authority) do
    with {:ok, args} <- Contract.validate("source_reconcile", args),
         {:ok, partition} <- PartitionIdentity.validate_generator(authority) do
      transaction(fn ->
        partition =
          Map.put(partition, :agent_id, authority[:agent_id] || "host:" <> partition.host_id)

        lock_partition(partition)
        source = locked_source(args["source"], partition)
        reconcile_phase(source, args, partition)
      end)
    end
  end

  def status(args, authority) do
    with {:ok, args} <- Contract.validate("source_status", args),
         {:ok, partition} <- PartitionIdentity.validate_generator(authority),
         source when not is_nil(source) <- repo().one(source_query(args["source"], partition)),
         %Mutation{} = mutation <- repo().get(Mutation, args["event_id"]),
         true <- mutation.source_id == source.id do
      {:ok, receipt(mutation)}
    else
      {:error, _} = error -> error
      _ -> {:error, :not_found}
    end
  end

  @doc false
  def suppress_memory!(memory_id) do
    repo().update_all(from(e in Entry, where: e.memory_id == ^memory_id),
      set: [suppressed: true, active: false, updated_at: DateTime.utc_now()]
    )

    :ok
  end

  defp apply_mutation(source, args, partition) do
    digest = Contract.digest(%{"arguments" => args, "authority" => stringify(partition)})

    case repo().get(Mutation, args["event_id"]) do
      %Mutation{payload_digest: ^digest} = saved -> receipt(saved)
      %Mutation{} -> repo().rollback(:idempotency_conflict)
      nil -> new_mutation(source, args, partition, digest)
    end
  end

  defp new_mutation(source, args, partition, digest) do
    entry =
      repo().one(
        from(e in Entry,
          where: e.source_id == ^source.id and e.entry_id == ^args["entry_id"],
          lock: "FOR UPDATE"
        )
      )

    revision = args["revision"]
    if entry && entry.revision == revision, do: repo().rollback(:revision_conflict)
    {:ok, occurred_at, _} = DateTime.from_iso8601(args["occurred_at"])
    occurred_at = %{occurred_at | microsecond: {elem(occurred_at.microsecond, 0), 6}}

    mutation =
      repo().insert!(%Mutation{
        id: args["event_id"],
        source_id: source.id,
        entry_id: args["entry_id"],
        revision: revision,
        operation: args["operation"],
        payload_digest: digest,
        provenance: args["provenance"],
        occurred_at: occurred_at,
        outcome: "processing"
      })

    {outcome, memory_id} =
      cond do
        revision <= source.revision_floor or (entry && entry.revision > revision) ->
          {"stale", entry && entry.memory_id}

        entry && entry.suppressed ->
          save_entry(source, entry, mutation, entry.memory_id, false, true)
          {"suppressed", entry.memory_id}

        args["operation"] == "withdraw" ->
          save_entry(source, entry, mutation, entry && entry.memory_id, false, false)
          {"applied", entry && entry.memory_id}

        true ->
          memory = remember_source!(mutation, args, partition)
          suppressed = not is_nil(memory.deleted_at)
          save_entry(source, entry, mutation, memory.id, not suppressed, suppressed)
          {if(suppressed, do: "suppressed", else: "applied"), memory.id}
      end

    Backplane.Memory.SourceSupport.refresh!(partition)
    edge_revision = if memory_id, do: edge_revision(partition, memory_id)

    mutation =
      mutation
      |> Ecto.Changeset.change(
        outcome: outcome,
        memory_id: memory_id,
        edge_revision: edge_revision
      )
      |> repo().update!()

    receipt(mutation)
  end

  defp remember_source!(mutation, args, partition) do
    provenance = args["provenance"]

    opts =
      Map.to_list(partition) ++
        [
          type: args["type"],
          agent_id: partition[:agent_id] || "host:" <> partition.host_id,
          session_id: provenance["session_id"],
          request_origin: "external_source",
          metadata:
            Map.take(provenance, ~w(repository_sources cwd)) |> Map.put("source", "hermes.native"),
          idempotency_scope: "memory-source.v1:" <> mutation.source_id,
          idempotency_key: mutation.id,
          evidence: [
            %{
              source_mutation_id: mutation.id,
              session_id: provenance["session_id"],
              evidence_kind: "supports",
              support_score: 1.0,
              excerpt: args["content"]
            }
          ]
        ]

    case Memories.remember(args["content"], opts) do
      {:ok, memory} -> memory
      {:error, reason} -> repo().rollback(reason)
    end
  end

  defp save_entry(source, entry, mutation, memory_id, active, suppressed) do
    (entry || %Entry{source_id: source.id, entry_id: mutation.entry_id})
    |> Ecto.Changeset.change(
      revision: mutation.revision,
      mutation_id: mutation.id,
      memory_id: memory_id,
      active: active,
      suppressed: suppressed
    )
    |> repo().insert_or_update!()
  end

  defp reconcile_phase(source, %{"phase" => "begin"} = args, _partition) do
    attrs = %{
      id: args["reconciliation_id"],
      source_id: source.id,
      revision: args["revision"],
      page_count: args["page_count"],
      entry_count: args["entry_count"],
      snapshot_hash: args["snapshot_hash"]
    }

    existing = repo().get(Reconciliation, attrs.id)

    snapshot =
      case existing do
        nil ->
          count =
            repo().aggregate(
              from(r in Reconciliation,
                where: r.source_id == ^source.id and r.status == "staging"
              ),
              :count
            )

          if count >= 16, do: repo().rollback(:reconciliation_capacity)
          repo().insert!(struct!(Reconciliation, attrs))

        row ->
          if Map.take(Map.from_struct(row), Map.keys(attrs)) != attrs,
            do: repo().rollback(:idempotency_conflict)

          row
      end

    reconciliation_receipt(snapshot, args)
  end

  defp reconcile_phase(source, args, partition) do
    snapshot =
      repo().one(
        from(r in Reconciliation,
          where: r.id == ^args["reconciliation_id"] and r.source_id == ^source.id,
          lock: "FOR UPDATE"
        )
      )

    if is_nil(snapshot), do: repo().rollback(:not_found)

    case args["phase"] do
      "page" ->
        if snapshot.status != "staging", do: repo().rollback(:reconciliation_closed)
        if args["page_index"] >= snapshot.page_count, do: repo().rollback(:invalid_arguments)

        attrs = %{
          reconciliation_id: snapshot.id,
          page_index: args["page_index"],
          page_hash: args["page_hash"],
          entries: args["entries"]
        }

        case repo().one(
               from(p in Page,
                 where: p.reconciliation_id == ^snapshot.id and p.page_index == ^attrs.page_index
               )
             ) do
          nil ->
            repo().insert!(struct!(Page, attrs))

          page ->
            if page.page_hash != attrs.page_hash or page.entries != attrs.entries,
              do: repo().rollback(:idempotency_conflict)
        end

        reconciliation_receipt(snapshot, args)

      "abort" ->
        if snapshot.status == "committed", do: repo().rollback(:reconciliation_closed)
        snapshot = snapshot |> Ecto.Changeset.change(status: "aborted") |> repo().update!()
        reconciliation_receipt(snapshot, args)

      "commit" ->
        if snapshot.status == "aborted", do: repo().rollback(:reconciliation_closed)

        if snapshot.status == "committed" do
          reconciliation_receipt(snapshot, args)
        else
          commit_snapshot(source, snapshot, args, partition)
        end
    end
  end

  defp commit_snapshot(source, snapshot, args, partition) do
    pages =
      repo().all(
        from(p in Page, where: p.reconciliation_id == ^snapshot.id, order_by: p.page_index)
      )

    entries = Enum.flat_map(pages, & &1.entries)
    {:ok, encoded} = Contract.encode(entries)

    unless length(pages) == snapshot.page_count and length(entries) == snapshot.entry_count and
             Enum.map(pages, & &1.page_index) == indexes(snapshot.page_count) and
             length(Enum.uniq_by(entries, & &1["entry_id"])) == length(entries) and
             Contract.digest(entries) == snapshot.snapshot_hash and
             byte_size(encoded) <= Contract.limits().snapshot_bytes do
      repo().rollback(:incomplete_snapshot)
    end

    heads =
      repo().all(
        from(e in Entry,
          where: e.source_id == ^source.id,
          order_by: e.entry_id,
          lock: "FOR UPDATE"
        )
      )

    by_id = Map.new(heads, &{&1.entry_id, &1})
    # Only a committed, complete snapshot is authority for absence. Newer heads
    # survive this fence, including those written while pages were in flight.
    Enum.each(entries, fn incoming ->
      head = by_id[incoming["entry_id"]]

      memory =
        if head && head.memory_id,
          do: repo().get(Backplane.Memory.Memories.Memory, head.memory_id)

      unchanged = head && head.active && memory && memory.content == incoming["content"]

      unless snapshot.revision <= source.revision_floor or
               (head && head.revision > snapshot.revision) or unchanged do
        event_id = derived_uuid(snapshot.id <> ":upsert:" <> incoming["entry_id"])

        mutation =
          Map.merge(incoming, %{
            "protocol" => Contract.protocol(),
            "source" => source_identity(source),
            "event_id" => event_id,
            "revision" => snapshot.revision,
            "operation" => "upsert",
            "occurred_at" => DateTime.to_iso8601(snapshot.inserted_at)
          })

        apply_mutation(source, mutation, partition)
      end
    end)

    present = MapSet.new(Enum.map(entries, & &1["entry_id"]))

    Enum.each(heads, fn head ->
      if head.active and head.revision <= snapshot.revision and
           not MapSet.member?(present, head.entry_id) do
        mutation = %{
          "protocol" => Contract.protocol(),
          "source" => source_identity(source),
          "event_id" => derived_uuid(snapshot.id <> ":withdraw:" <> head.entry_id),
          "entry_id" => head.entry_id,
          "revision" => snapshot.revision,
          "operation" => "withdraw",
          "type" => "semantic",
          "provenance" => %{},
          "occurred_at" => DateTime.to_iso8601(snapshot.inserted_at)
        }

        apply_mutation(source, mutation, partition)
      end
    end)

    source
    |> Ecto.Changeset.change(revision_floor: max(source.revision_floor, snapshot.revision))
    |> repo().update!()

    snapshot =
      snapshot
      |> Ecto.Changeset.change(
        status: "committed",
        result: %{"entry_count" => length(entries), "source_revision" => snapshot.revision}
      )
      |> repo().update!()

    Backplane.Memory.SourceSupport.refresh!(partition)
    reconciliation_receipt(snapshot, args)
  end

  defp indexes(0), do: []
  defp indexes(count), do: Enum.to_list(0..(count - 1))

  defp locked_source(identity, partition) do
    case repo().one(source_query(identity, partition) |> lock("FOR UPDATE")) do
      nil ->
        repo().insert!(
          struct!(
            Source,
            Map.merge(
              Map.take(partition, [:memory_space_id, :host_id, :scope, :namespace]),
              %{
                integration: identity["integration"],
                installation_id: identity["installation_id"],
                profile_id: identity["profile_id"],
                target: identity["target"]
              }
            )
          )
        )

      source ->
        source
    end
  end

  defp source_query(identity, partition),
    do:
      from(s in Source,
        where:
          s.memory_space_id == ^partition.memory_space_id and s.host_id == ^partition.host_id and
            s.scope == ^partition.scope and s.namespace == ^partition.namespace and
            s.integration == ^identity["integration"] and
            s.installation_id == ^identity["installation_id"] and
            s.profile_id == ^identity["profile_id"] and s.target == ^identity["target"]
      )

  defp source_identity(source),
    do: %{
      "integration" => source.integration,
      "installation_id" => source.installation_id,
      "profile_id" => source.profile_id,
      "target" => source.target
    }

  defp lock_partition(partition) do
    <<key::signed-64, _::binary>> =
      :crypto.hash(
        :sha256,
        Enum.join(
          ["memory-sources", partition.memory_space_id, partition.scope, partition.namespace],
          ":"
        )
      )

    repo().query!("SELECT pg_advisory_xact_lock($1::bigint)", [key])
  end

  defp edge_revision(partition, id),
    do:
      repo().one(
        from(c in Backplane.Memory.EdgeSync.Change,
          where:
            c.memory_space_id == ^partition.memory_space_id and c.scope == ^partition.scope and
              c.namespace == ^partition.namespace and c.memory_id == ^id,
          select: max(c.revision)
        )
      )

  defp receipt(mutation),
    do: %{
      protocol: Contract.protocol(),
      event_id: mutation.id,
      command_id: mutation.id,
      status: "committed",
      outcome: mutation.outcome,
      canonical_id: mutation.memory_id,
      revision: mutation.edge_revision,
      source_revision: mutation.revision,
      authority: "canonical",
      consistency: "canonical"
    }

  defp reconciliation_receipt(snapshot, args),
    do: %{
      protocol: Contract.protocol(),
      event_id: args["event_id"],
      command_id: args["event_id"],
      reconciliation_id: snapshot.id,
      phase: args["phase"],
      status: "committed",
      outcome: if(snapshot.status == "committed", do: "applied", else: "unchanged"),
      reconciliation_status: snapshot.status,
      source_revision: snapshot.revision,
      authority: "canonical",
      consistency: "canonical"
    }

  defp derived_uuid(value) do
    <<a::32, b::16, _::4, c::12, _::2, d::62, _::binary>> = :crypto.hash(:sha256, value)
    Ecto.UUID.load!(<<a::32, b::16, 5::4, c::12, 2::2, d::62>>)
  end

  defp stringify(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
  defp transaction(fun), do: repo().transaction(fun)
  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)
end

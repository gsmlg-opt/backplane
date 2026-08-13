defmodule Backplane.Memory.Audit do
  @moduledoc "Append-only audit log for memory governance operations."

  import Ecto.Query

  @contract_operations ~w(
    activity.repair
    memory.activity.purge
    coordination.action.create
    coordination.action.status
    coordination.heal
    coordination.lease.acquire
    coordination.lease.cleanup
    coordination.signal.read
    coordination.signal.send
    crystal.crystallize
    forget
    governance_delete
    hard_delete
    memory.archive
    memory.apply
    lesson.candidate
    lesson.save
    lesson.strengthen
    lesson.transition
    memory.recall_trace.purge
    memory_relation.candidate
    memory_relation.policy
    memory_relation.resolve
    projection.repair
    projection.rebuild
    remember
    memory.export
    memory.activity.summary
    memory.config.set
    memory.replay.import_dispatched
    memory.replay.load
    memory.replay.sessions
    memory.gate.set
    memory.import.completed
    memory.import.failed
    memory.import.started
    memory.repair
    session.abandoned
    session.lifecycle_transition
    session.summary_enqueued
  )

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)

  @doc "Enumerates the lifecycle, repair, and coordination operations audited by M14."
  def contract_operations, do: Enum.sort(@contract_operations)

  @doc "Append an audit entry."
  def log(operation, actor, target_ids, metadata \\ %{}) when is_binary(operation) do
    repo().insert_all("memory_audit_log", [
      %{
        id: Ecto.UUID.dump!(Ecto.UUID.generate()),
        operation: operation,
        actor: actor || "system",
        target_ids: target_ids,
        metadata: scrub_sensitive(metadata),
        created_at: DateTime.utc_now()
      }
    ])

    :ok
  end

  @doc "Append an audit entry once for an operation and stable idempotency key."
  def log_once(operation, actor, target_ids, idempotency_key, metadata \\ %{})
      when is_binary(operation) and is_binary(idempotency_key) do
    lock_key = operation <> ":" <> idempotency_key
    repo().query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [lock_key])

    exists? =
      repo().exists?(
        from(r in "memory_audit_log",
          where: r.operation == ^operation,
          where: fragment("?->>'idempotency_key' = ?", r.metadata, ^idempotency_key)
        )
      )

    unless exists? do
      log(operation, actor, target_ids, Map.put(metadata, :idempotency_key, idempotency_key))
    end

    :ok
  end

  @doc "List audit entries, newest first. Accepts :limit, :offset, :operation, :actor filters."
  def list(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)

    q =
      from(r in "memory_audit_log",
        order_by: [desc: r.created_at],
        limit: ^limit,
        offset: ^offset,
        select: %{
          id: r.id,
          operation: r.operation,
          actor: r.actor,
          target_ids: r.target_ids,
          metadata: r.metadata,
          created_at: r.created_at
        }
      )

    q = if op = opts[:operation], do: where(q, [r], r.operation == ^op), else: q
    q = if actor = opts[:actor], do: where(q, [r], r.actor == ^actor), else: q

    repo().all(q)
  end

  @doc "List audit entries owned by an exact memory partition before pagination."
  def list(%{host_id: host_id, client_id: client_id, scope: scope, namespace: namespace}, opts)
      when is_list(opts) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)

    q =
      from(r in "memory_audit_log",
        where:
          (fragment("?->>'host_id'", r.metadata) == ^host_id and
             fragment("?->>'client_id'", r.metadata) == ^client_id and
             fragment("?->>'scope'", r.metadata) == ^scope and
             fragment("?->>'namespace'", r.metadata) == ^namespace) or
            fragment(
              """
              EXISTS (
                SELECT 1 FROM bpm_memories m
                WHERE m.host_id = ? AND m.client_id = ? AND m.scope = ? AND m.namespace = ?
                  AND CASE jsonb_typeof(?)
                    WHEN 'array' THEN ? @> jsonb_build_array(m.id::text)
                    WHEN 'object' THEN EXISTS (
                      SELECT 1 FROM jsonb_each_text(?) AS target(key, value)
                      WHERE target.value = m.id::text
                    )
                    ELSE false
                  END
              )
              """,
              ^host_id,
              ^client_id,
              ^scope,
              ^namespace,
              r.target_ids,
              r.target_ids,
              r.target_ids
            ),
        order_by: [desc: r.created_at, desc: r.id],
        limit: ^limit,
        offset: ^offset,
        select: %{
          id: r.id,
          operation: r.operation,
          actor: r.actor,
          target_ids: r.target_ids,
          metadata: r.metadata,
          created_at: r.created_at
        }
      )

    q = if op = opts[:operation], do: where(q, [r], r.operation == ^op), else: q
    q = if actor = opts[:actor], do: where(q, [r], r.actor == ^actor), else: q
    repo().all(q)
  end

  @doc "List every audit entry whose legacy array or map target_ids contains the target."
  @spec list_for_target(String.t()) :: [map()]
  def list_for_target(target_id) when is_binary(target_id) do
    repo().all(
      from(r in "memory_audit_log",
        where:
          fragment(
            """
            CASE jsonb_typeof(?)
              WHEN 'array' THEN ? @> jsonb_build_array(?::text)
              WHEN 'object' THEN EXISTS (
                SELECT 1 FROM jsonb_each_text(?) AS target(key, value)
                WHERE target.value = ?
              )
              ELSE false
            END
            """,
            r.target_ids,
            r.target_ids,
            ^target_id,
            r.target_ids,
            ^target_id
          ),
        order_by: [desc: r.created_at],
        select: %{
          id: r.id,
          operation: r.operation,
          actor: r.actor,
          target_ids: r.target_ids,
          metadata: r.metadata,
          created_at: r.created_at
        }
      )
    )
  end

  defp scrub_sensitive(%module{} = value) when is_atom(module), do: value

  defp scrub_sensitive(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {key, scrub_sensitive(nested)} end)
    |> Map.drop([:content, "content", :raw, "raw"])
  end

  defp scrub_sensitive(value) when is_list(value), do: Enum.map(value, &scrub_sensitive/1)
  defp scrub_sensitive(value), do: value
end

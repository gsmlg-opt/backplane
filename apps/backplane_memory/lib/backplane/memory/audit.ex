defmodule Backplane.Memory.Audit do
  @moduledoc "Append-only audit log for memory governance operations."

  import Ecto.Query

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)

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

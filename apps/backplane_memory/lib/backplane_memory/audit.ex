defmodule BackplaneMemory.Audit do
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
        metadata: metadata,
        created_at: DateTime.utc_now()
      }
    ])

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
end

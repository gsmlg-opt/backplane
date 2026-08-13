defmodule Backplane.Memory.Coordination.Lease do
  @moduledoc "Exclusive lease on an action_id for distributed coordination."

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Backplane.Memory.Audit

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts false

  schema "memory_leases" do
    field(:host_id, :string)
    field(:client_id, :string)
    field(:scope, :string)
    field(:namespace, :string)
    field(:action_id, :binary_id)
    field(:holder_agent_id, :string)
    field(:acquired_at, :utc_datetime_usec)
    field(:expires_at, :utc_datetime_usec)
    field(:renewed_at, :utc_datetime_usec)
  end

  def changeset(lease, attrs) do
    lease
    |> cast(attrs, [
      :host_id,
      :client_id,
      :scope,
      :namespace,
      :action_id,
      :holder_agent_id,
      :acquired_at,
      :expires_at
    ])
    |> validate_required([:action_id, :holder_agent_id, :expires_at])
  end

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)

  @doc """
  Acquire an exclusive lease for action_id.
  Returns {:ok, lease_id} or {:error, %{held_by: agent_id, expires_at: dt}}.
  """
  def acquire(action_id, agent_id, ttl_seconds \\ 300),
    do: acquire(action_id, agent_id, ttl_seconds, nil)

  def acquire(action_id, agent_id, ttl_seconds, partition) do
    now = DateTime.utc_now()
    expires_at = DateTime.add(now, ttl_seconds, :second)

    action_owned =
      repo().exists?(
        from(a in Backplane.Memory.Coordination.Action,
          where: a.id == ^action_id,
          where: ^partition_dynamic(partition)
        )
      )

    if not action_owned do
      {:error, :not_found}
    else
      {:ok, result} =
        repo().transaction(fn ->
          expired_query =
            from(l in __MODULE__,
              where: l.action_id == ^action_id and l.expires_at < ^now,
              where: ^partition_dynamic(partition),
              order_by: [asc: l.expires_at, asc: l.id],
              limit: 100,
              lock: "FOR UPDATE SKIP LOCKED"
            )

          expired_ids = repo().all(from(l in expired_query, select: l.id))

          {deleted_count, deleted_ids} =
            if expired_ids == [],
              do: {0, []},
              else:
                repo().delete_all(
                  from(l in __MODULE__, where: l.id in ^expired_ids, select: l.id)
                )

          if deleted_count > 0 do
            Audit.log("coordination.lease.cleanup", "system", deleted_ids, %{
              action_id: action_id,
              result: "expired",
              count: deleted_count
            })
          end

          new_id = Ecto.UUID.generate()

          {count, _} =
            repo().insert_all(
              __MODULE__,
              [
                %{
                  id: new_id,
                  action_id: action_id,
                  holder_agent_id: agent_id,
                  acquired_at: now,
                  expires_at: expires_at
                }
                |> Map.merge(partition_attrs(partition))
              ],
              on_conflict: :nothing
            )

          if count == 1 do
            Audit.log("coordination.lease.acquire", agent_id, [new_id], %{
              action_id: action_id,
              expires_at: expires_at,
              host_id: partition_value(partition, :host_id),
              client_id: partition_value(partition, :client_id),
              scope: partition_value(partition, :scope),
              namespace: partition_value(partition, :namespace),
              result: "acquired"
            })

            {:ok, new_id}
          else
            fetch_holder(action_id, now, partition)
          end
        end)

      result
    end
  end

  defp fetch_holder(action_id, now, partition) do
    case repo().one(
           from(l in __MODULE__,
             where: l.action_id == ^action_id and l.expires_at >= ^now,
             where: ^partition_dynamic(partition)
           )
         ) do
      nil -> {:error, :not_found}
      held -> {:error, %{held_by: held.holder_agent_id, expires_at: held.expires_at}}
    end
  end

  defp partition_dynamic(partition) when is_map(partition),
    do:
      dynamic(
        [row],
        row.host_id == ^Map.fetch!(partition, :host_id) and
          row.client_id == ^Map.fetch!(partition, :client_id) and
          row.scope == ^Map.fetch!(partition, :scope) and
          row.namespace == ^Map.fetch!(partition, :namespace)
      )

  defp partition_dynamic(nil),
    do:
      dynamic(
        [row],
        is_nil(row.host_id) and is_nil(row.client_id) and is_nil(row.scope) and
          is_nil(row.namespace)
      )

  defp partition_attrs(partition) when is_map(partition),
    do: Map.take(partition, [:host_id, :client_id, :scope, :namespace])

  defp partition_attrs(nil), do: %{}

  defp partition_value(partition, key) when is_map(partition), do: Map.get(partition, key)
  defp partition_value(nil, _key), do: nil
end

defmodule BackplaneMemory.Coordination.Lease do
  @moduledoc "Exclusive lease on an action_id for distributed coordination."

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts false

  schema "memory_leases" do
    field(:action_id, :binary_id)
    field(:holder_agent_id, :string)
    field(:acquired_at, :utc_datetime_usec)
    field(:expires_at, :utc_datetime_usec)
    field(:renewed_at, :utc_datetime_usec)
  end

  def changeset(lease, attrs) do
    lease
    |> cast(attrs, [:action_id, :holder_agent_id, :acquired_at, :expires_at])
    |> validate_required([:action_id, :holder_agent_id, :expires_at])
  end

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)

  @doc """
  Acquire an exclusive lease for action_id.
  Returns {:ok, lease_id} or {:error, %{held_by: agent_id, expires_at: dt}}.
  """
  def acquire(action_id, agent_id, ttl_seconds \\ 300) do
    now = DateTime.utc_now()
    expires_at = DateTime.add(now, ttl_seconds, :second)

    repo().delete_all(
      from(l in __MODULE__, where: l.action_id == ^action_id and l.expires_at < ^now)
    )

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
        ],
        on_conflict: :nothing
      )

    if count == 1 do
      {:ok, new_id}
    else
      fetch_holder(action_id, now)
    end
  end

  defp fetch_holder(action_id, now) do
    case repo().one(
           from(l in __MODULE__,
             where: l.action_id == ^action_id and l.expires_at >= ^now
           )
         ) do
      nil -> {:error, :not_found}
      held -> {:error, %{held_by: held.holder_agent_id, expires_at: held.expires_at}}
    end
  end
end

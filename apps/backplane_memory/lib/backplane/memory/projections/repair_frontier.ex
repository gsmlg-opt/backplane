defmodule Backplane.Memory.Projections.RepairFrontier do
  @moduledoc "Durable monotonic scheduling frontier for a captured session projection."

  use Ecto.Schema

  import Ecto.Query

  @primary_key false
  schema "bpm_projection_repair_frontiers" do
    field :host_id, :string, primary_key: true
    field :session_id, :string, primary_key: true
    field :requested_generation, :integer
    field :requested_revision, :string
    field :inflight_generation, :integer
    field :inflight_revision, :string
    field :completed_generation, :integer
    field :completed_revision, :string
    timestamps(type: :utc_datetime_usec)
  end

  def advance(repo, host_id, session_id, revision) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {1, [frontier]} =
      repo.insert_all(
        __MODULE__,
        [
          %{
            host_id: host_id,
            session_id: session_id,
            requested_generation: 1,
            requested_revision: revision,
            inflight_generation: 0,
            completed_generation: 0,
            inserted_at: now,
            updated_at: now
          }
        ],
        conflict_target: [:host_id, :session_id],
        on_conflict:
          from(frontier in __MODULE__,
            update: [
              set: [
                requested_generation: fragment("? + 1", frontier.requested_generation),
                requested_revision: ^revision,
                updated_at: ^now
              ]
            ]
          ),
        returning: true
      )

    frontier
  end

  def lock(repo, host_id, session_id) do
    repo.one(
      from frontier in __MODULE__,
        where: frontier.host_id == ^host_id and frontier.session_id == ^session_id,
        lock: "FOR UPDATE"
    )
  end

  def mark_inflight(repo, frontier) do
    update_frontier(repo, frontier,
      inflight_generation: frontier.requested_generation,
      inflight_revision: frontier.requested_revision
    )
  end

  def replace_requested_revision(repo, frontier, revision) do
    update_frontier(repo, frontier, requested_revision: revision)
  end

  def complete(repo, frontier, generation, revision) do
    update_frontier(repo, frontier,
      inflight_generation: generation,
      inflight_revision: revision,
      completed_generation: generation,
      completed_revision: revision
    )
  end

  def get(repo, host_id, session_id),
    do: repo.get_by(__MODULE__, host_id: host_id, session_id: session_id)

  defp update_frontier(repo, frontier, fields) do
    changes =
      Map.new(fields)
      |> Map.put(:updated_at, DateTime.utc_now() |> DateTime.truncate(:microsecond))

    {1, [updated]} =
      repo.update_all(
        from(row in __MODULE__,
          where: row.host_id == ^frontier.host_id and row.session_id == ^frontier.session_id,
          select: row
        ),
        set: Map.to_list(changes)
      )

    updated
  end
end

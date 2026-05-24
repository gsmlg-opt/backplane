defmodule BackplaneMemory.Coordination.Action do
  @moduledoc "Action items with priority, status, and dependency edges."

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  @valid_statuses ~w(pending in_progress done blocked cancelled)

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts false

  schema "memory_actions" do
    field(:title, :string)
    field(:description, :string)
    field(:status, :string, default: "pending")
    field(:priority, :integer, default: 0)
    field(:created_by, :string)
    field(:project, :string)
    field(:tags, {:array, :string}, default: [])
    field(:source_observation_ids, {:array, :binary_id}, default: [])
    field(:source_memory_ids, {:array, :binary_id}, default: [])
    field(:parent_id, :binary_id)
    field(:created_at, :utc_datetime_usec)
    field(:updated_at, :utc_datetime_usec)
  end

  def changeset(action, attrs) do
    action
    |> cast(attrs, [
      :title,
      :description,
      :status,
      :priority,
      :created_by,
      :project,
      :tags,
      :source_observation_ids,
      :source_memory_ids,
      :parent_id,
      :created_at,
      :updated_at
    ])
    |> validate_required([:title])
    |> validate_inclusion(:status, @valid_statuses)
  end

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)

  @doc "Create an action with optional dependency edges."
  def create(attrs, edges \\ []) do
    now = DateTime.utc_now()
    attrs_with_timestamps = Map.merge(%{"created_at" => now, "updated_at" => now}, attrs)

    result =
      %__MODULE__{}
      |> changeset(attrs_with_timestamps)
      |> repo().insert()

    case result do
      {:ok, action} ->
        Enum.each(edges, fn %{"source_id" => src, "target_id" => tgt, "edge_type" => type} ->
          repo().insert_all(
            "memory_action_edges",
            [
              %{
                id: Ecto.UUID.dump!(Ecto.UUID.generate()),
                source_id: Ecto.UUID.dump!(src),
                target_id: Ecto.UUID.dump!(tgt),
                edge_type: type
              }
            ],
            on_conflict: :nothing
          )
        end)

        {:ok, action}

      error ->
        error
    end
  end

  @doc "Update status of an action."
  def update_status(action_id, status) when status in @valid_statuses do
    case repo().update_all(
           from(a in __MODULE__, where: a.id == ^action_id),
           set: [status: status, updated_at: DateTime.utc_now()]
         ) do
      {1, _} -> :ok
      {0, _} -> {:error, :not_found}
    end
  end

  def update_status(_, status), do: {:error, {:invalid_status, status}}

  @doc """
  Frontier: actions with no pending 'requires' prerequisites, sorted by priority DESC.
  Optionally scoped by project.
  """
  def frontier(project \\ nil) do
    base =
      from(a in __MODULE__,
        where: a.status in ["pending", "in_progress"],
        order_by: [desc: a.priority]
      )

    base = if project, do: where(base, [a], a.project == ^project), else: base

    blocked_ids =
      repo().all(
        from(e in "memory_action_edges",
          join: prereq in __MODULE__,
          on: prereq.id == type(e.source_id, :binary_id),
          where: e.edge_type == "requires" and prereq.status in ["pending", "in_progress"],
          select: type(e.target_id, :binary_id)
        )
      )

    repo().all(from(a in base, where: a.id not in ^blocked_ids))
  end

  @doc "Return the single highest-priority unblocked action."
  def next(project \\ nil) do
    frontier(project) |> List.first()
  end
end

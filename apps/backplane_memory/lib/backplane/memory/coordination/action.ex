defmodule Backplane.Memory.Coordination.Action do
  @moduledoc "Action items with priority, status, and dependency edges."

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Backplane.Memory.Audit

  @valid_statuses ~w(pending in_progress done blocked cancelled)

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts false

  schema "memory_actions" do
    field(:host_id, :string)
    field(:client_id, :string)
    field(:scope, :string)
    field(:namespace, :string)
    field(:title, :string)
    field(:description, :string)
    field(:status, :string, default: "pending")
    field(:priority, :integer, default: 0)
    field(:created_by, :string)
    field(:project, :string)
    field(:tags, {:array, :string}, default: [])
    field(:source_observation_ids, {:array, :binary_id}, default: [])
    field(:source_memory_ids, {:array, :binary_id}, default: [])
    field(:source_session_ids, {:array, :string}, default: [])
    field(:source_lesson_ids, {:array, :binary_id}, default: [])
    field(:source_crystal_ids, {:array, :binary_id}, default: [])
    field(:parent_id, :binary_id)
    field(:created_at, :utc_datetime_usec)
    field(:updated_at, :utc_datetime_usec)
  end

  def changeset(action, attrs) do
    action
    |> cast(attrs, [
      :title,
      :host_id,
      :client_id,
      :scope,
      :namespace,
      :description,
      :status,
      :priority,
      :created_by,
      :project,
      :tags,
      :source_observation_ids,
      :source_memory_ids,
      :source_session_ids,
      :source_lesson_ids,
      :source_crystal_ids,
      :parent_id,
      :created_at,
      :updated_at
    ])
    |> validate_required([:title])
    |> validate_inclusion(:status, @valid_statuses)
  end

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)

  @doc "Create an action with optional dependency edges."
  def create(attrs, edges \\ []), do: create(attrs, edges, nil)

  def create(attrs, edges, partition) do
    now = DateTime.utc_now()

    attrs_with_timestamps =
      %{"created_at" => now, "updated_at" => now}
      |> Map.merge(attrs)
      |> Map.merge(string_partition(partition))

    case repo().transaction(fn ->
           action =
             case %__MODULE__{} |> changeset(attrs_with_timestamps) |> repo().insert() do
               {:ok, action} -> action
               {:error, changeset} -> repo().rollback(changeset)
             end

           Enum.each(edges, fn %{"source_id" => src, "target_id" => tgt, "edge_type" => type} ->
             if owned_actions?(src, tgt, partition) do
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
             end
           end)

           Audit.log("coordination.action.create", action.created_by || "system", [action.id], %{
             status: action.status,
             project: action.project,
             host_id: action.host_id,
             client_id: action.client_id,
             scope: action.scope,
             namespace: action.namespace,
             result: "created"
           })

           action
         end) do
      {:ok, action} -> {:ok, action}
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
    end
  end

  @doc "Update status of an action."
  def update_status(action_id, status) when status in @valid_statuses,
    do: update_status(action_id, status, nil)

  def update_status(_, status), do: {:error, {:invalid_status, status}}

  def update_status(action_id, status, partition) when status in @valid_statuses do
    case repo().transaction(fn ->
           case repo().update_all(
                  from(a in __MODULE__,
                    where: a.id == ^action_id,
                    where: ^partition_dynamic(partition),
                    select: %{
                      host_id: a.host_id,
                      client_id: a.client_id,
                      scope: a.scope,
                      namespace: a.namespace
                    }
                  ),
                  set: [status: status, updated_at: DateTime.utc_now()]
                ) do
             {1, [action]} ->
               Audit.log("coordination.action.status", "system", [action_id], %{
                 status: status,
                 host_id: action.host_id,
                 client_id: action.client_id,
                 scope: action.scope,
                 namespace: action.namespace,
                 result: "updated"
               })

               :ok

             {0, _} ->
               repo().rollback(:not_found)
           end
         end) do
      {:ok, :ok} -> :ok
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  def update_status(_, status, _partition), do: {:error, {:invalid_status, status}}

  @doc "Returns a bounded, all-status page for one exact partition."
  def list(partition, opts \\ [])

  def list(partition, opts) when is_map(partition) and is_list(opts) do
    limit = Keyword.get(opts, :limit, 25)
    offset = Keyword.get(opts, :offset, 0)
    project = Keyword.get(opts, :project)

    if exact_partition?(partition) and is_integer(limit) and limit in 1..100 and
         is_integer(offset) and offset in 0..10_000 and
         (is_nil(project) or (is_binary(project) and String.trim(project) != "")) and
         Enum.all?(Keyword.keys(opts), &(&1 in [:limit, :offset, :project])) do
      query =
        from(a in __MODULE__,
          where: ^partition_dynamic(partition),
          order_by: [desc: a.updated_at, desc: a.id],
          limit: ^(limit + 1),
          offset: ^offset
        )

      query = if project, do: where(query, [a], a.project == ^String.trim(project)), else: query
      rows = repo().all(query)
      entries = Enum.take(rows, limit)
      next_offset = if length(rows) > limit, do: offset + limit
      {:ok, %{entries: entries, next_offset: next_offset}}
    else
      {:error, :invalid_options}
    end
  end

  def list(_partition, _opts), do: {:error, :partition_required}

  @doc "Returns one exact-partition action together with its current lease, if any."
  def detail(action_id, partition) when is_binary(action_id) and is_map(partition) do
    if exact_partition?(partition) do
      case repo().one(
             from(a in __MODULE__,
               where: a.id == ^action_id,
               where: ^partition_dynamic(partition)
             )
           ) do
        nil ->
          {:error, :not_found}

        action ->
          now = DateTime.utc_now()

          lease =
            repo().one(
              from(l in Backplane.Memory.Coordination.Lease,
                where: l.action_id == ^action.id and l.expires_at >= ^now,
                where: ^partition_dynamic(partition),
                order_by: [desc: l.expires_at],
                limit: 1
              )
            )

          {:ok, %{action: action, lease: lease}}
      end
    else
      {:error, :partition_required}
    end
  end

  def detail(_action_id, _partition), do: {:error, :partition_required}

  @doc """
  Frontier: actions with no pending 'requires' prerequisites, sorted by priority DESC.
  Optionally scoped by project.
  """
  def frontier(project \\ nil), do: frontier(project, nil)

  def frontier(project, partition) do
    base =
      from(a in __MODULE__,
        where: a.status in ["pending", "in_progress"],
        where: ^partition_dynamic(partition),
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
  def next(project \\ nil), do: frontier(project, nil) |> List.first()

  def next(project, partition), do: frontier(project, partition) |> List.first()

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

  defp exact_partition?(partition) do
    Enum.all?([:host_id, :client_id, :scope, :namespace], fn key ->
      case Map.get(partition, key) do
        value when is_binary(value) -> String.trim(value) != ""
        _ -> false
      end
    end)
  end

  defp string_partition(partition) when is_map(partition),
    do:
      Map.new([:host_id, :client_id, :scope, :namespace], fn key ->
        {Atom.to_string(key), Map.fetch!(partition, key)}
      end)

  defp string_partition(nil), do: %{}

  defp owned_actions?(source_id, target_id, partition) do
    repo().aggregate(
      from(action in __MODULE__,
        where: action.id in ^[source_id, target_id],
        where: ^partition_dynamic(partition)
      ),
      :count,
      :id
    ) == 2
  end
end

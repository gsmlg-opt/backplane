defmodule Backplane.Memory.Graph do
  @moduledoc "Knowledge graph context: node upsert, edge insert, stats."

  import Ecto.Query
  alias Backplane.Memory.Graph.{Edge, Node}
  alias Backplane.Memory.Memories.{Memory, Relation}

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)

  @doc """
  Insert a node, deduplicating by name+type.
  Uses Jaro distance >= 0.85 to identify the same entity.
  Returns `{:ok, node}` — either an existing node or a newly inserted one.
  """
  def upsert_node(attrs), do: upsert_node(attrs, nil)

  def upsert_node(attrs, partition) when is_map(attrs) do
    attrs = stringify_keys(attrs)
    name = attrs["name"]
    type = attrs["type"]

    existing =
      repo().all(
        from(n in Node,
          where: n.type == ^type,
          where: ^partition_dynamic(partition),
          select: {n.id, n.name}
        )
      )

    new_obs_ids = List.wrap(attrs["source_observation_ids"])

    case find_fuzzy_match(existing, name) do
      {existing_id, _} ->
        node = repo().get!(Node, existing_id)

        merged_ids =
          (node.source_observation_ids ++ new_obs_ids)
          |> Enum.uniq()

        node
        |> Ecto.Changeset.change(source_observation_ids: merged_ids)
        |> repo().update()
        |> case do
          {:ok, updated} -> {:ok, updated}
          {:error, _} -> {:ok, node}
        end

      nil ->
        %Node{}
        |> Node.changeset(Map.merge(attrs, string_partition_attrs(partition)))
        |> repo().insert()
    end
  end

  @doc "Insert an edge between two node IDs. Silently ignores duplicate (source, target, relation) combinations."
  def insert_edge(attrs), do: insert_edge(attrs, nil)

  def insert_edge(attrs, partition) when is_map(attrs) do
    attrs = Map.merge(stringify_keys(attrs), string_partition_attrs(partition))
    source_id = attrs["source_id"]
    target_id = attrs["target_id"]

    if owned_nodes?(source_id, target_id, partition) do
      %Edge{}
      |> Edge.changeset(attrs)
      |> repo().insert(
        on_conflict: :nothing,
        conflict_target: [:source_id, :target_id, :relation]
      )
    else
      {:error, :not_found}
    end
  end

  @doc "Return node count by type and edge count by relation."
  def stats, do: stats(nil)

  def stats(partition) do
    node_stats =
      repo().all(
        from(n in Node,
          where: ^partition_dynamic(partition),
          group_by: n.type,
          select: {n.type, count(n.id)}
        )
      )
      |> Map.new()

    edge_stats =
      repo().all(
        from(e in Edge,
          where: ^partition_dynamic(partition),
          group_by: e.relation,
          select: {e.relation, count(e.id)}
        )
      )
      |> Map.new()

    relation_stats =
      repo().all(
        from(r in Relation,
          join: memory in Memory,
          on: memory.id == r.source_memory_id,
          where: ^relation_partition_dynamic(partition),
          group_by: r.domain,
          select: {r.domain, count(r.id)}
        )
      )
      |> Map.new()

    relation_stats =
      Map.merge(%{"knowledge" => 0, "lifecycle" => 0, "provenance" => 0}, relation_stats)

    %{
      node_count_by_type: node_stats,
      edge_count_by_relation: edge_stats,
      relation_count_by_domain: relation_stats
    }
  end

  @doc "Return a bounded, exact-partition relation view for one semantic domain."
  def relations(partition, domain, limit \\ 50)

  def relations(partition, domain, limit)
      when domain in ~w(knowledge lifecycle provenance) and limit in 1..100 do
    query =
      from(r in Relation,
        join: source in Memory,
        on: source.id == r.source_memory_id,
        join: target in Memory,
        on: target.id == r.target_memory_id,
        where: r.domain == ^domain,
        order_by: [desc: r.created_at, desc: r.id],
        limit: ^limit,
        select: %{
          id: r.id,
          domain: r.domain,
          relation_type: r.relation_type,
          status: r.status,
          confidence: r.confidence,
          source_memory_id: source.id,
          source_content: source.content,
          target_memory_id: target.id,
          target_content: target.content
        }
      )

    query
    |> relation_partition(partition)
    |> repo().all()
  end

  def relations(_partition, _domain, _limit), do: []

  defp relation_partition(query, nil) do
    where(
      query,
      [_relation, source, _target],
      is_nil(source.host_id) and is_nil(source.client_id) and is_nil(source.scope) and
        is_nil(source.namespace)
    )
  end

  defp relation_partition(query, partition) do
    where(
      query,
      [_relation, source, _target],
      source.host_id == ^Map.fetch!(partition, :host_id) and
        source.client_id == ^Map.fetch!(partition, :client_id) and
        source.scope == ^Map.fetch!(partition, :scope) and
        source.namespace == ^Map.fetch!(partition, :namespace)
    )
  end

  defp partition_dynamic(nil),
    do:
      dynamic(
        [row],
        is_nil(row.host_id) and is_nil(row.client_id) and is_nil(row.scope) and
          is_nil(row.namespace)
      )

  defp partition_dynamic(partition) when is_map(partition) do
    dynamic(
      [row],
      row.host_id == ^Map.fetch!(partition, :host_id) and
        row.client_id == ^Map.fetch!(partition, :client_id) and
        row.scope == ^Map.fetch!(partition, :scope) and
        row.namespace == ^Map.fetch!(partition, :namespace)
    )
  end

  defp relation_partition_dynamic(nil) do
    dynamic(
      [_relation, memory],
      is_nil(memory.host_id) and is_nil(memory.client_id) and is_nil(memory.scope) and
        is_nil(memory.namespace)
    )
  end

  defp relation_partition_dynamic(partition) when is_map(partition) do
    dynamic(
      [_relation, memory],
      memory.host_id == ^Map.fetch!(partition, :host_id) and
        memory.client_id == ^Map.fetch!(partition, :client_id) and
        memory.scope == ^Map.fetch!(partition, :scope) and
        memory.namespace == ^Map.fetch!(partition, :namespace)
    )
  end

  defp string_partition_attrs(nil), do: %{}

  defp string_partition_attrs(partition) when is_map(partition),
    do:
      Map.new([:host_id, :client_id, :scope, :namespace], fn key ->
        {Atom.to_string(key), Map.fetch!(partition, key)}
      end)

  defp stringify_keys(attrs), do: Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

  defp owned_nodes?(source_id, target_id, partition) do
    repo().aggregate(
      from(n in Node,
        where: n.id in ^[source_id, target_id],
        where: ^partition_dynamic(partition)
      ),
      :count,
      :id
    ) == 2
  end

  # Jaro distance >= 0.85 = likely same entity
  defp find_fuzzy_match(candidates, name) do
    Enum.find(candidates, fn {_, candidate_name} ->
      String.jaro_distance(String.downcase(candidate_name), String.downcase(name)) >= 0.85
    end)
  end
end

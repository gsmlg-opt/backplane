defmodule Backplane.Memory.Graph.BFS do
  @moduledoc """
  BFS traversal over the knowledge graph starting from nodes whose name
  matches `entity_name` (case-insensitive), up to `depth` hops.
  """

  import Ecto.Query
  alias Backplane.Memory.Graph.{Edge, Node}
  alias Backplane.Memory.PartitionIdentity

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)

  @doc """
  BFS from nodes matching entity_name up to depth hops.

  A partition is required. This unpartitioned overload returns
  `{:error, :unauthorized}`.
  """
  @spec query(String.t(), pos_integer(), String.t() | nil) ::
          {:error, :unauthorized}
  def query(_entity_name, _depth \\ 2, _relation_filter \\ nil), do: {:error, :unauthorized}

  def query(entity_name, depth, relation_filter, partition) do
    with {:ok, partition} <- PartitionIdentity.validate(partition) do
      do_query(entity_name, depth, relation_filter, partition)
    end
  end

  defp do_query(entity_name, depth, relation_filter, partition) do
    seed_nodes =
      repo().all(
        from(n in Node,
          where: ilike(n.name, ^entity_name),
          where: ^partition_dynamic(partition)
        )
      )

    seed_ids = Enum.map(seed_nodes, & &1.id)
    bfs(seed_ids, seed_nodes, [], relation_filter, depth, partition)
  end

  @doc """
  BFS starting from a pre-fetched list of seed nodes up to depth hops.

  A partition is required. This unpartitioned overload returns
  `{:error, :unauthorized}`.
  """
  @spec query_from_nodes([map()], pos_integer(), String.t() | nil) ::
          {:error, :unauthorized}
  def query_from_nodes(_seed_nodes, _depth, _relation_filter \\ nil), do: {:error, :unauthorized}

  def query_from_nodes(seed_nodes, depth, relation_filter, partition) when is_list(seed_nodes) do
    with {:ok, partition} <- PartitionIdentity.validate(partition) do
      seed_nodes = Enum.filter(seed_nodes, &partition_match?(&1, partition))
      seed_ids = Enum.map(seed_nodes, & &1.id)
      bfs(seed_ids, seed_nodes, [], relation_filter, depth, partition)
    end
  end

  defp bfs([], visited_nodes, visited_edges, _filter, _depth, _partition),
    do: {:ok, %{nodes: visited_nodes, edges: visited_edges}}

  defp bfs(_frontier, visited_nodes, visited_edges, _filter, 0, _partition),
    do: {:ok, %{nodes: visited_nodes, edges: visited_edges}}

  defp bfs(frontier_ids, visited_nodes, visited_edges, relation_filter, depth, partition) do
    edge_query =
      from(e in Edge,
        where: e.source_id in ^frontier_ids or e.target_id in ^frontier_ids,
        where: ^partition_dynamic(partition)
      )

    edge_query =
      if relation_filter do
        where(edge_query, [e], e.relation == ^relation_filter)
      else
        edge_query
      end

    new_edges = repo().all(edge_query)

    visited_edge_ids = MapSet.new(visited_edges, & &1.id)
    truly_new_edges = Enum.reject(new_edges, &MapSet.member?(visited_edge_ids, &1.id))

    reachable_ids =
      truly_new_edges
      |> Enum.flat_map(fn e -> [e.source_id, e.target_id] end)
      |> Enum.uniq()

    visited_node_ids = MapSet.new(visited_nodes, & &1.id)
    new_node_ids = Enum.reject(reachable_ids, &MapSet.member?(visited_node_ids, &1))

    new_nodes =
      if new_node_ids == [] do
        []
      else
        repo().all(
          from(n in Node, where: n.id in ^new_node_ids, where: ^partition_dynamic(partition))
        )
      end

    bfs(
      new_node_ids,
      visited_nodes ++ new_nodes,
      visited_edges ++ truly_new_edges,
      relation_filter,
      depth - 1,
      partition
    )
  end

  defp partition_dynamic(partition) when is_map(partition) do
    dynamic(
      [row],
      row.memory_space_id == ^Map.fetch!(partition, :memory_space_id) and
        row.scope == ^Map.fetch!(partition, :scope) and
        row.namespace == ^Map.fetch!(partition, :namespace)
    )
  end

  defp partition_match?(node, partition) do
    node.memory_space_id == Map.fetch!(partition, :memory_space_id) and
      node.scope == Map.fetch!(partition, :scope) and
      node.namespace == Map.fetch!(partition, :namespace)
  end
end

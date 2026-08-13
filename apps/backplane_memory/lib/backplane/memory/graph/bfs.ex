defmodule Backplane.Memory.Graph.BFS do
  @moduledoc """
  BFS traversal over the knowledge graph starting from nodes whose name
  matches `entity_name` (case-insensitive), up to `depth` hops.
  """

  import Ecto.Query
  alias Backplane.Memory.Graph.{Edge, Node}

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)

  @doc """
  BFS from nodes matching entity_name up to depth hops.

  Optional `relation_filter` (string) restricts edge traversal to that
  relation type. Returns `{:ok, %{nodes: [...], edges: [...]}}`.
  """
  @spec query(String.t(), pos_integer(), String.t() | nil) ::
          {:ok, %{nodes: [Node.t()], edges: [Edge.t()]}}
  def query(entity_name, depth \\ 2, relation_filter \\ nil) do
    query(entity_name, depth, relation_filter, nil)
  end

  def query(entity_name, depth, relation_filter, partition) do
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

  Avoids a redundant DB lookup when the caller already has the seed nodes.
  Returns `{:ok, %{nodes: [...], edges: [...]}}`.
  """
  @spec query_from_nodes([Node.t()], pos_integer(), String.t() | nil) ::
          {:ok, %{nodes: [Node.t()], edges: [Edge.t()]}}
  def query_from_nodes(seed_nodes, depth, relation_filter \\ nil) when is_list(seed_nodes) do
    query_from_nodes(seed_nodes, depth, relation_filter, nil)
  end

  def query_from_nodes(seed_nodes, depth, relation_filter, partition) when is_list(seed_nodes) do
    seed_nodes = Enum.filter(seed_nodes, &partition_match?(&1, partition))
    seed_ids = Enum.map(seed_nodes, & &1.id)
    bfs(seed_ids, seed_nodes, [], relation_filter, depth, partition)
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

  defp partition_match?(node, nil) do
    is_nil(node.host_id) and is_nil(node.client_id) and is_nil(node.scope) and
      is_nil(node.namespace)
  end

  defp partition_match?(node, partition) do
    node.host_id == Map.fetch!(partition, :host_id) and
      node.client_id == Map.fetch!(partition, :client_id) and
      node.scope == Map.fetch!(partition, :scope) and
      node.namespace == Map.fetch!(partition, :namespace)
  end
end

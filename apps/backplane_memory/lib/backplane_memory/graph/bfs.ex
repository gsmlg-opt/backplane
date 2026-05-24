defmodule BackplaneMemory.Graph.BFS do
  @moduledoc """
  BFS traversal over the knowledge graph starting from nodes whose name
  matches `entity_name` (case-insensitive), up to `depth` hops.
  """

  import Ecto.Query
  alias BackplaneMemory.Graph.{Edge, Node}

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)

  @doc """
  BFS from nodes matching entity_name up to depth hops.

  Optional `relation_filter` (string) restricts edge traversal to that
  relation type. Returns `{:ok, %{nodes: [...], edges: [...]}}`.
  """
  @spec query(String.t(), pos_integer(), String.t() | nil) ::
          {:ok, %{nodes: [Node.t()], edges: [Edge.t()]}}
  def query(entity_name, depth \\ 2, relation_filter \\ nil) do
    seed_nodes =
      repo().all(
        from(n in Node,
          where: ilike(n.name, ^entity_name)
        )
      )

    seed_ids = Enum.map(seed_nodes, & &1.id)
    bfs(seed_ids, seed_nodes, [], relation_filter, depth)
  end

  @doc """
  BFS starting from a pre-fetched list of seed nodes up to depth hops.

  Avoids a redundant DB lookup when the caller already has the seed nodes.
  Returns `{:ok, %{nodes: [...], edges: [...]}}`.
  """
  @spec query_from_nodes([Node.t()], pos_integer(), String.t() | nil) ::
          {:ok, %{nodes: [Node.t()], edges: [Edge.t()]}}
  def query_from_nodes(seed_nodes, depth, relation_filter \\ nil) when is_list(seed_nodes) do
    seed_ids = Enum.map(seed_nodes, & &1.id)
    bfs(seed_ids, seed_nodes, [], relation_filter, depth)
  end

  defp bfs([], visited_nodes, visited_edges, _filter, _depth),
    do: {:ok, %{nodes: visited_nodes, edges: visited_edges}}

  defp bfs(_frontier, visited_nodes, visited_edges, _filter, 0),
    do: {:ok, %{nodes: visited_nodes, edges: visited_edges}}

  defp bfs(frontier_ids, visited_nodes, visited_edges, relation_filter, depth) do
    edge_query =
      from(e in Edge,
        where: e.source_id in ^frontier_ids or e.target_id in ^frontier_ids
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
        repo().all(from(n in Node, where: n.id in ^new_node_ids))
      end

    bfs(
      new_node_ids,
      visited_nodes ++ new_nodes,
      visited_edges ++ truly_new_edges,
      relation_filter,
      depth - 1
    )
  end
end

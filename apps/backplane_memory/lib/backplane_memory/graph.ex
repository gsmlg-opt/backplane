defmodule BackplaneMemory.Graph do
  @moduledoc "Knowledge graph context: node upsert, edge insert, stats."

  import Ecto.Query
  alias BackplaneMemory.Graph.{Edge, Node}

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)

  @doc """
  Insert a node, deduplicating by name+type.
  Uses Jaro distance >= 0.85 to identify the same entity.
  Returns `{:ok, node}` — either an existing node or a newly inserted one.
  """
  def upsert_node(attrs) do
    name = attrs[:name] || attrs["name"]
    type = attrs[:type] || attrs["type"]

    existing = repo().all(from(n in Node, where: n.type == ^type, select: {n.id, n.name}))

    case find_fuzzy_match(existing, name) do
      {existing_id, _} ->
        {:ok, repo().get!(Node, existing_id)}

      nil ->
        %Node{}
        |> Node.changeset(attrs)
        |> repo().insert()
    end
  end

  @doc "Insert an edge between two node IDs."
  def insert_edge(attrs) do
    %Edge{}
    |> Edge.changeset(attrs)
    |> repo().insert()
  end

  @doc "Return node count by type and edge count by relation."
  def stats do
    node_stats =
      repo().all(
        from(n in Node,
          group_by: n.type,
          select: {n.type, count(n.id)}
        )
      )
      |> Map.new()

    edge_stats =
      repo().all(
        from(e in Edge,
          group_by: e.relation,
          select: {e.relation, count(e.id)}
        )
      )
      |> Map.new()

    %{node_count_by_type: node_stats, edge_count_by_relation: edge_stats}
  end

  # Jaro distance >= 0.85 = likely same entity
  defp find_fuzzy_match(candidates, name) do
    Enum.find(candidates, fn {_, candidate_name} ->
      String.jaro_distance(String.downcase(candidate_name), String.downcase(name)) >= 0.85
    end)
  end
end

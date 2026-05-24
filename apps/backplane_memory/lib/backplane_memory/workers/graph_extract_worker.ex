defmodule BackplaneMemory.Workers.GraphExtractWorker do
  @moduledoc "Oban worker: extract knowledge graph entities/edges from session observations after session end."

  use Oban.Worker, queue: :memory, max_attempts: 3

  import Ecto.Query

  alias BackplaneMemory.Graph
  alias BackplaneMemory.Memories.Memory

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"session_id" => session_id}}) do
    min_obs =
      case Backplane.Settings.get("memory.graph_min_observations") do
        v when is_binary(v) -> String.to_integer(v)
        v when is_integer(v) -> v
        _ -> 3
      end

    obs_count =
      repo().aggregate(
        from(m in Memory,
          where: m.session_id == ^session_id and is_nil(m.deleted_at)
        ),
        :count,
        :id
      )

    if obs_count < min_obs do
      {:ok, :skipped_min_observations}
    else
      extract_graph(session_id)
    end
  end

  defp extract_graph(session_id) do
    memories =
      repo().all(
        from(m in Memory,
          where: m.session_id == ^session_id and is_nil(m.deleted_at),
          select: m.content,
          limit: 50
        )
      )

    llm_module = Application.get_env(:backplane_memory, :llm_module, BackplaneMemory.LLM)

    case llm_module.extract_graph(memories) do
      {:ok, %{nodes: nodes, edges: edges}} ->
        Enum.each(nodes, &Graph.upsert_node/1)
        Enum.each(edges, &Graph.insert_edge/1)
        {:ok, %{nodes_extracted: length(nodes), edges_extracted: length(edges)}}

      {:skip, reason} ->
        {:ok, {:skipped, reason}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Enqueue a graph extraction job for a session."
  def enqueue(session_id) do
    %{session_id: session_id}
    |> new()
    |> Oban.insert()
  end
end

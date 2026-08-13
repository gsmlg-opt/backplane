defmodule Backplane.Memory.Workers.GraphExtractWorker do
  @moduledoc "Oban worker: extract knowledge graph entities/edges from session observations after session end."

  use Oban.Worker, queue: :memory, max_attempts: 3

  import Ecto.Query

  alias Backplane.Memory.Graph
  alias Backplane.Memory.Memories.Memory
  alias Backplane.Memory.Projections.ProjectedObservation

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)

  @impl Oban.Worker
  def perform(%Oban.Job{
        args:
          %{
            "session_id" => session_id,
            "host_id" => _host_id,
            "client_id" => _client_id,
            "scope" => _scope,
            "namespace" => _namespace
          } = partition
      }) do
    Backplane.Memory.PipelineTelemetry.span("graph", partition, fn ->
      perform_partition(session_id, partition)
    end)
  end

  def perform(%Oban.Job{}), do: {:discard, :ambiguous_partition}

  defp perform_partition(session_id, partition) do
    host_id = partition["host_id"]
    client_id = partition["client_id"]
    scope = partition["scope"]
    namespace = partition["namespace"]

    min_obs =
      case Backplane.Settings.get("memory.graph_min_observations") do
        v when is_binary(v) -> String.to_integer(v)
        v when is_integer(v) -> v
        _ -> 3
      end

    obs_count =
      repo().aggregate(
        from(m in Memory,
          where:
            m.session_id == ^session_id and m.host_id == ^host_id and
              m.client_id == ^client_id and m.scope == ^scope and
              m.namespace == ^namespace and is_nil(m.deleted_at)
        ),
        :count,
        :id
      )

    if obs_count < min_obs do
      {:ok, :skipped_min_observations}
    else
      extract_graph(session_id, partition)
    end
  end

  defp extract_graph(session_id, partition) do
    host_id = partition["host_id"]
    client_id = partition["client_id"]
    scope = partition["scope"]
    namespace = partition["namespace"]

    memories =
      repo().all(
        from(m in Memory,
          where:
            m.session_id == ^session_id and m.host_id == ^host_id and
              m.client_id == ^client_id and m.scope == ^scope and
              m.namespace == ^namespace and is_nil(m.deleted_at),
          select: m.content,
          limit: 50
        )
      )

    llm_module = Application.get_env(:backplane_memory, :llm_module, Backplane.Memory.LLM)

    case llm_module.extract_graph(memories) do
      {:ok, %{nodes: nodes, edges: edges}} ->
        atom_partition = atom_partition(partition)

        source_event_ids =
          repo().all(
            from(observation in ProjectedObservation,
              where:
                observation.session_id == ^session_id and observation.host_id == ^host_id and
                  observation.client_id == ^client_id and observation.scope == ^scope and
                  observation.namespace == ^namespace,
              order_by: [asc: observation.event_id],
              limit: 256,
              select: observation.event_id
            )
          )

        Enum.each(nodes, fn node ->
          node
          |> Map.drop([:source_observation_ids, "source_observation_ids"])
          |> Map.put(:source_observation_ids, source_event_ids)
          |> Graph.upsert_node(atom_partition)
        end)

        Enum.each(edges, &Graph.insert_edge(&1, atom_partition))
        {:ok, %{nodes_extracted: length(nodes), edges_extracted: length(edges)}}

      {:skip, reason} ->
        {:ok, {:skipped, reason}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Enqueue a graph extraction job for a session."
  def enqueue(_session_id), do: {:error, :unauthorized}

  def enqueue(session_id, partition) do
    %{session_id: session_id}
    |> Map.merge(atom_partition(partition))
    |> new()
    |> Oban.insert()
  end

  defp atom_partition(partition) do
    Map.new([:host_id, :client_id, :scope, :namespace], fn key ->
      value = Map.get(partition, key) || Map.fetch!(partition, Atom.to_string(key))
      {key, value}
    end)
  end
end

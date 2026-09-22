defmodule Backplane.Memory.Workers.GraphExtractWorker do
  @moduledoc "Oban worker: extract knowledge graph entities/edges from session observations after session end."

  use Oban.Worker, queue: :memory, max_attempts: 3

  import Ecto.Query

  alias Backplane.Memory.Graph
  alias Backplane.Memory.Memories.Memory
  alias Backplane.Memory.PartitionIdentity

  alias Backplane.Memory.Projections.{
    ProcessingState,
    ProjectedObservation,
    ProjectedSession,
    Source
  }

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)

  @impl Oban.Worker
  def perform(
        %Oban.Job{
          args:
            %{
              "session_id" => session_id,
              "memory_space_id" => _memory_space_id,
              "host_id" => _host_id,
              "client_id" => _client_id,
              "scope" => _scope,
              "namespace" => _namespace
            } = partition
        } = job
      ) do
    Backplane.Memory.PipelineTelemetry.span("graph", partition, fn ->
      case generator_partition(session_id, partition) do
        {:ok, partition} ->
          perform_partition(session_id, partition, job)

        {:error, reason} ->
          record_partition_issue(session_id, partition, reason)
          {:discard, reason}
      end
    end)
  end

  def perform(%Oban.Job{}), do: {:discard, :ambiguous_partition}

  defp perform_partition(session_id, partition, job) do
    host_id = partition.host_id
    memory_space_id = partition.memory_space_id
    client_id = partition.client_id
    scope = partition.scope
    namespace = partition.namespace

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
            m.session_id == ^session_id and m.memory_space_id == ^memory_space_id and
              m.host_id == ^host_id and
              m.client_id == ^client_id and m.scope == ^scope and
              m.namespace == ^namespace and is_nil(m.deleted_at)
        ),
        :count,
        :id
      )

    with {:ok, state_attrs} <- processing_attrs(session_id, partition) do
      case transition_current(session_id, partition, state_attrs, "running") do
        {:ok, _state} ->
          run_current(session_id, partition, state_attrs, obs_count, min_obs, job)

        {:stale, _state} ->
          {:discard, :stale}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp run_current(session_id, partition, state_attrs, obs_count, min_obs, job) do
    try do
      result =
        if obs_count < min_obs do
          {:ok, :skipped_min_observations}
        else
          extract_graph(session_id, partition)
        end

      case result do
        {:generated, nodes, edges} ->
          case persist_graph(session_id, partition, state_attrs, nodes, edges) do
            {:error, reason} = error ->
              record_processing_outcome(
                session_id,
                partition,
                state_attrs,
                error,
                job
              )

              {:error, reason}

            result ->
              result
          end

        _other ->
          record_processing_outcome(session_id, partition, state_attrs, result, job)
          result
      end
    rescue
      exception ->
        record_processing_outcome(session_id, partition, state_attrs, {:error, exception}, job)
        reraise exception, __STACKTRACE__
    end
  end

  defp extract_graph(session_id, partition) do
    host_id = partition.host_id
    memory_space_id = partition.memory_space_id
    client_id = partition.client_id
    scope = partition.scope
    namespace = partition.namespace

    memories =
      repo().all(
        from(m in Memory,
          where:
            m.session_id == ^session_id and m.memory_space_id == ^memory_space_id and
              m.host_id == ^host_id and
              m.client_id == ^client_id and m.scope == ^scope and
              m.namespace == ^namespace and is_nil(m.deleted_at),
          select: m.content,
          limit: 50
        )
      )

    llm_module = Application.get_env(:backplane_memory, :llm_module, Backplane.Memory.LLM)

    case llm_module.extract_graph(memories) do
      {:ok, %{nodes: nodes, edges: edges}} ->
        {:generated, nodes, edges}

      {:skip, reason} ->
        {:ok, {:skipped, reason}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp persist_graph(session_id, partition, attrs, nodes, edges) do
    result = %{nodes_extracted: length(nodes), edges_extracted: length(edges)}

    case ProcessingState.persist_current(
           repo(),
           attrs,
           fn -> current_attrs(session_id, partition) end,
           fn -> do_persist_graph(session_id, partition, nodes, edges, result) end
         ) do
      {:ok, ^result, _state} -> {:ok, result}
      {:stale, _state} -> {:discard, :stale}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_persist_graph(session_id, partition, nodes, edges, result) do
    atom_partition = atom_partition(partition)

    source_event_ids =
      repo().all(
        from(observation in ProjectedObservation,
          where:
            observation.session_id == ^session_id and
              observation.memory_space_id == ^partition.memory_space_id and
              observation.host_id == ^partition.host_id and
              observation.client_id == ^partition.client_id and
              observation.scope == ^partition.scope and
              observation.namespace == ^partition.namespace,
          order_by: [asc: observation.event_id],
          limit: 256,
          select: observation.event_id
        )
      )

    writes =
      Enum.map(nodes, fn node ->
        node
        |> Map.drop([:source_observation_ids, "source_observation_ids"])
        |> Map.put(:source_observation_ids, source_event_ids)
        |> Graph.upsert_node(atom_partition)
      end) ++ Enum.map(edges, &Graph.insert_edge(&1, atom_partition))

    case Enum.find(writes, &match?({:error, _reason}, &1)) do
      {:error, reason} -> {:error, reason}
      nil -> {:ok, result}
    end
  end

  @doc "Enqueue a graph extraction job for a session."
  def enqueue(_session_id), do: {:error, :unauthorized}

  def enqueue(session_id, partition) do
    case generator_partition(session_id, partition) do
      {:ok, partition} ->
        %{session_id: session_id}
        |> Map.merge(atom_partition(partition))
        |> new()
        |> Oban.insert()

      {:error, reason} = error ->
        record_partition_issue(session_id, partition, reason)
        error
    end
  end

  defp atom_partition(partition) do
    Map.new(
      [:memory_space_id, :host_id, :client_id, :source_client_id, :scope, :namespace],
      fn key ->
        value = Map.get(partition, key) || Map.get(partition, Atom.to_string(key))
        {key, value}
      end
    )
  end

  defp generator_partition(session_id, partition) do
    with {:ok, claim} <- PartitionIdentity.validate_generator(partition),
         {:ok, expected} <- authoritative_partition(session_id, claim),
         {:ok, validated} <- PartitionIdentity.validate_generator(claim, expected) do
      {:ok, validated}
    end
  end

  defp authoritative_partition(session_id, claim) do
    cond do
      exact_source?(session_id, claim) -> {:ok, claim}
      any_source?(session_id) -> {:error, :partition_mismatch}
      true -> {:error, :incomplete_partition}
    end
  end

  defp exact_source?(session_id, claim) do
    repo().exists?(
      from(s in ProjectedSession,
        where:
          s.session_id == ^session_id and s.memory_space_id == ^claim.memory_space_id and
            s.host_id == ^claim.host_id and s.client_id == ^claim.client_id and
            s.scope == ^claim.scope and s.namespace == ^claim.namespace
      )
    ) or
      repo().exists?(
        from(m in Memory,
          where:
            m.session_id == ^session_id and m.memory_space_id == ^claim.memory_space_id and
              m.host_id == ^claim.host_id and m.client_id == ^claim.client_id and
              m.scope == ^claim.scope and m.namespace == ^claim.namespace and
              is_nil(m.deleted_at)
        )
      )
  end

  defp any_source?(session_id) do
    repo().exists?(from(s in ProjectedSession, where: s.session_id == ^session_id)) or
      repo().exists?(
        from(m in Memory, where: m.session_id == ^session_id and is_nil(m.deleted_at))
      )
  end

  defp record_partition_issue(session_id, partition, reason) do
    claim = issue_partition(partition)
    details = Map.put(claim, :session_id, session_id)

    source_id =
      [session_id, claim]
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    Backplane.Memory.Memories.record_partition_issue(
      "memory_graph_generator",
      source_id,
      reason,
      details
    )
  end

  defp issue_partition(partition) do
    Map.new([:memory_space_id, :host_id, :client_id, :scope, :namespace], fn key ->
      value = Map.get(partition, key, Map.get(partition, Atom.to_string(key)))
      {key, if(is_binary(value), do: String.trim(value), else: value)}
    end)
  end

  defp processing_attrs(session_id, partition) do
    case repo().one(
           from(session in ProjectedSession,
             where:
               session.session_id == ^session_id and
                 session.memory_space_id == ^partition.memory_space_id and
                 session.host_id == ^partition.host_id and
                 session.client_id == ^partition.client_id and
                 session.scope == ^partition.scope and session.namespace == ^partition.namespace,
             lock: "FOR UPDATE",
             select: session.input_revision
           )
         ) do
      revision when is_binary(revision) and revision != "" ->
        {:ok,
         %{
           memory_space_id: partition.memory_space_id,
           host_id: partition.host_id,
           source_client_id: partition[:source_client_id],
           scope: partition.scope,
           namespace: partition.namespace,
           projector: "graph",
           subject_type: "captured_session",
           subject_id:
             Backplane.Memory.Projections.Source.subject_id!(partition.host_id, session_id),
           processing_version: "graph-v1",
           input_revision: revision,
           output_revision: nil
         }}

      _ ->
        {:error, :projection_incomplete}
    end
  end

  defp record_processing_outcome(session_id, partition, attrs, {:ok, {:skipped, reason}}, _job),
    do:
      transition_current(session_id, partition, attrs, ProcessingState.skipped_status(reason),
        reason: reason
      )

  defp record_processing_outcome(session_id, partition, attrs, {:ok, _result}, _job),
    do: transition_current(session_id, partition, attrs, "complete")

  defp record_processing_outcome(session_id, partition, attrs, {:error, reason}, job),
    do:
      transition_current(session_id, partition, attrs, ProcessingState.failure_status(job),
        reason: reason
      )

  defp transition_current(session_id, partition, attrs, status, opts \\ []) do
    ProcessingState.transition_current(
      repo(),
      attrs,
      status,
      fn ->
        current_attrs(session_id, partition)
      end,
      opts
    )
  end

  defp current_attrs(session_id, partition) do
    Source.lock_streams(partition.host_id, session_id)
    processing_attrs(session_id, partition)
  end
end

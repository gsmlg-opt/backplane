defmodule Backplane.Memory.Recall.Channels do
  @moduledoc "Bounded, exact-partition FTS, vector, and entity graph recall channels."

  import Ecto.Query

  alias Backplane.Memory.Embedding.Client
  alias Backplane.Memory.Events.Event
  alias Backplane.Memory.Graph.{Edge, Node}
  alias Backplane.Memory.Lessons.Lesson
  alias Backplane.Memory.Memories.{Evidence, Memory, RememberRequest}
  alias Backplane.Memory.Observations.Observation
  alias Backplane.Memory.Projections.{ProjectedObservation, ProjectedSession}
  alias Backplane.Memory.Recall.{Adapters, QueryPlan}
  alias Backplane.Memory.Summaries.{SourceEvent, Summary}
  alias Pgvector.HalfVector

  @max_limit 500
  @graph_node_cap 100
  @graph_edge_cap 200
  @graph_depth 2

  def fts(%QueryPlan{} = plan, limit) when limit in 1..@max_limit do
    memories = fts_memories(plan, limit)
    summaries = if plan.facets == [], do: fts_summaries(plan, limit), else: []

    rows =
      (memories ++ summaries)
      |> Enum.sort_by(fn {candidate, score} ->
        {-score, kind_order(candidate.kind), candidate.id}
      end)
      |> Enum.take(limit)

    {:ok, rows}
  end

  def fts(%QueryPlan{}, _limit), do: {:error, :invalid_limit}

  def lessons(%QueryPlan{} = plan, limit) when limit in 1..@max_limit do
    rows =
      Memory
      |> active_memory_query(plan)
      |> join(:inner, [memory], lesson in Lesson,
        on: lesson.memory_id == memory.id and lesson.status == "active"
      )
      |> where([memory], memory.memory_type == "procedural")
      |> where(
        [memory],
        fragment("search_tsv @@ websearch_to_tsquery('english', ?)", ^plan.normalized_query)
      )
      |> order_by(
        [memory, lesson],
        desc:
          fragment(
            "ts_rank(search_tsv, websearch_to_tsquery('english', ?)) * GREATEST(0.0, 1.0 - ?)",
            ^plan.normalized_query,
            lesson.decay_rate
          ),
        asc: memory.id
      )
      |> limit(^limit)
      |> select(
        [memory, lesson],
        {memory,
         fragment(
           "ts_rank(search_tsv, websearch_to_tsquery('english', ?)) * GREATEST(0.0, 1.0 - ?)",
           ^plan.normalized_query,
           lesson.decay_rate
         )}
      )
      |> repo().all()
      |> adapt_memory_rows(plan)

    {:ok, rows}
  end

  def lessons(%QueryPlan{}, _limit), do: {:error, :invalid_limit}

  @doc "Returns the bounded highest-priority active lessons without requiring a text query match."
  def top_lessons(%QueryPlan{} = plan, limit) when limit in 1..@max_limit do
    rows =
      Memory
      |> active_memory_query(plan)
      |> join(:inner, [memory], lesson in Lesson,
        on: lesson.memory_id == memory.id and lesson.status == "active"
      )
      |> where([memory], memory.memory_type == "procedural")
      |> order_by([memory, lesson],
        desc: memory.confidence,
        desc: lesson.reinforcement_count,
        desc_nulls_last: lesson.last_applied_at,
        asc: memory.id
      )
      |> limit(^limit)
      |> select([memory, _lesson], {memory, 1.0})
      |> repo().all()
      |> adapt_memory_rows(plan)

    {:ok, rows}
  end

  def top_lessons(%QueryPlan{}, _limit), do: {:error, :invalid_limit}

  def vector(plan, limit, embed_fn \\ nil)

  def vector(%QueryPlan{} = plan, limit, embed_fn) when limit in 1..@max_limit do
    embed_fn = embed_fn || (&Client.embed/3)

    with {:ok, [vector]} <- embed_fn.([plan.normalized_query], :query, []) do
      query_vector = HalfVector.new(vector)

      rows =
        Memory
        |> active_memory_query(plan)
        |> where([memory], not is_nil(memory.embedding))
        |> order_by([memory],
          asc: fragment("? <=> ?", memory.embedding, ^query_vector),
          asc: memory.id
        )
        |> limit(^limit)
        |> select(
          [memory],
          {memory, fragment("1.0 - (? <=> ?)", memory.embedding, ^query_vector)}
        )
        |> repo().all()
        |> adapt_memory_rows(plan)

      {:ok, rows}
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_embedding_result}
    end
  end

  def vector(%QueryPlan{}, _limit, _embed_fn), do: {:error, :invalid_limit}

  def graph(%QueryPlan{entity_hints: []}, limit) when limit in 1..@max_limit,
    do: {:unavailable, :no_entity_hints}

  def graph(%QueryPlan{} = plan, limit) when limit in 1..@max_limit do
    seeds = graph_seeds(plan)

    if seeds == [] do
      {:unavailable, :no_graph_data}
    else
      nodes = traverse_graph(seeds, plan)

      observation_depths =
        nodes
        |> Enum.flat_map(fn {node, depth} ->
          Enum.map(node.source_observation_ids, &{&1, depth})
        end)
        |> Enum.reduce(%{}, fn {id, depth}, acc -> Map.update(acc, id, depth, &min(&1, depth)) end)

      ids =
        observation_depths
        |> Enum.sort_by(fn {id, depth} -> {depth, id} end)
        |> Enum.take(@graph_node_cap)
        |> Enum.map(&elem(&1, 0))

      durable_event_ids =
        Event
        |> exact_partition(plan)
        |> where([event], event.id in ^ids)
        |> order_by([event], asc: event.id)
        |> select([event], event.id)
        |> repo().all()

      matching_memory_sources =
        Evidence
        |> where([evidence], evidence.source_event_id in ^durable_event_ids)
        |> select([evidence], {evidence.memory_id, evidence.source_event_id})
        |> repo().all()
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

      durable_memory_rows =
        if map_size(matching_memory_sources) == 0 do
          []
        else
          matched_memory_ids = matching_memory_sources |> Map.keys() |> Enum.sort()

          Memory
          |> active_memory_query(plan)
          |> where([memory], memory.id in ^matched_memory_ids)
          |> order_by([memory], asc: memory.id)
          |> limit(^@graph_node_cap)
          |> select([memory], {memory, 1.0})
          |> repo().all()
          |> adapt_memory_rows(plan)
          |> Enum.map(fn {candidate, _score} ->
            depth =
              matching_memory_sources
              |> Map.fetch!(candidate.id)
              |> Enum.map(&Map.fetch!(observation_depths, &1))
              |> Enum.min()

            {candidate, 1.0 / (1 + depth)}
          end)
        end

      working_rows =
        if plan.include_working do
          ProjectedObservation
          |> exact_partition(plan)
          |> where([observation], observation.event_id in ^ids)
          |> order_by([observation], asc: observation.event_id)
          |> limit(^@graph_node_cap)
          |> repo().all()
          |> Enum.flat_map(fn observation ->
            refs = [%Adapters.SourceRef{type: :event, id: observation.event_id}]

            case Adapters.observation(%Adapters.ObservationRow{
                   observation: observation,
                   partition: partition(plan),
                   source_refs: refs
                 }) do
              {:ok, candidate} ->
                [{candidate, 1.0 / (1 + observation_depths[observation.event_id])}]

              {:error, _reason} ->
                []
            end
          end)
        else
          []
        end

      rows =
        (durable_memory_rows ++ working_rows)
        |> Enum.sort_by(fn {candidate, score} -> {-score, candidate.id} end)
        |> Enum.take(limit)

      {:ok, rows}
    end
  end

  def graph(%QueryPlan{}, _limit), do: {:error, :invalid_limit}

  defp fts_memories(plan, limit) do
    Memory
    |> active_memory_query(plan)
    |> where(
      [_memory],
      fragment("search_tsv @@ websearch_to_tsquery('english', ?)", ^plan.normalized_query)
    )
    |> order_by([memory],
      desc:
        fragment(
          "ts_rank(search_tsv, websearch_to_tsquery('english', ?))",
          ^plan.normalized_query
        ),
      asc: memory.id
    )
    |> limit(^limit)
    |> select(
      [memory],
      {memory,
       fragment("ts_rank(search_tsv, websearch_to_tsquery('english', ?))", ^plan.normalized_query)}
    )
    |> repo().all()
    |> adapt_memory_rows(plan)
  end

  defp fts_summaries(plan, limit) do
    query =
      from(summary in Summary,
        join: session in ProjectedSession,
        on:
          session.host_id == summary.host_id and session.session_id == summary.session_id and
            session.subject_id == summary.subject_id,
        where:
          session.host_id == ^plan.host_id and session.client_id == ^plan.client_id and
            session.scope == ^plan.scope and session.namespace == ^plan.namespace,
        where:
          fragment(
            "to_tsvector('simple', coalesce(?, '')) @@ websearch_to_tsquery('simple', ?)",
            summary.content,
            ^plan.normalized_query
          ),
        order_by: [
          desc:
            fragment(
              "ts_rank(to_tsvector('simple', coalesce(?, '')), websearch_to_tsquery('simple', ?))",
              summary.content,
              ^plan.normalized_query
            ),
          asc: summary.id
        ],
        limit: ^limit,
        select:
          {summary,
           fragment(
             "ts_rank(to_tsvector('simple', coalesce(?, '')), websearch_to_tsquery('simple', ?))",
             summary.content,
             ^plan.normalized_query
           )}
      )
      |> maybe_summary_project(plan.project)
      |> temporal_summary(plan.temporal_hints)

    rows = repo().all(query)
    summary_ids = Enum.map(rows, fn {summary, _score} -> summary.id end)

    refs_by_summary =
      SourceEvent
      |> join(:inner, [source], event in Event, on: event.id == source.event_id)
      |> where(
        [source, event],
        source.summary_id in ^summary_ids and source.host_id == ^plan.host_id and
          event.host_id == ^plan.host_id and event.client_id == ^plan.client_id and
          event.scope == ^plan.scope and event.namespace == ^plan.namespace
      )
      |> order_by([source, _event], asc: source.summary_id, asc: source.event_id)
      |> limit(^(max(length(summary_ids), 1) * 256))
      |> select([source, _event], {source.summary_id, source.event_id})
      |> repo().all()
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    Enum.flat_map(rows, fn {summary, score} ->
      refs =
        refs_by_summary
        |> Map.get(summary.id, [])
        |> Enum.take(256)
        |> Enum.map(&%Adapters.SourceRef{type: :event, id: &1})

      case Adapters.summary(%Adapters.SummaryRow{
             summary: summary,
             partition: partition(plan),
             source_refs: refs
           }) do
        {:ok, candidate} -> [{candidate, score}]
        {:error, _reason} -> []
      end
    end)
  end

  defp active_memory_query(query, plan) do
    query
    |> exact_partition(plan)
    |> where(
      [memory],
      is_nil(memory.deleted_at) and
        (is_nil(memory.expires_at) or memory.expires_at > ^DateTime.utc_now()) and
        memory.lifecycle_state not in ["superseded", "archived", "tombstoned"]
    )
    |> maybe_exclude_working(plan.include_working)
    |> maybe_memory_project(plan.project)
    |> apply_facets(plan.facets)
    |> temporal_memory(plan.temporal_hints)
  end

  defp exact_partition(query, plan) do
    where(
      query,
      [row],
      row.host_id == ^plan.host_id and row.client_id == ^plan.client_id and
        row.scope == ^plan.scope and row.namespace == ^plan.namespace
    )
  end

  defp maybe_memory_project(query, nil), do: query

  defp maybe_memory_project(query, project),
    do: where(query, [memory], fragment("?->>'project'", memory.metadata) == ^project)

  defp maybe_exclude_working(query, true), do: query

  defp maybe_exclude_working(query, false),
    do: where(query, [memory], memory.memory_type != "working")

  defp maybe_summary_project(query, nil), do: query

  defp maybe_summary_project(query, project),
    do: where(query, [summary, _session], summary.project == ^project)

  defp apply_facets(query, facets) do
    Enum.reduce(facets, query, fn %{"dimension" => dimension, "value" => value}, query ->
      where(
        query,
        [memory],
        fragment(
          "EXISTS (SELECT 1 FROM memory_facets AS facet WHERE facet.memory_id = ? AND facet.dimension = ? AND facet.value = ?)",
          memory.id,
          ^dimension,
          ^value
        )
      )
    end)
  end

  defp temporal_memory(query, nil), do: query
  defp temporal_memory(query, hints), do: temporal(query, hints, :inserted_at)
  defp temporal_summary(query, nil), do: query
  defp temporal_summary(query, hints), do: temporal(query, hints, :created_at)

  defp temporal(query, hints, field) do
    Enum.reduce(hints, query, fn
      {"after", value}, query ->
        where(query, [row, ...], field(row, ^field) >= ^parse_time(value))

      {"before", value}, query ->
        where(query, [row, ...], field(row, ^field) <= ^parse_time(value))

      {"at", value}, query ->
        where(query, [row, ...], field(row, ^field) == ^parse_time(value))
    end)
  end

  defp graph_seeds(plan) do
    plan.entity_hints
    |> Enum.flat_map(fn hint ->
      Node
      |> exact_partition(plan)
      |> where([node], ilike(node.name, ^hint))
      |> order_by([node], asc: node.id)
      |> limit(^@graph_node_cap)
      |> repo().all()
    end)
    |> Enum.uniq_by(& &1.id)
    |> Enum.take(@graph_node_cap)
    |> Enum.map(&{&1, 0})
  end

  defp traverse_graph(seeds, plan), do: traverse_graph(seeds, seeds, plan, @graph_depth)
  defp traverse_graph(_frontier, visited, _plan, 0), do: visited
  defp traverse_graph([], visited, _plan, _depth), do: visited

  defp traverse_graph(frontier, visited, plan, depth) do
    frontier_ids = Enum.map(frontier, fn {node, _depth} -> node.id end)
    visited_ids = MapSet.new(visited, fn {node, _depth} -> node.id end)

    edges =
      Edge
      |> exact_partition(plan)
      |> where([edge], edge.source_id in ^frontier_ids or edge.target_id in ^frontier_ids)
      |> order_by([edge], asc: edge.id)
      |> limit(^@graph_edge_cap)
      |> repo().all()

    new_ids =
      edges
      |> Enum.flat_map(&[&1.source_id, &1.target_id])
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(visited_ids, &1))
      |> Enum.sort()
      |> Enum.take(max(@graph_node_cap - length(visited), 0))

    new_nodes =
      Node
      |> exact_partition(plan)
      |> where([node], node.id in ^new_ids)
      |> order_by([node], asc: node.id)
      |> limit(^@graph_node_cap)
      |> repo().all()
      |> Enum.map(&{&1, @graph_depth - depth + 1})

    traverse_graph(new_nodes, visited ++ new_nodes, plan, depth - 1)
  end

  defp adapt_memory_rows([], _plan), do: []

  defp adapt_memory_rows(rows, plan) do
    memory_ids = Enum.map(rows, fn {memory, _score} -> memory.id end)
    evidence_fields = Evidence.__schema__(:fields)

    lessons_by_memory =
      Lesson
      |> where([lesson], lesson.memory_id in ^memory_ids and lesson.status == "active")
      |> repo().all()
      |> Map.new(&{&1.memory_id, &1})

    ranked_evidence =
      from(evidence in Evidence,
        where: evidence.memory_id in ^memory_ids,
        windows: [
          per_memory: [
            partition_by: evidence.memory_id,
            order_by: [asc: evidence.created_at, asc: evidence.id]
          ]
        ],
        select:
          merge(map(evidence, ^evidence_fields), %{position: over(row_number(), :per_memory)})
      )

    evidence_by_memory =
      from(row in subquery(ranked_evidence),
        where: row.position <= 256,
        order_by: [asc: row.memory_id, asc: row.position],
        select: map(row, ^evidence_fields)
      )
      |> repo().all()
      |> Enum.map(&decode_evidence/1)
      |> Enum.group_by(& &1.memory_id)

    context = evidence_context(evidence_by_memory, plan)

    Enum.flat_map(rows, fn {memory, score} ->
      evidence = Map.get(evidence_by_memory, memory.id, [])

      verified =
        evidence |> Enum.map(&evidence_refs(&1, memory, context)) |> Enum.reject(&(&1 == []))

      refs = verified |> List.flatten() |> Enum.uniq() |> Enum.take(256)

      memory =
        %{memory | metadata: Map.put(memory.metadata || %{}, "evidence_count", length(verified))}

      adapted =
        case Map.fetch(lessons_by_memory, memory.id) do
          {:ok, lesson} ->
            Adapters.lesson(%Adapters.LessonRow{
              lesson: lesson,
              memory: memory,
              partition: partition(memory),
              source_refs: refs,
              evidence_ids: Enum.map(evidence, & &1.id)
            })

          :error ->
            row = %Adapters.MemoryRow{
              memory: memory,
              partition: partition(memory),
              source_refs: refs
            }

            if memory.metadata["kind"] == "crystal",
              do: Adapters.crystal(row),
              else: Adapters.memory(row)
        end

      case adapted do
        {:ok, candidate} -> [{candidate, score}]
        {:error, _reason} -> []
      end
    end)
  end

  defp evidence_context(evidence_by_memory, plan) do
    evidence = evidence_by_memory |> Map.values() |> List.flatten()
    event_ids = compact_ids(evidence, :source_event_id)
    summary_ids = compact_ids(evidence, :source_summary_id)
    observation_ids = compact_ids(evidence, :source_observation_id)
    request_ids = compact_ids(evidence, :source_request_id)

    valid_events =
      Event
      |> exact_partition(plan)
      |> where([event], event.id in ^event_ids)
      |> select([event], event.id)
      |> repo().all()
      |> MapSet.new()

    valid_summaries =
      from(summary in Summary,
        join: session in ProjectedSession,
        on:
          session.host_id == summary.host_id and session.session_id == summary.session_id and
            session.subject_id == summary.subject_id,
        where:
          summary.id in ^summary_ids and session.host_id == ^plan.host_id and
            session.client_id == ^plan.client_id and session.scope == ^plan.scope and
            session.namespace == ^plan.namespace,
        select: summary.id
      )
      |> repo().all()
      |> MapSet.new()

    valid_requests =
      RememberRequest
      |> where([request], request.id in ^request_ids)
      |> select([request], {request.id, request.memory_id})
      |> repo().all()
      |> MapSet.new()

    valid_observations =
      Observation
      |> where([observation], observation.id in ^observation_ids)
      |> select([observation], observation.id)
      |> repo().all()
      |> MapSet.new()

    %{
      events: valid_events,
      summaries: valid_summaries,
      observations: valid_observations,
      requests: valid_requests
    }
  end

  defp evidence_refs(%Evidence{source_event_id: id}, _memory, context) when not is_nil(id) do
    if MapSet.member?(context.events, id),
      do: [%Adapters.SourceRef{type: :event, id: id}],
      else: []
  end

  defp evidence_refs(%Evidence{source_observation_id: id, host_id: host_id}, memory, context)
       when not is_nil(id) do
    if host_id == memory.host_id and MapSet.member?(context.observations, id),
      do: [%Adapters.SourceRef{type: :observation, id: id}],
      else: []
  end

  defp evidence_refs(%Evidence{source_summary_id: id}, _memory, context) when not is_nil(id) do
    if MapSet.member?(context.summaries, id),
      do: [%Adapters.SourceRef{type: :summary, id: id}],
      else: []
  end

  defp evidence_refs(%Evidence{source_request_id: id}, memory, context) when not is_nil(id) do
    if MapSet.member?(context.requests, {id, memory.id}),
      do: [%Adapters.SourceRef{type: :request, id: id}],
      else: []
  end

  defp evidence_refs(%Evidence{source_session_id: session_id}, _memory, _context)
       when not is_nil(session_id),
       do: []

  defp evidence_refs(%Evidence{}, _memory, _context), do: []

  defp compact_ids(rows, field),
    do: rows |> Enum.map(&Map.fetch!(&1, field)) |> Enum.reject(&is_nil/1) |> Enum.uniq()

  defp decode_evidence(row) do
    [
      :id,
      :memory_id,
      :source_event_id,
      :source_observation_id,
      :source_summary_id,
      :source_request_id
    ]
    |> Enum.reduce(row, fn field, decoded ->
      case Map.get(decoded, field) do
        value when is_binary(value) -> Map.put(decoded, field, Ecto.UUID.load!(value))
        _other -> decoded
      end
    end)
    |> then(&struct!(Evidence, &1))
  end

  defp partition(value), do: Map.take(value, [:host_id, :client_id, :scope, :namespace])
  defp parse_time(value), do: value |> DateTime.from_iso8601() |> elem(1)
  defp kind_order(:memory), do: 0
  defp kind_order(:lesson), do: 1
  defp kind_order(:crystal), do: 2
  defp kind_order(:summary), do: 3
  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)
end

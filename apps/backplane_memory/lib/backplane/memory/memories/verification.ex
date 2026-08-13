defmodule Backplane.Memory.Memories.Verification do
  @moduledoc false

  import Ecto.Query

  alias Backplane.Memory.Events.Event
  alias Backplane.Memory.Memories.{Evidence, Memory, Relation, RelationEvidence, RememberRequest}
  alias Backplane.Memory.Projections.{ProjectedObservation, ProjectedSession}
  alias Backplane.Memory.Summaries.{SourceEvent, Summary}

  @evidence_limit 100
  @relation_limit 100
  @audit_limit 100
  @source_limit 200
  @graph_node_limit 100
  @graph_query_timeout 2_000
  @depth 2

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)

  def build(memory, partition) do
    evidence = evidence(memory.id, partition)
    relations = relations(memory.id, partition)
    summaries = summaries(evidence, partition)
    source_events = source_events(evidence, summaries.links, partition)
    observations = observations(evidence, partition)
    requests = requests(evidence, memory.id)
    sessions = sessions(evidence, partition)
    audit = audit(memory.id)

    evidence_views = Enum.map(evidence, &evidence_view/1)
    evidence_total = evidence_total(memory.id, partition)
    relation_total = relation_total(memory.id, partition)
    audit_total = audit_total(memory.id)

    contradictory_evidence_count =
      Enum.count(evidence_views, &(&1.evidence_kind == "contradicts"))

    graph = graph(memory, partition)

    %{
      memory: memory,
      memory_version: memory.updated_at,
      lifecycle_state: memory.lifecycle_state,
      superseded_by: memory.superseded_by,
      evidence: evidence_views,
      evidence_count: evidence_total,
      access_count: memory.access_count,
      application_count: memory.application_count,
      supporting_count:
        Enum.count(evidence_views, &(&1.evidence_kind in ~w(supports derives confirms applies))),
      contradictory_evidence_count: contradictory_evidence_count,
      # Compatibility alias. New callers should use contradictory_evidence_count so evidence
      # cannot be confused with confirmed contradiction relations.
      contradiction_count: contradictory_evidence_count,
      source_diversity:
        evidence_views |> Enum.map(&evidence_identity/1) |> MapSet.new() |> MapSet.size(),
      relations: relations,
      contradiction_relation_count:
        Enum.count(
          relations,
          &(&1.classification == "contradiction" and &1.status == "confirmed")
        ),
      successors: successors(relations, memory.id),
      graph: graph,
      summaries: summaries.nodes,
      summary_event_links: summaries.links,
      source_events: source_events,
      observations: observations,
      requests: requests,
      sessions: sessions,
      provenance_roots:
        provenance_roots(
          evidence_views,
          summaries.nodes,
          source_events,
          observations,
          requests,
          sessions
        ),
      audit: audit,
      audit_decisions: Enum.filter(audit, &String.starts_with?(&1.operation, "memory_relation.")),
      processing_versions: %{
        embedding_model: memory.embedding_model,
        summaries:
          summaries.nodes |> Enum.map(& &1.processing_version) |> Enum.uniq() |> Enum.sort(),
        event_schema_versions:
          source_events |> Enum.map(& &1.processing_version) |> Enum.uniq() |> Enum.sort(),
        classifiers:
          relations
          |> Enum.map(&%{model: &1.classifier_model, version: &1.classifier_version})
          |> Enum.uniq()
          |> Enum.sort_by(&{&1.model, &1.version})
      },
      bounds: %{
        depth: @depth,
        evidence_limit: @evidence_limit,
        relation_limit: @relation_limit,
        source_limit: @source_limit,
        audit_limit: @audit_limit,
        cycle_safe: true,
        evidence: page_counts(evidence_total, length(evidence)),
        relations: %{
          total_count: relation_total,
          returned_count: length(relations),
          truncated: relation_total > length(relations)
        },
        source_events: %{
          total_count: length(source_events),
          returned_count: length(source_events),
          truncated: false
        },
        audit: page_counts(audit_total, length(audit))
      }
    }
  end

  defp evidence(memory_id, partition) do
    repo().all(
      from(e in Evidence,
        where: e.memory_id == ^memory_id and e.host_id == ^partition.host_id,
        order_by: [asc: e.created_at, asc: e.id],
        limit: ^@evidence_limit
      )
    )
  end

  defp relations(memory_id, partition) do
    rows =
      repo().all(
        from(r in Relation,
          join: source in Memory,
          on: source.id == r.source_memory_id,
          join: target in Memory,
          on: target.id == r.target_memory_id,
          where: r.source_memory_id == ^memory_id or r.target_memory_id == ^memory_id,
          where:
            source.host_id == ^partition.host_id and
              fragment("? IS NOT DISTINCT FROM ?", source.client_id, ^partition.client_id) and
              source.scope == ^partition.scope and source.namespace == ^partition.namespace and
              target.host_id == ^partition.host_id and
              fragment("? IS NOT DISTINCT FROM ?", target.client_id, ^partition.client_id) and
              target.scope == ^partition.scope and target.namespace == ^partition.namespace,
          order_by: [asc: r.created_at, asc: r.id],
          limit: ^@relation_limit,
          select:
            {r, source.lifecycle_state, source.superseded_by, target.lifecycle_state,
             target.superseded_by}
        )
      )

    relation_ids = Enum.map(rows, fn {relation, _, _, _, _} -> relation.id end)

    joined_evidence =
      if relation_ids == [] do
        %{}
      else
        RelationEvidence
        |> where([join], join.relation_id in ^relation_ids)
        |> order_by([join], asc: join.relation_id, asc: join.role, asc: join.evidence_id)
        |> limit(^(@relation_limit * 2))
        |> select([join], {join.relation_id, %{evidence_id: join.evidence_id, role: join.role}})
        |> repo().all()
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      end

    Enum.map(rows, fn {relation, source_state, source_successor, target_state, target_successor} ->
      relation
      |> Map.from_struct()
      |> Map.drop([:__meta__])
      |> Map.put(:evidence, Map.get(joined_evidence, relation.id, []))
      |> Map.put(:source_lifecycle, %{state: source_state, superseded_by: source_successor})
      |> Map.put(:target_lifecycle, %{state: target_state, superseded_by: target_successor})
    end)
  end

  defp summaries(evidence, partition) do
    ids = evidence |> Enum.map(& &1.source_summary_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    if ids == [] do
      %{nodes: [], links: []}
    else
      nodes =
        repo().all(
          from(s in Summary,
            where: s.id in ^ids and s.host_id == ^partition.host_id,
            order_by: [asc: s.created_at, asc: s.id],
            limit: ^@source_limit,
            select: %{
              id: s.id,
              session_id: s.session_id,
              subject_id: s.subject_id,
              host_id: s.host_id,
              agent_id: s.agent_id,
              project: s.project,
              observation_count: s.observation_count,
              processing_version: s.processing_version,
              input_revision: s.input_revision,
              output_revision: s.output_revision,
              source_complete: s.source_complete,
              source_gap_count: s.source_gap_count,
              source_gaps: s.source_gaps,
              superseded_at: s.superseded_at,
              superseded_by_input_revision: s.superseded_by_input_revision
            }
          )
        )

      node_ids = Enum.map(nodes, & &1.id)
      links = summary_links(node_ids, partition)
      safe_ids = complete_summary_partitions(node_ids, links)

      %{
        nodes: Enum.filter(nodes, &MapSet.member?(safe_ids, &1.id)),
        links: Enum.filter(links, &MapSet.member?(safe_ids, &1.summary_id))
      }
    end
  end

  defp summary_links([], _partition), do: []

  defp summary_links(summary_ids, partition) do
    repo().all(
      from(link in SourceEvent,
        join: event in Event,
        on: event.id == link.event_id,
        where: link.summary_id in ^summary_ids and link.host_id == ^partition.host_id,
        where:
          event.host_id == ^partition.host_id and
            fragment("? IS NOT DISTINCT FROM ?", event.client_id, ^partition.client_id) and
            event.scope == ^partition.scope and event.namespace == ^partition.namespace,
        order_by: [asc: link.summary_id, asc: event.sequence, asc: link.event_id],
        limit: ^@source_limit,
        select: %{
          summary_id: link.summary_id,
          event_id: link.event_id,
          host_id: link.host_id,
          session_id: link.session_id
        }
      )
    )
  end

  defp complete_summary_partitions([], _links), do: MapSet.new()

  defp complete_summary_partitions(summary_ids, links) do
    total_counts =
      repo().all(
        from(link in SourceEvent,
          where: link.summary_id in ^summary_ids,
          group_by: link.summary_id,
          select: {link.summary_id, count(link.event_id)}
        )
      )
      |> Map.new()

    visible_counts = Enum.frequencies_by(links, & &1.summary_id)

    summary_ids
    |> Enum.filter(fn id ->
      Map.get(total_counts, id, 0) > 0 and total_counts[id] == visible_counts[id]
    end)
    |> MapSet.new()
  end

  defp source_events(evidence, links, partition) do
    ids =
      evidence
      |> Enum.map(& &1.source_event_id)
      |> Enum.concat(Enum.map(links, & &1.event_id))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.take(@source_limit)

    repo().all(
      from(event in Event,
        where: event.id in ^ids,
        where:
          event.host_id == ^partition.host_id and
            fragment("? IS NOT DISTINCT FROM ?", event.client_id, ^partition.client_id) and
            event.scope == ^partition.scope and event.namespace == ^partition.namespace,
        order_by: [asc: event.occurred_at, asc: event.sequence, asc: event.id],
        limit: ^@source_limit,
        select: %{
          id: event.id,
          stream_id: event.stream_id,
          sequence: event.sequence,
          event_type: event.event_type,
          host_id: event.host_id,
          client_id: event.client_id,
          scope: event.scope,
          namespace: event.namespace,
          session_id: event.session_id,
          project: event.project,
          agent_id: event.agent_id,
          processing_version: event.schema_version,
          occurred_at: event.occurred_at,
          causation_id: event.causation_id
        }
      )
    )
  end

  defp observations(evidence, partition) do
    ids =
      evidence |> Enum.map(& &1.source_observation_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    repo().all(
      from(observation in ProjectedObservation,
        where: observation.event_id in ^ids,
        where:
          observation.host_id == ^partition.host_id and
            fragment("? IS NOT DISTINCT FROM ?", observation.client_id, ^partition.client_id) and
            observation.scope == ^partition.scope and
            observation.namespace == ^partition.namespace,
        order_by: [asc: observation.occurred_at, asc: observation.event_id],
        limit: ^@source_limit,
        select: %{
          event_id: observation.event_id,
          host_id: observation.host_id,
          client_id: observation.client_id,
          scope: observation.scope,
          namespace: observation.namespace,
          session_id: observation.session_id,
          processing_version: observation.processing_version,
          input_revision: observation.input_revision,
          occurred_at: observation.occurred_at
        }
      )
    )
  end

  defp requests(evidence, memory_id) do
    ids = evidence |> Enum.map(& &1.source_request_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    repo().all(
      from(request in RememberRequest,
        where: request.id in ^ids and request.memory_id == ^memory_id,
        order_by: [asc: request.inserted_at, asc: request.id],
        limit: ^@source_limit,
        select: %{
          id: request.id,
          memory_id: request.memory_id,
          idempotency_scope: request.idempotency_scope,
          request_hash: request.request_hash,
          inserted_at: request.inserted_at
        }
      )
    )
  end

  defp audit(memory_id) do
    repo().all(
      from(row in "memory_audit_log",
        where:
          fragment(
            "CASE jsonb_typeof(?) WHEN 'array' THEN ? @> jsonb_build_array(?::text) WHEN 'object' THEN EXISTS (SELECT 1 FROM jsonb_each_text(?) AS target(key, value) WHERE target.value = ?) ELSE false END",
            row.target_ids,
            row.target_ids,
            ^memory_id,
            row.target_ids,
            ^memory_id
          ),
        order_by: [desc: row.created_at, desc: row.id],
        limit: ^@audit_limit,
        select: %{
          id: row.id,
          operation: row.operation,
          actor: row.actor,
          target_ids: row.target_ids,
          metadata: row.metadata,
          created_at: row.created_at
        }
      )
    )
  end

  defp successors(relations, memory_id) do
    relations
    |> Enum.filter(&(&1.status == "confirmed" and &1.classification == "temporal_replacement"))
    |> Enum.flat_map(fn relation ->
      cond do
        relation.source_memory_id == memory_id ->
          [
            %{
              memory_id: relation.target_memory_id,
              relation_id: relation.id,
              direction: "successor"
            }
          ]

        relation.target_memory_id == memory_id ->
          [
            %{
              memory_id: relation.source_memory_id,
              relation_id: relation.id,
              direction: "predecessor"
            }
          ]

        true ->
          []
      end
    end)
    |> Enum.uniq_by(&{&1.memory_id, &1.relation_id, &1.direction})
  end

  defp provenance_roots(evidence, summaries, events, observations, requests, sessions) do
    available = %{
      "summary" => MapSet.new(summaries, & &1.id),
      "event" => MapSet.new(events, & &1.id),
      "observation" => MapSet.new(observations, & &1.event_id),
      "request" => MapSet.new(requests, & &1.id),
      "session" => MapSet.new(sessions, &"#{&1.host_id}:#{&1.session_id}")
    }

    Enum.map(evidence, fn item ->
      resolved =
        MapSet.member?(Map.get(available, item.source_type, MapSet.new()), item.source_id)

      %{
        evidence_id: item.id,
        source_type: item.source_type,
        source_id: item.source_id,
        resolved: resolved
      }
    end)
  end

  defp evidence_view(evidence) do
    {source_type, source_id} = evidence_source(evidence)

    evidence
    |> Map.take([
      :id,
      :memory_id,
      :session_id,
      :agent_id,
      :host_id,
      :evidence_kind,
      :support_score,
      :excerpt,
      :created_at
    ])
    |> Map.merge(%{source_type: source_type, source_id: source_id})
  end

  defp evidence_source(%Evidence{source_event_id: id}) when not is_nil(id), do: {"event", id}

  defp evidence_source(%Evidence{source_observation_id: id}) when not is_nil(id),
    do: {"observation", id}

  defp evidence_source(%Evidence{source_summary_id: id}) when not is_nil(id), do: {"summary", id}
  defp evidence_source(%Evidence{source_request_id: id}) when not is_nil(id), do: {"request", id}

  defp evidence_source(%Evidence{host_id: host, source_session_id: session}),
    do: {"session", "#{host}:#{session}"}

  defp evidence_identity(%{source_type: "session"} = evidence),
    do: {:provenance, evidence.source_id, evidence.host_id || "", evidence.agent_id || ""}

  defp evidence_identity(%{session_id: session_id} = evidence) when not is_nil(session_id),
    do: {:provenance, session_id, evidence.host_id || "", evidence.agent_id || ""}

  defp evidence_identity(evidence)
       when not is_nil(evidence.host_id) or not is_nil(evidence.agent_id),
       do: {:provenance, nil, evidence.host_id || "", evidence.agent_id || ""}

  defp evidence_identity(evidence), do: {:source, evidence.source_type, evidence.source_id}

  defp graph(memory, partition) do
    case graph_universe(memory.id, partition) do
      {:ok, universe} -> graph_complete(memory, partition, universe)
      {:error, :verification_timeout} -> timed_out_graph(memory)
    end
  end

  defp graph_complete(memory, partition, universe) do
    memory_ids =
      universe.ids
      |> Enum.reject(&(&1 == memory.id))
      |> Enum.take(@graph_node_limit - 1)
      |> then(&MapSet.new([memory.id | &1]))

    omitted_ids =
      universe.ids
      |> Enum.reject(&MapSet.member?(memory_ids, &1))
      |> Enum.take(@graph_node_limit)

    {links, edge_total} = graph_edges(memory_ids, universe.edge_total, partition)
    related_ids = memory_ids |> MapSet.delete(memory.id) |> MapSet.to_list() |> Enum.sort()

    nodes =
      repo().all(
        from(m in Memory,
          where: m.id in ^related_ids,
          where:
            m.host_id == ^partition.host_id and
              fragment("? IS NOT DISTINCT FROM ?", m.client_id, ^partition.client_id) and
              m.scope == ^partition.scope and m.namespace == ^partition.namespace,
          order_by: [asc: m.id],
          limit: ^@relation_limit,
          select: %{
            type: "memory",
            id: m.id,
            memory_type: m.memory_type,
            lifecycle_state: m.lifecycle_state,
            superseded_by: m.superseded_by,
            version: m.updated_at,
            embedding_model: m.embedding_model
          }
        )
      )

    inherited_evidence =
      repo().all(
        from(e in Evidence,
          where: e.memory_id in ^related_ids and e.host_id == ^partition.host_id,
          order_by: [asc: e.memory_id, asc: e.created_at, asc: e.id],
          limit: ^@evidence_limit
        )
      )
      |> Enum.map(&evidence_view/1)

    inherited_evidence_total = inherited_evidence_total(related_ids, partition)
    inherited_sources = resolve_sources(inherited_evidence, partition, related_ids)
    relation_evidence = relation_evidence_for_links(links)
    relation_evidence_total = relation_evidence_total(links)
    related_audit = related_audit(related_ids)
    related_audit_total = related_audit_total(related_ids)

    %{
      root_memory_id: memory.id,
      depth: @depth,
      nodes: [
        %{
          type: "memory",
          id: memory.id,
          lifecycle_state: memory.lifecycle_state,
          version: memory.updated_at
        }
        | nodes
      ],
      links: links,
      relation_evidence: relation_evidence,
      inherited_evidence: inherited_evidence,
      inherited_sources: inherited_sources,
      audit_decisions: related_audit,
      visited_memory_ids: memory_ids |> MapSet.to_list() |> Enum.sort(),
      cycle_safe: true,
      bounds: %{
        nodes: page_counts(universe.total, MapSet.size(memory_ids)),
        edges: page_counts(edge_total, length(links)),
        relation_evidence: page_counts(relation_evidence_total, length(relation_evidence)),
        inherited_evidence: page_counts(inherited_evidence_total, length(inherited_evidence)),
        audit_decisions: page_counts(related_audit_total, length(related_audit)),
        omitted_memory_count: universe.total - MapSet.size(memory_ids),
        omitted_memory_ids: omitted_ids
      }
    }
  end

  defp graph_universe(root_id, partition) do
    ctes = """
    WITH level1 AS (
      SELECT CASE WHEN relation.source_memory_id = walk.memory_id
                  THEN relation.target_memory_id ELSE relation.source_memory_id END AS memory_id
      FROM (SELECT $1::text::uuid AS memory_id) walk
      JOIN bpm_memory_relations relation
        ON relation.source_memory_id = walk.memory_id OR relation.target_memory_id = walk.memory_id
      JOIN bpm_memories source ON source.id = relation.source_memory_id
      JOIN bpm_memories target ON target.id = relation.target_memory_id
      WHERE source.host_id = $2 AND source.client_id IS NOT DISTINCT FROM $3
        AND source.scope = $4 AND source.namespace = $5
        AND target.host_id = $2 AND target.client_id IS NOT DISTINCT FROM $3
        AND target.scope = $4 AND target.namespace = $5
      ORDER BY memory_id
      LIMIT #{@graph_node_limit * 2}
    ), level2 AS (
      SELECT CASE WHEN relation.source_memory_id = level1.memory_id
                  THEN relation.target_memory_id ELSE relation.source_memory_id END AS memory_id
      FROM level1
      JOIN bpm_memory_relations relation
        ON relation.source_memory_id = level1.memory_id OR relation.target_memory_id = level1.memory_id
      JOIN bpm_memories source ON source.id = relation.source_memory_id
      JOIN bpm_memories target ON target.id = relation.target_memory_id
      WHERE source.host_id = $2 AND source.client_id IS NOT DISTINCT FROM $3
        AND source.scope = $4 AND source.namespace = $5
        AND target.host_id = $2 AND target.client_id IS NOT DISTINCT FROM $3
        AND target.scope = $4 AND target.namespace = $5
      ORDER BY memory_id
      LIMIT #{@graph_node_limit * 2}
    ), universe AS (
      SELECT $1::text::uuid AS memory_id UNION SELECT memory_id FROM level1 UNION SELECT memory_id FROM level2
    )
    """

    params = [
      root_id,
      partition.host_id,
      partition.client_id,
      partition.scope,
      partition.namespace
    ]

    count_ctes =
      Regex.replace(
        ~r/\s+ORDER BY memory_id\s+LIMIT #{@graph_node_limit * 2}/,
        ctes,
        ""
      )

    with {:ok, %{rows: [[total, edge_total]]}} <-
           graph_query(
             count_ctes <>
               "SELECT (SELECT count(*) FROM universe), (SELECT count(*) FROM bpm_memory_relations relation WHERE relation.source_memory_id IN (SELECT memory_id FROM universe) AND relation.target_memory_id IN (SELECT memory_id FROM universe))",
             params
           ),
         {:ok, %{rows: id_rows}} <-
           graph_query(
             ctes <>
               "SELECT memory_id::text FROM universe ORDER BY CASE WHEN memory_id = $1::text::uuid THEN 0 ELSE 1 END, memory_id::text LIMIT #{@graph_node_limit * 2}",
             params
           ) do
      {:ok, %{total: total, ids: List.flatten(id_rows), edge_total: edge_total}}
    end
  end

  defp graph_query(sql, params) do
    query =
      if Mix.env() == :test do
        Application.get_env(:backplane_memory, :verification_graph_query, &repo().query/3)
      else
        &repo().query/3
      end

    case query.(sql, params, timeout: @graph_query_timeout) do
      {:ok, result} -> {:ok, result}
      {:error, _reason} -> {:error, :verification_timeout}
    end
  rescue
    DBConnection.ConnectionError -> {:error, :verification_timeout}
    Postgrex.Error -> {:error, :verification_timeout}
  catch
    :exit, _reason -> {:error, :verification_timeout}
  end

  defp timed_out_graph(memory) do
    %{
      root_memory_id: memory.id,
      depth: @depth,
      nodes: [],
      links: [],
      relation_evidence: [],
      inherited_evidence: [],
      inherited_sources: %{nodes: [], summary_event_links: [], roots: []},
      audit_decisions: [],
      visited_memory_ids: [memory.id],
      cycle_safe: true,
      status: "timed_out",
      incomplete: true,
      bounds: %{
        nodes: %{total_count: nil, returned_count: 0, truncated: true},
        edges: %{total_count: nil, returned_count: 0, truncated: true},
        relation_evidence: %{total_count: nil, returned_count: 0, truncated: true},
        inherited_evidence: %{total_count: nil, returned_count: 0, truncated: true},
        audit_decisions: %{total_count: nil, returned_count: 0, truncated: true},
        omitted_memory_count: nil,
        omitted_memory_ids: []
      }
    }
  end

  defp graph_edges(memory_ids, edge_total, partition) do
    returned_ids = MapSet.to_list(memory_ids)

    links =
      graph_edge_query(returned_ids, partition)
      |> order_by([r, _source, _target], asc: r.created_at, asc: r.id)
      |> limit(^@relation_limit)
      |> repo().all()
      |> Enum.map(&relation_link/1)

    {links, edge_total}
  end

  defp graph_edge_query(ids, partition) do
    from(r in Relation,
      join: source in Memory,
      on: source.id == r.source_memory_id,
      join: target in Memory,
      on: target.id == r.target_memory_id,
      where: r.source_memory_id in ^ids and r.target_memory_id in ^ids,
      where:
        source.host_id == ^partition.host_id and
          fragment("? IS NOT DISTINCT FROM ?", source.client_id, ^partition.client_id) and
          source.scope == ^partition.scope and source.namespace == ^partition.namespace and
          target.host_id == ^partition.host_id and
          fragment("? IS NOT DISTINCT FROM ?", target.client_id, ^partition.client_id) and
          target.scope == ^partition.scope and target.namespace == ^partition.namespace
    )
  end

  defp relation_link(relation) do
    %{
      type: "memory_relation",
      id: relation.id,
      source_id: relation.source_memory_id,
      target_id: relation.target_memory_id,
      classification: relation.classification,
      status: relation.status,
      classifier_model: relation.classifier_model,
      classifier_version: relation.classifier_version,
      input_revision: relation.input_revision
    }
  end

  defp resolve_sources(evidence_views, partition, allowed_memory_ids) do
    event_ids = source_ids(evidence_views, "event")
    observation_ids = source_ids(evidence_views, "observation")
    summary_ids = source_ids(evidence_views, "summary")
    request_ids = source_ids(evidence_views, "request")

    events =
      repo().all(
        from(event in Event,
          where: event.id in ^event_ids,
          where:
            event.host_id == ^partition.host_id and
              fragment("? IS NOT DISTINCT FROM ?", event.client_id, ^partition.client_id) and
              event.scope == ^partition.scope and event.namespace == ^partition.namespace,
          order_by: [asc: event.id],
          limit: ^@source_limit,
          select: %{type: "event", id: event.id, processing_version: event.schema_version}
        )
      )

    observations =
      repo().all(
        from(obs in ProjectedObservation,
          where: obs.event_id in ^observation_ids,
          where:
            obs.host_id == ^partition.host_id and
              fragment("? IS NOT DISTINCT FROM ?", obs.client_id, ^partition.client_id) and
              obs.scope == ^partition.scope and obs.namespace == ^partition.namespace,
          order_by: [asc: obs.event_id],
          limit: ^@source_limit,
          select: %{
            type: "observation",
            id: obs.event_id,
            processing_version: obs.processing_version,
            input_revision: obs.input_revision
          }
        )
      )

    summaries =
      repo().all(
        from(summary in Summary,
          join: session in ProjectedSession,
          on: session.subject_id == summary.subject_id,
          where: summary.id in ^summary_ids and summary.host_id == ^partition.host_id,
          where:
            session.host_id == ^partition.host_id and
              fragment("? IS NOT DISTINCT FROM ?", session.client_id, ^partition.client_id) and
              session.scope == ^partition.scope and session.namespace == ^partition.namespace and
              session.session_id == summary.session_id and session.project == summary.project,
          order_by: [asc: summary.id],
          limit: ^@source_limit,
          select: %{
            type: "summary",
            id: summary.id,
            processing_version: summary.processing_version,
            input_revision: summary.input_revision,
            output_revision: summary.output_revision,
            source_complete: summary.source_complete,
            source_gap_count: summary.source_gap_count,
            source_gaps: summary.source_gaps
          }
        )
      )

    requests =
      repo().all(
        from(request in RememberRequest,
          where: request.id in ^request_ids and request.memory_id in ^allowed_memory_ids,
          order_by: [asc: request.id],
          limit: ^@source_limit,
          select: %{type: "request", id: request.id, memory_id: request.memory_id}
        )
      )

    session_ids =
      evidence_views
      |> Enum.filter(&(&1.source_type == "session"))
      |> Enum.map(&session_identity(&1, partition.host_id))
      |> Enum.reject(&is_nil/1)

    sessions =
      repo().all(
        from(session in ProjectedSession,
          where: session.session_id in ^session_ids and session.host_id == ^partition.host_id,
          where:
            fragment("? IS NOT DISTINCT FROM ?", session.client_id, ^partition.client_id) and
              session.scope == ^partition.scope and session.namespace == ^partition.namespace,
          order_by: [asc: session.subject_id],
          limit: ^@source_limit,
          select: %{
            type: "session",
            id: session.subject_id,
            session_id: session.session_id,
            processing_version: session.processing_version,
            input_revision: session.input_revision,
            source_complete: session.gap_count == 0,
            source_gap_count: session.gap_count
          }
        )
      )

    summary_ids = Enum.map(summaries, & &1.id)
    summary_links = summary_links(summary_ids, partition)
    safe_summary_ids = complete_summary_partitions(summary_ids, summary_links)
    summaries = Enum.filter(summaries, &MapSet.member?(safe_summary_ids, &1.id))
    summary_links = Enum.filter(summary_links, &MapSet.member?(safe_summary_ids, &1.summary_id))
    summary_events = source_events([], summary_links, partition)

    %{
      nodes: events ++ observations ++ summaries ++ requests ++ sessions ++ summary_events,
      summary_event_links: summary_links,
      roots:
        root_resolution(
          evidence_views,
          events,
          observations,
          summaries,
          requests,
          sessions,
          partition.host_id
        )
    }
  end

  defp source_ids(evidence, type),
    do:
      evidence
      |> Enum.filter(&(&1.source_type == type))
      |> Enum.map(& &1.source_id)
      |> Enum.uniq()

  defp root_resolution(evidence, events, observations, summaries, requests, sessions, host_id) do
    available = %{
      "event" => MapSet.new(events, & &1.id),
      "observation" => MapSet.new(observations, & &1.id),
      "summary" => MapSet.new(summaries, & &1.id),
      "request" => MapSet.new(requests, & &1.id),
      "session" => MapSet.new(sessions, & &1.session_id)
    }

    Enum.map(evidence, fn item ->
      source_id =
        if item.source_type == "session",
          do: session_identity(item, host_id),
          else: item.source_id

      %{
        evidence_id: item.id,
        source_type: item.source_type,
        source_id: item.source_id,
        resolved: MapSet.member?(available[item.source_type] || MapSet.new(), source_id)
      }
    end)
  end

  defp session_identity(item, host_id) do
    prefix = host_id <> ":"

    if String.starts_with?(item.source_id, prefix),
      do: String.replace_prefix(item.source_id, prefix, ""),
      else: nil
  end

  defp relation_evidence_for_links(links) do
    ids = Enum.map(links, & &1.id)

    repo().all(
      from(join in RelationEvidence,
        where: join.relation_id in ^ids,
        order_by: [asc: join.relation_id, asc: join.role, asc: join.evidence_id],
        limit: ^(@relation_limit * 2),
        select: %{relation_id: join.relation_id, evidence_id: join.evidence_id, role: join.role}
      )
    )
  end

  defp relation_evidence_total(links) do
    ids = Enum.map(links, & &1.id)
    repo().aggregate(from(join in RelationEvidence, where: join.relation_id in ^ids), :count)
  end

  defp inherited_evidence_total([], _partition), do: 0

  defp inherited_evidence_total(memory_ids, partition) do
    repo().aggregate(
      from(e in Evidence,
        where: e.memory_id in ^memory_ids and e.host_id == ^partition.host_id
      ),
      :count
    )
  end

  defp related_audit([]), do: []

  defp related_audit(memory_ids) do
    repo().all(
      from(row in "memory_audit_log",
        where:
          fragment(
            "EXISTS (SELECT 1 FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(?) = 'array' THEN ? ELSE '[]'::jsonb END) target(value) WHERE target.value = ANY(?))",
            row.target_ids,
            row.target_ids,
            ^memory_ids
          ),
        order_by: [desc: row.created_at, desc: row.id],
        limit: ^@audit_limit,
        select: %{
          id: row.id,
          operation: row.operation,
          target_ids: row.target_ids,
          metadata: row.metadata,
          created_at: row.created_at
        }
      )
    )
  end

  defp related_audit_total([]), do: 0

  defp related_audit_total(memory_ids) do
    repo().aggregate(
      from(row in "memory_audit_log",
        where:
          fragment(
            "EXISTS (SELECT 1 FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(?) = 'array' THEN ? ELSE '[]'::jsonb END) target(value) WHERE target.value = ANY(?))",
            row.target_ids,
            row.target_ids,
            ^memory_ids
          )
      ),
      :count
    )
  end

  defp sessions(evidence, partition) do
    ids = evidence |> Enum.map(& &1.source_session_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    repo().all(
      from(session in ProjectedSession,
        where: session.session_id in ^ids and session.host_id == ^partition.host_id,
        where:
          fragment("? IS NOT DISTINCT FROM ?", session.client_id, ^partition.client_id) and
            session.scope == ^partition.scope and session.namespace == ^partition.namespace,
        order_by: [asc: session.session_id, asc: session.subject_id],
        limit: ^@source_limit,
        select: %{
          subject_id: session.subject_id,
          host_id: session.host_id,
          client_id: session.client_id,
          scope: session.scope,
          namespace: session.namespace,
          session_id: session.session_id,
          processing_version: session.processing_version,
          input_revision: session.input_revision,
          source_complete: session.gap_count == 0,
          source_gap_count: session.gap_count,
          status: session.status
        }
      )
    )
  end

  defp evidence_total(memory_id, partition) do
    repo().aggregate(
      from(e in Evidence, where: e.memory_id == ^memory_id and e.host_id == ^partition.host_id),
      :count
    )
  end

  defp relation_total(memory_id, partition) do
    repo().aggregate(
      from(r in Relation,
        join: source in Memory,
        on: source.id == r.source_memory_id,
        join: target in Memory,
        on: target.id == r.target_memory_id,
        where: r.source_memory_id == ^memory_id or r.target_memory_id == ^memory_id,
        where:
          source.host_id == ^partition.host_id and
            fragment("? IS NOT DISTINCT FROM ?", source.client_id, ^partition.client_id) and
            source.scope == ^partition.scope and source.namespace == ^partition.namespace and
            target.host_id == ^partition.host_id and
            fragment("? IS NOT DISTINCT FROM ?", target.client_id, ^partition.client_id) and
            target.scope == ^partition.scope and target.namespace == ^partition.namespace
      ),
      :count
    )
  end

  defp audit_total(memory_id) do
    repo().aggregate(
      from(row in "memory_audit_log",
        where:
          fragment(
            "CASE jsonb_typeof(?) WHEN 'array' THEN ? @> jsonb_build_array(?::text) WHEN 'object' THEN EXISTS (SELECT 1 FROM jsonb_each_text(?) AS target(key, value) WHERE target.value = ?) ELSE false END",
            row.target_ids,
            row.target_ids,
            ^memory_id,
            row.target_ids,
            ^memory_id
          )
      ),
      :count
    )
  end

  defp page_counts(total, returned),
    do: %{total_count: total, returned_count: returned, truncated: total > returned}
end

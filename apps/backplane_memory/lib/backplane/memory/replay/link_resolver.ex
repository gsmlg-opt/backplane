defmodule Backplane.Memory.Replay.LinkResolver do
  @moduledoc "Resolves exact-partition derived artifacts per replay event."

  import Ecto.Query

  alias Backplane.Memory.Coordination.Action
  alias Backplane.Memory.Crystals.{Crystal, SourceEvent}
  alias Backplane.Memory.Graph.Node
  alias Backplane.Memory.Lessons.Lesson
  alias Backplane.Memory.Memories.{Evidence, Memory}
  alias Backplane.Memory.Projections.ProjectedSession
  alias Backplane.Memory.Summaries.Summary

  @link_types ~w(summary memory graph lesson crystal action)a

  def resolve(event_ids, partition, session_id) when is_list(event_ids) do
    dumped_event_ids = Enum.map(event_ids, &Ecto.UUID.dump!/1)
    summaries = summaries(partition, session_id)
    evidence = evidence(event_ids, partition, session_id)
    all_memory_ids = evidence |> Enum.map(& &1.memory_id) |> Enum.uniq()
    lesson_memory_ids = lessons(all_memory_ids) |> MapSet.new()
    graphs = graphs(dumped_event_ids, partition)
    actions = actions(dumped_event_ids, all_memory_ids, partition)
    crystal_sources = crystal_sources(event_ids)
    crystals = crystals(session_id, all_memory_ids, Map.keys(crystal_sources), partition)

    Map.new(event_ids, fn event_id ->
      memory_ids = memory_ids_for(evidence, event_id, session_id)

      links = %{
        summary: summaries,
        memory: memory_ids,
        lesson: Enum.filter(memory_ids, &MapSet.member?(lesson_memory_ids, &1)),
        graph: ids_containing(graphs, event_id, :source_observation_ids),
        action: action_ids_for(actions, event_id, memory_ids),
        crystal: crystal_ids_for(crystals, crystal_sources, event_id, memory_ids, session_id)
      }

      {event_id, Map.take(links, @link_types)}
    end)
  end

  defp summaries(partition, session_id) do
    repo().all(
      from s in Summary,
        join: ps in ProjectedSession,
        on: ps.subject_id == s.subject_id,
        where:
          ps.host_id == ^partition.host_id and ps.client_id == ^partition.client_id and
            ps.scope == ^partition.scope and ps.namespace == ^partition.namespace and
            ps.session_id == ^session_id and is_nil(s.superseded_at),
        order_by: s.id,
        select: s.id
    )
  end

  defp evidence(event_ids, partition, session_id) do
    repo().all(
      from e in Evidence,
        join: m in Memory,
        on: m.id == e.memory_id,
        where:
          m.host_id == ^partition.host_id and m.client_id == ^partition.client_id and
            m.scope == ^partition.scope and m.namespace == ^partition.namespace and
            (e.source_event_id in ^event_ids or e.session_id == ^session_id or
               e.source_session_id == ^session_id),
        order_by: [e.memory_id, e.id],
        select: %{
          memory_id: e.memory_id,
          source_event_id: e.source_event_id,
          session_id: e.session_id,
          source_session_id: e.source_session_id
        }
    )
  end

  defp lessons([]), do: []

  defp lessons(memory_ids) do
    repo().all(
      from l in Lesson,
        where: l.memory_id in ^memory_ids,
        order_by: l.memory_id,
        select: l.memory_id
    )
  end

  defp graphs(dumped_event_ids, partition) do
    repo().all(
      from n in Node,
        where:
          n.host_id == ^partition.host_id and n.client_id == ^partition.client_id and
            n.scope == ^partition.scope and n.namespace == ^partition.namespace and
            fragment("? && ?", n.source_observation_ids, ^dumped_event_ids),
        order_by: n.id,
        select: %{id: n.id, source_observation_ids: n.source_observation_ids}
    )
  end

  defp actions(dumped_event_ids, memory_ids, partition) do
    dumped_memory_ids = Enum.map(memory_ids, &Ecto.UUID.dump!/1)

    repo().all(
      from a in Action,
        where:
          a.host_id == ^partition.host_id and a.client_id == ^partition.client_id and
            a.scope == ^partition.scope and a.namespace == ^partition.namespace and
            (fragment("? && ?", a.source_observation_ids, ^dumped_event_ids) or
               fragment("? && ?", a.source_memory_ids, ^dumped_memory_ids)),
        order_by: a.id,
        select: %{
          id: a.id,
          source_observation_ids: a.source_observation_ids,
          source_memory_ids: a.source_memory_ids
        }
    )
  end

  defp crystal_sources(event_ids) do
    repo().all(
      from se in SourceEvent,
        where: se.event_id in ^event_ids,
        order_by: [se.event_id, se.crystal_id],
        select: {se.crystal_id, se.event_id}
    )
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp crystals(session_id, memory_ids, event_crystal_ids, partition) do
    repo().all(
      from c in Crystal,
        where:
          c.host_id == ^partition.host_id and c.client_id == ^partition.client_id and
            c.scope == ^partition.scope and c.namespace == ^partition.namespace and
            (c.source_session_id == ^session_id or c.id in ^event_crystal_ids or
               c.memory_id in ^memory_ids),
        order_by: c.id,
        select: %{id: c.id, memory_id: c.memory_id, source_session_id: c.source_session_id}
    )
  end

  defp memory_ids_for(evidence, event_id, session_id) do
    evidence
    |> Enum.filter(fn row ->
      if is_binary(row.source_event_id) do
        row.source_event_id == event_id
      else
        row.session_id == session_id or row.source_session_id == session_id
      end
    end)
    |> Enum.map(& &1.memory_id)
    |> Enum.uniq()
  end

  defp ids_containing(rows, value, field) do
    rows
    |> Enum.filter(&(value in Map.fetch!(&1, field)))
    |> Enum.map(& &1.id)
  end

  defp action_ids_for(actions, event_id, memory_ids) do
    actions
    |> Enum.filter(fn action ->
      event_id in action.source_observation_ids or
        Enum.any?(memory_ids, &(&1 in action.source_memory_ids))
    end)
    |> Enum.map(& &1.id)
  end

  defp crystal_ids_for(crystals, sources, event_id, memory_ids, session_id) do
    crystals
    |> Enum.filter(fn crystal ->
      case Map.fetch(sources, crystal.id) do
        {:ok, source_event_ids} -> event_id in source_event_ids
        :error -> crystal.source_session_id == session_id or crystal.memory_id in memory_ids
      end
    end)
    |> Enum.map(& &1.id)
  end

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)
end

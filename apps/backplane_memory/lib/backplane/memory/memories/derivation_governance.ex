defmodule Backplane.Memory.Memories.DerivationGovernance do
  @moduledoc false

  import Ecto.Query

  alias Backplane.Memory.Events.Event
  alias Backplane.Memory.Memories.Evidence
  alias Backplane.Memory.Projections.ProjectedSession
  alias Backplane.Memory.Observations.Observation
  alias Backplane.Memory.Summaries.Summary

  @sources [
    source_summary_id: Summary,
    source_event_id: Event,
    source_observation_id: Observation
  ]

  def find_tombstone(candidates, incoming, partition) do
    tombstones = Enum.filter(candidates, &(not is_nil(&1.deleted_at)))
    if tombstones != [], do: match_tombstone(tombstones, incoming, partition)
  end

  defp match_tombstone(tombstones, incoming, partition) do
    ids = Enum.map(tombstones, & &1.id)
    stored = repo().all(from(e in Evidence, where: e.memory_id in ^ids))
    sources = load_sources(incoming ++ stored, partition)
    incoming_roots = roots(incoming, sources)

    # Workers currently attribute whole sessions, not individual facts to events.
    # A changed summary revision still belongs to the same governed source subject.
    if MapSet.size(incoming_roots) > 0 and
         Enum.all?(incoming_roots, &match?({:captured_session, _, _}, &1)) do
      by_memory = Enum.group_by(stored, & &1.memory_id)

      Enum.find(tombstones, fn memory ->
        governed = roots(Map.get(by_memory, memory.id, []), sources)
        MapSet.subset?(incoming_roots, governed)
      end)
    end
  end

  defp load_sources(evidence, partition) do
    sources =
      Map.new(@sources, fn {field, schema} ->
        ids = evidence |> Enum.map(&Map.get(&1, field)) |> Enum.reject(&is_nil/1) |> Enum.uniq()

        rows =
          repo().all(
            from(s in schema,
              where: s.id in ^ids,
              where:
                s.memory_space_id == ^partition.memory_space_id and
                  s.host_id == ^partition.host_id and s.scope == ^partition.scope and
                  s.namespace == ^partition.namespace,
              select: {s.id, s.host_id, s.session_id}
            )
          )

        {field, Map.new(rows, fn {id, host, session} -> {id, session_root(host, session)} end)}
      end)

    ids =
      evidence
      |> Enum.map(&Map.get(&1, :source_session_id))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    sessions =
      repo().all(
        from(s in ProjectedSession,
          where: s.session_id in ^ids,
          where:
            s.memory_space_id == ^partition.memory_space_id and
              s.host_id == ^partition.host_id and s.scope == ^partition.scope and
              s.namespace == ^partition.namespace,
          select: {s.session_id, s.host_id}
        )
      )

    Map.put(
      sources,
      :source_session_id,
      Map.new(sessions, fn {session, host} ->
        {session, session_root(host, session)}
      end)
    )
  end

  defp roots(evidence, sources) do
    evidence
    |> Enum.flat_map(fn source ->
      cond do
        Map.get(source, :source_session_id) ->
          id = Map.get(source, :source_session_id)
          [Map.get(sources[:source_session_id], id, {:unresolved, :session, id})]

        Map.get(source, :source_crystal_id) ->
          [{:unsupported, :crystal, Map.get(source, :source_crystal_id)}]

        true ->
          Enum.flat_map(@sources, fn {field, _schema} ->
            case Map.get(source, field) do
              nil -> []
              id -> [Map.get(sources[field], id, {:unresolved, field, id})]
            end
          end)
      end
    end)
    |> MapSet.new()
  end

  defp session_root(host, session) when is_binary(host) and is_binary(session),
    do: {:captured_session, host, session}

  defp session_root(host, session), do: {:unresolved_session, host, session}

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)
end

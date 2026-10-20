defmodule Backplane.Memory.Provenance do
  @moduledoc "Repository attribution inherited through exact, canonical evidence links."
  import Ecto.Query

  alias Backplane.Memory.Events.Event
  alias Backplane.Memory.Memories.{Memory, RememberRequest}
  alias Backplane.MemoryRepository

  @doc "Enriches a new memory without changing its ownership, historical project, or evidence."
  def metadata(metadata, evidence, partition) do
    sources = Enum.flat_map(evidence, &source_records(&1, partition))
    MemoryRepository.metadata(metadata, sources)
  end

  @doc "Collects the distinct repository/path associations from canonical event payloads."
  def event_sources(events) do
    events
    |> Enum.flat_map(fn event ->
      MemoryRepository.sources((event.payload || %{})["repository_sources"])
    end)
    |> MemoryRepository.sources()
  end

  @doc "Retains available action-chain source associations without assigning a guessed repository."
  def action_sources(actions, partition) do
    memory_ids = Enum.flat_map(actions, & &1.source_memory_ids)
    lesson_ids = Enum.flat_map(actions, & &1.source_lesson_ids)
    crystal_ids = Enum.flat_map(actions, & &1.source_crystal_ids)

    lesson_memory_ids =
      from(lesson in Backplane.Memory.Lessons.Lesson,
        where: lesson.memory_id in ^lesson_ids,
        select: lesson.memory_id
      )

    crystal_memory_ids =
      from(crystal in Backplane.Memory.Crystals.Crystal,
        where: crystal.id in ^crystal_ids,
        select: crystal.memory_id
      )

    metadata_sources =
      from(memory in Memory,
        where:
          memory.memory_space_id == ^partition.memory_space_id and
            memory.scope == ^partition.scope and memory.namespace == ^partition.namespace,
        where:
          memory.id in ^memory_ids or memory.id in subquery(lesson_memory_ids) or
            memory.id in subquery(crystal_memory_ids),
        select: memory.metadata
      )
      |> repo().all()
      |> Enum.flat_map(&MemoryRepository.sources(&1["repository_sources"]))

    evidence =
      Enum.flat_map(actions, fn action ->
        Enum.map(action.source_session_ids, &%{source_session_id: &1, host_id: action.host_id}) ++
          Enum.map(action.source_observation_ids, &%{source_event_id: &1})
      end)

    metadata(%{}, evidence, partition)
    |> MemoryRepository.metadata(metadata_sources)
    |> Map.get("repository_sources", [])
  end

  defp source_records(%{source_request_id: id}, partition) when is_binary(id) do
    from(memory in Memory,
      join: request in RememberRequest,
      on: request.memory_id == memory.id,
      where: request.id == ^id,
      where:
        memory.memory_space_id == ^partition.memory_space_id and
          memory.scope == ^partition.scope and memory.namespace == ^partition.namespace,
      select: memory.metadata
    )
    |> repo().all()
    |> Enum.flat_map(&MemoryRepository.sources(&1["repository_sources"]))
  end

  defp source_records(evidence, partition) do
    Event
    |> where(
      [event],
      event.memory_space_id == ^partition.memory_space_id and
        event.scope == ^partition.scope and event.namespace == ^partition.namespace
    )
    |> evidence_events(evidence)
    |> repo().all()
    |> event_sources()
  end

  defp evidence_events(query, %{source_event_id: id}) when is_binary(id),
    do: where(query, [event], event.id == ^id)

  # Legacy observations have no retained repository metadata. Canonical projected
  # observation IDs are event IDs, so exact evidence can retain that attribution.
  defp evidence_events(query, %{source_observation_id: id}) when is_binary(id),
    do: where(query, [event], event.id == ^id)

  defp evidence_events(query, %{source_summary_id: id}) when is_binary(id) do
    join(query, :inner, [event], source in Backplane.Memory.Summaries.SourceEvent,
      on: source.event_id == event.id and source.summary_id == ^id
    )
  end

  defp evidence_events(query, %{source_crystal_id: id}) when is_binary(id) do
    join(query, :inner, [event], source in Backplane.Memory.Crystals.SourceEvent,
      on: source.event_id == event.id and source.crystal_id == ^id
    )
  end

  defp evidence_events(query, %{source_session_id: id, host_id: host}) when is_binary(id),
    do: where(query, [event], event.session_id == ^id and event.host_id == ^host)

  defp evidence_events(query, _evidence), do: where(query, false)
  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)
end

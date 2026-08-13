defmodule Backplane.Memory.Operations.Health do
  @moduledoc "Bounded, content-free processing health for one exact memory partition."

  import Ecto.Query

  alias Backplane.Memory.Lessons.Lesson
  alias Backplane.Memory.Memories.{Memory, Relation}
  alias Backplane.Memory.Projections.{ProjectedSession, State}

  def snapshot(partition) when is_map(partition) do
    %{
      projections: projection_counts(partition),
      unembedded_memories: unembedded_count(partition),
      relation_candidates: relation_candidate_count(partition),
      lesson_candidates: lesson_candidate_count(partition),
      bounded: true,
      content_exposed: false
    }
  end

  defp projection_counts(partition) do
    repo().all(
      from(state in State,
        join: session in ProjectedSession,
        on: session.subject_id == state.subject_id,
        where:
          state.subject_type == "captured_session" and
            session.host_id == ^partition.host_id and
            session.client_id == ^partition.client_id and session.scope == ^partition.scope and
            session.namespace == ^partition.namespace,
        group_by: state.status,
        order_by: state.status,
        select: {state.status, count(state.id)}
      )
    )
    |> Map.new()
  end

  defp unembedded_count(partition) do
    repo().aggregate(
      from(memory in Memory,
        where:
          memory.host_id == ^partition.host_id and memory.client_id == ^partition.client_id and
            memory.scope == ^partition.scope and memory.namespace == ^partition.namespace and
            is_nil(memory.deleted_at) and is_nil(memory.embedding)
      ),
      :count,
      :id
    )
  end

  defp relation_candidate_count(partition) do
    repo().aggregate(
      from(relation in Relation,
        join: memory in Memory,
        on: memory.id == relation.source_memory_id,
        where:
          relation.status == "candidate" and memory.host_id == ^partition.host_id and
            memory.client_id == ^partition.client_id and memory.scope == ^partition.scope and
            memory.namespace == ^partition.namespace and is_nil(memory.deleted_at)
      ),
      :count,
      :id
    )
  end

  defp lesson_candidate_count(partition) do
    repo().aggregate(
      from(lesson in Lesson,
        join: memory in Memory,
        on: memory.id == lesson.memory_id,
        where:
          lesson.status in ["candidate", "disputed"] and
            memory.host_id == ^partition.host_id and memory.client_id == ^partition.client_id and
            memory.scope == ^partition.scope and memory.namespace == ^partition.namespace and
            is_nil(memory.deleted_at)
      ),
      :count,
      :memory_id
    )
  end

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)
end

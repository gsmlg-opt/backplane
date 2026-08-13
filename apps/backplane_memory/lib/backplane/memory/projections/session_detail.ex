defmodule Backplane.Memory.Projections.SessionDetail do
  @moduledoc """
  Bounded, exact-partition session detail shared by REST and LiveView.

  The representation is assembled from canonical events and their read models.
  Every collection is capped so a session detail request cannot materialize an
  unbounded event history in the server or browser.
  """

  import Ecto.Query

  alias Backplane.Memory.Coordination.Action
  alias Backplane.Memory.Crystals.Crystal
  alias Backplane.Memory.Events.Event
  alias Backplane.Memory.Lessons.Lesson
  alias Backplane.Memory.Memories.Memory

  alias Backplane.Memory.Projections.{ProjectedObservation, ReadModels, State}
  alias Backplane.Memory.Summaries.Summary

  @collection_limit 100
  @processing_keys ~w(summary embeddings graph profile lessons crystal)a

  @doc "Returns the SES-002 detail representation for one exact partition and session."
  def get(partition, session_id) when is_map(partition) and is_binary(session_id) do
    with :ok <- exact_partition(partition),
         true <- String.trim(session_id) != "" || {:error, :invalid_session_id},
         {:ok, [session]} <- session(partition, String.trim(session_id)) do
      session_id = String.trim(session_id)
      events = metadata_events(partition, session_id)
      observations = projected_observations(partition, session_id)
      memories = memories(partition, session_id)
      lessons = lessons(partition, session_id)
      crystals = crystals(partition, session_id)
      states = processing_states(session.subject_id)

      {:ok,
       %{
         subject_id: session.subject_id,
         session_id: session.session_id,
         project: session.project,
         host_id: session.host_id,
         agent_id: session.agent_id,
         integration: first_value(events, & &1.integration),
         model: first_value(events, &event_model/1),
         status: session.status,
         started_at: session.started_at,
         ended_at: session.ended_at,
         duration_ms: duration_ms(session.started_at, session.ended_at),
         first_prompt: first_value(events, &event_prompt/1),
         summary: summary(session.subject_id),
         observation_count: session.observation_count,
         event_type_breakdown: event_breakdown(partition, session_id),
         tool_breakdown: tool_breakdown(partition, session_id),
         files: observations |> Enum.flat_map(& &1.file_paths) |> Enum.uniq() |> Enum.sort(),
         commits:
           observations
           |> Enum.map(& &1.commit_hash)
           |> Enum.reject(&is_nil/1)
           |> Enum.uniq()
           |> Enum.sort(),
         source_session_id: first_value(events, & &1.parent_session_id),
         child_session_ids: child_session_ids(partition, session_id),
         processing: processing(states, memories, lessons, crystals),
         links: %{
           actions: actions(partition, session.project, Enum.map(observations, & &1.event_id)),
           lessons: lessons,
           memories: memories,
           crystals: crystals
         }
       }}
    else
      {:ok, []} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
      false -> {:error, :invalid_session_id}
    end
  end

  def get(_partition, _session_id), do: {:error, :partition_required}

  defp session(partition, session_id) do
    ReadModels.sessions(
      host_id: partition.host_id,
      client_id: partition.client_id,
      scope: partition.scope,
      namespace: partition.namespace,
      session_id: session_id,
      limit: 1
    )
  end

  defp metadata_events(partition, session_id) do
    repo().all(
      from(event in Event,
        where: ^event_partition(partition),
        where: event.session_id == ^session_id,
        order_by: [asc_nulls_last: event.source_sequence, asc: event.occurred_at, asc: event.id],
        limit: ^@collection_limit
      )
    )
  end

  defp projected_observations(partition, session_id) do
    repo().all(
      from(observation in ProjectedObservation,
        where: ^observation_partition(partition),
        where: observation.session_id == ^session_id,
        order_by: [asc: observation.occurred_at, asc: observation.event_id],
        limit: ^@collection_limit,
        select: %{
          event_id: observation.event_id,
          file_paths: observation.file_paths,
          commit_hash: observation.commit_hash
        }
      )
    )
  end

  defp event_breakdown(partition, session_id) do
    Event
    |> where([event], ^event_partition(partition))
    |> where([event], event.session_id == ^session_id)
    |> group_by([event], event.event_type)
    |> order_by([event], asc: event.event_type)
    |> limit(^@collection_limit)
    |> select([event], {event.event_type, count(event.id)})
    |> repo().all()
    |> Map.new()
  end

  defp tool_breakdown(partition, session_id) do
    ProjectedObservation
    |> where([observation], ^observation_partition(partition))
    |> where([observation], observation.session_id == ^session_id)
    |> where([observation], not is_nil(observation.tool_name) and observation.tool_name != "")
    |> group_by([observation], observation.tool_name)
    |> order_by([observation], asc: observation.tool_name)
    |> limit(^@collection_limit)
    |> select([observation], {observation.tool_name, count(observation.event_id)})
    |> repo().all()
    |> Map.new()
  end

  defp summary(subject_id) do
    repo().one(
      from(summary in Summary,
        where: summary.subject_id == ^subject_id and is_nil(summary.superseded_at),
        order_by: [desc: summary.created_at, desc: summary.id],
        limit: 1,
        select: %{
          id: summary.id,
          content: summary.content,
          observation_count: summary.observation_count,
          processing_version: summary.processing_version
        }
      )
    )
  end

  defp memories(partition, session_id) do
    repo().all(
      from(memory in Memory,
        where: ^row_partition(partition),
        where: memory.session_id == ^session_id and is_nil(memory.deleted_at),
        order_by: [desc: memory.inserted_at, desc: memory.id],
        limit: ^@collection_limit,
        select: %{
          id: memory.id,
          memory_type: memory.memory_type,
          lifecycle_state: memory.lifecycle_state,
          embedded: not is_nil(memory.embedding)
        }
      )
    )
  end

  defp lessons(partition, session_id) do
    repo().all(
      from(lesson in Lesson,
        join: memory in Memory,
        on: memory.id == lesson.memory_id,
        where:
          memory.host_id == ^partition.host_id and memory.client_id == ^partition.client_id and
            memory.scope == ^partition.scope and memory.namespace == ^partition.namespace,
        where: memory.session_id == ^session_id and is_nil(memory.deleted_at),
        order_by: [desc: lesson.updated_at, desc: lesson.memory_id],
        limit: ^@collection_limit,
        select: %{
          memory_id: lesson.memory_id,
          status: lesson.status,
          reinforcement_count: lesson.reinforcement_count
        }
      )
    )
  end

  defp crystals(partition, session_id) do
    repo().all(
      from(crystal in Crystal,
        where: ^row_partition(partition),
        where: crystal.source_session_id == ^session_id,
        order_by: [desc: crystal.updated_at, desc: crystal.id],
        limit: ^@collection_limit,
        select: %{id: crystal.id, title: crystal.title, status: crystal.status}
      )
    )
  end

  defp actions(partition, project, event_ids) do
    query =
      from(action in Action,
        where: ^row_partition(partition),
        where:
          fragment(
            "? && ?",
            action.source_observation_ids,
            type(^event_ids, {:array, :binary_id})
          ),
        order_by: [desc: action.updated_at, desc: action.id],
        limit: ^@collection_limit,
        select: %{id: action.id, title: action.title, status: action.status}
      )

    query = if project, do: where(query, [action], action.project == ^project), else: query
    repo().all(query)
  end

  defp child_session_ids(partition, session_id) do
    repo().all(
      from(event in Event,
        where: ^event_partition(partition),
        where: event.parent_session_id == ^session_id and not is_nil(event.session_id),
        distinct: event.session_id,
        order_by: [asc: event.session_id],
        limit: ^@collection_limit,
        select: event.session_id
      )
    )
  end

  defp processing_states(subject_id) do
    repo().all(
      from(state in State,
        where: state.subject_type == "captured_session" and state.subject_id == ^subject_id,
        select: %{
          projector: state.projector,
          status: state.status,
          processing_version: state.processing_version,
          attempt_count: state.attempt_count,
          last_error: state.last_error
        }
      )
    )
  end

  defp processing(states, memories, lessons, crystals) do
    indexed = Map.new(states, &{&1.projector, Map.delete(&1, :projector)})

    Map.new(@processing_keys, fn
      :embeddings ->
        status =
          cond do
            memories == [] -> "pending"
            Enum.all?(memories, & &1.embedded) -> "complete"
            true -> "pending"
          end

        {:embeddings, %{status: status, last_error: nil}}

      :lessons ->
        {:lessons, derived_processing(indexed, "lessons", lessons)}

      :crystal ->
        {:crystal, derived_processing(indexed, "crystal", crystals)}

      key ->
        {key, Map.get(indexed, Atom.to_string(key), %{status: "pending", last_error: nil})}
    end)
  end

  defp derived_processing(indexed, projector, rows) do
    Map.get_lazy(indexed, projector, fn ->
      %{status: if(rows == [], do: "pending", else: "complete"), last_error: nil}
    end)
  end

  defp event_model(event) do
    first_string([
      get_in(event.payload || %{}, ["source", "model"]),
      get_in(event.payload || %{}, ["model"]),
      get_in(event.raw_envelope || %{}, ["model"])
    ])
  end

  defp event_prompt(event) do
    first_string([
      get_in(event.payload || %{}, ["source", "prompt"]),
      get_in(event.payload || %{}, ["prompt"]),
      if(event.event_type in ["conversation.user_message", "agent.prompt"], do: event.content)
    ])
  end

  defp first_value(values, fun), do: Enum.find_value(values, fun)

  defp first_string(values) do
    Enum.find(values, &(is_binary(&1) and String.trim(&1) != ""))
  end

  defp duration_ms(%DateTime{} = started_at, %DateTime{} = ended_at),
    do: DateTime.diff(ended_at, started_at, :millisecond)

  defp duration_ms(_started_at, _ended_at), do: nil

  defp exact_partition(partition) do
    if Enum.all?([:host_id, :client_id, :scope, :namespace], fn key ->
         case Map.get(partition, key) do
           value when is_binary(value) -> String.trim(value) != ""
           _value -> false
         end
       end),
       do: :ok,
       else: {:error, :partition_required}
  end

  defp event_partition(partition) do
    dynamic(
      [row],
      row.host_id == ^partition.host_id and row.client_id == ^partition.client_id and
        row.scope == ^partition.scope and row.namespace == ^partition.namespace
    )
  end

  defp observation_partition(partition) do
    dynamic(
      [row],
      row.host_id == ^partition.host_id and row.client_id == ^partition.client_id and
        row.scope == ^partition.scope and row.namespace == ^partition.namespace
    )
  end

  defp row_partition(partition) do
    dynamic(
      [record],
      record.host_id == ^partition.host_id and record.client_id == ^partition.client_id and
        record.scope == ^partition.scope and record.namespace == ^partition.namespace
    )
  end

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)
end

defmodule Backplane.Memory.Operations.StageStatus do
  @moduledoc "Bounded processing metadata for one exact operator-selected partition."

  import Ecto.Query

  alias Backplane.Memory.Memories.Memory
  alias Backplane.Memory.Profiles.Profile
  alias Backplane.Memory.Projections.{ProjectedSession, State}

  def list(partition) do
    sessions = owned(ProjectedSession, partition)
    memories = owned(Memory, partition)
    memory_subjects = from(memory in memories, select: fragment("?::text", memory.id))

    # Procedural identities contain the canonical owner and exact project. Raw
    # source_client_id is capture provenance, never an authorization boundary.
    prefix = Enum.join(owner_values(partition), ":") <> ":"

    session_partitions =
      from(session in sessions,
        select: fragment("? || COALESCE(?, '')", ^prefix, session.project)
      )

    memory_partitions =
      from(memory in memories,
        select:
          fragment(
            "? || COALESCE(CASE WHEN jsonb_typeof(?->'project') = 'string' THEN ?->>'project' ELSE '' END, '')",
            ^prefix,
            memory.metadata,
            memory.metadata
          )
      )

    profile_subjects = profile_subjects(partition)

    rows =
      repo().all(
        from(state in State,
          left_join: session in subquery(sessions),
          on:
            (state.subject_type == "captured_session" and session.subject_id == state.subject_id) or
              (state.subject_type == "captured_session_window" and
                 fragment(
                   "starts_with(?, ? || ':window:')",
                   state.subject_id,
                   session.subject_id
                 )),
          where:
            state.memory_space_id == ^partition.memory_space_id and
              state.host_id == ^partition.host_id and
              state.scope == ^partition.scope and state.namespace == ^partition.namespace,
          where:
            not is_nil(session.subject_id) or
              (state.subject_type == "memory" and state.subject_id in subquery(memory_subjects)) or
              (state.subject_type == "memory_partition" and state.projector == "procedural" and
                 (state.subject_id in subquery(session_partitions) or
                    state.subject_id in subquery(memory_partitions))) or
              (state.subject_type == "memory_profile" and state.projector == "profile" and
                 state.subject_id in ^profile_subjects),
          order_by: [desc: state.updated_at, desc: state.id],
          limit: 50,
          select: %{
            id: state.id,
            projector: state.projector,
            subject_type: state.subject_type,
            subject_id: state.subject_id,
            status: state.status,
            input_revision: state.input_revision,
            output_revision: state.output_revision,
            attempt_count: state.attempt_count,
            session_id: session.session_id
          }
        )
      )

    {:ok, Enum.map(rows, &Map.put(&1, :reason, reason(&1.status)))}
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp owned(query, partition) do
    from(owner in query,
      where:
        owner.memory_space_id == ^partition.memory_space_id and
          owner.host_id == ^partition.host_id and owner.client_id == ^partition.client_id and
          owner.scope == ^partition.scope and owner.namespace == ^partition.namespace
    )
  end

  defp profile_subjects(partition) do
    Profile
    |> owned(partition)
    |> order_by([profile], desc: profile.updated_at, desc: profile.id)
    |> limit(50)
    |> select([profile], profile.project)
    |> repo().all()
    |> Enum.map(fn project ->
      (owner_values(partition) ++ [project])
      |> :erlang.term_to_binary([:deterministic])
      |> Base.url_encode64(padding: false)
    end)
  end

  defp owner_values(partition) do
    [
      partition.memory_space_id,
      partition.host_id,
      partition.client_id,
      partition.scope,
      partition.namespace
    ]
  end

  # Provider failures may contain response bodies. Keep them out of operator metadata.
  defp reason("failed"), do: "Processing failed. Inspect the source session and retry."

  defp reason("dead_letter"),
    do: "Retry limit reached. Inspect the source session before retrying."

  defp reason("skipped_no_model"), do: "Select a Memory model in Config before retrying."
  defp reason("skipped_disabled"), do: "Stage disabled. Enable its policy before retrying."
  defp reason("complete"), do: "Processing complete."
  defp reason("running"), do: "Processing is running."
  defp reason("enqueued"), do: "Waiting for a worker."
  defp reason(_), do: "Awaiting processing."

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)
end

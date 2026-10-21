defmodule Backplane.Memory.Operations.Consolidation do
  @moduledoc "Partition-scoped session consolidation with revision progress and bounded artifact identities."
  import Ecto.Query

  alias Backplane.Memory.{Audit, PartitionIdentity}
  alias Backplane.Memory.Crystals.Crystal
  alias Backplane.Memory.Memories.{Evidence, Memory}
  alias Backplane.Memory.Projections.{ProjectedSession, Source, State}
  alias Backplane.Memory.Summaries.Summary
  alias Backplane.Memory.Workers.{ProceduralWorker, StageResumeWorker}

  def get(session_id, partition) when is_binary(session_id) and session_id != "" do
    with {:ok, partition} <- PartitionIdentity.validate_generator(partition),
         %ProjectedSession{} = session <- owned_session(session_id, partition) do
      {:ok, progress(session, [])}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def get(_, _), do: {:error, :invalid_arguments}

  def enqueue(session_id, partition) when is_binary(session_id) and session_id != "" do
    with {:ok, partition} <- PartitionIdentity.validate_generator(partition),
         %ProjectedSession{} = session <- owned_session(session_id, partition) do
      case repo().transaction(fn ->
             Source.lock_streams(session.host_id, session.session_id)
             session = owned_session(session_id, partition)

             case StageResumeWorker.reconcile_session(session, retry_failed: true) do
               {:ok, jobs} ->
                 Audit.log_once(
                   "memory.consolidate",
                   "operator",
                   [session.subject_id],
                   "#{session.subject_id}:#{session.input_revision}",
                   Map.merge(partition, %{
                     session_id: session_id,
                     input_revision: session.input_revision
                   })
                 )

                 progress(session, jobs)

               {:error, reason} ->
                 repo().rollback(reason)
             end
           end) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, reason}
      end
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def enqueue(_, _), do: {:error, :invalid_arguments}

  defp progress(session, jobs) do
    states =
      repo().all(
        from(s in State,
          where:
            s.subject_type == "captured_session" and
              s.subject_id == ^session.subject_id and s.input_revision == ^session.input_revision
        )
      )
      |> Map.new(&{&1.projector, &1})

    stages =
      Map.new(~w(summary episodic graph crystal), fn stage ->
        value =
          case states[stage] do
            nil -> %{status: "pending", reason: nil}
            state -> %{status: state.status, reason: state.last_error}
          end

        {stage, value}
      end)

    {:ok, procedural} =
      ProceduralWorker.processing_identity(Map.from_struct(session), session.project || "")

    procedure_state =
      repo().one(
        from(s in State,
          where:
            s.projector == "procedural" and s.subject_type == "memory_partition" and
              s.subject_id == ^procedural.subject_id and
              s.input_revision == ^procedural.input_revision
        )
      )

    window_prefix = session.subject_id <> ":window:"

    window_states =
      repo().all(
        from(s in State,
          where:
            s.projector == "window_summary" and s.subject_type == "captured_session_window" and
              s.memory_space_id == ^session.memory_space_id and s.host_id == ^session.host_id and
              s.scope == ^session.scope and s.namespace == ^session.namespace and
              fragment("starts_with(?, ?)", s.subject_id, ^window_prefix),
          order_by: [asc: s.subject_id],
          limit: 100,
          select: %{
            subject_id: s.subject_id,
            status: s.status,
            reason: s.last_error,
            input_revision: s.input_revision
          }
        )
      )

    stages =
      stages
      |> Map.put("procedural", state_progress(procedure_state))
      |> Map.put("window_summary", %{
        status: if(window_states == [], do: "pending", else: "observed"),
        windows: window_states
      })

    summaries =
      repo().all(
        from(s in Summary,
          where:
            s.subject_id == ^session.subject_id and
              s.processing_version == "summary-v1" and s.input_revision == ^session.input_revision,
          limit: 1,
          select: s.id
        )
      )

    windows =
      repo().all(
        from(s in Summary,
          where:
            s.host_id == ^session.host_id and
              s.memory_space_id == ^session.memory_space_id and s.scope == ^session.scope and
              s.namespace == ^session.namespace and s.session_id == ^session.session_id and
              s.processing_version == "window-summary-v1",
          order_by: [asc: s.subject_id],
          limit: 100,
          select: s.id
        )
      )

    artifacts =
      if summaries == [] do
        []
      else
        repo().all(
          from(m in Memory,
            join: e in Evidence,
            on: e.memory_id == m.id,
            where:
              e.source_summary_id in ^summaries and m.memory_space_id == ^session.memory_space_id and
                m.scope == ^session.scope and m.namespace == ^session.namespace and
                is_nil(m.deleted_at),
            distinct: m.id,
            order_by: [asc: m.id],
            limit: 100,
            select: {m.id, m.memory_type}
          )
        )
      end

    crystals =
      repo().all(
        from(c in Crystal,
          where:
            c.subject_id == ^session.subject_id and c.input_revision == ^session.input_revision and
              c.memory_space_id == ^session.memory_space_id and c.host_id == ^session.host_id and
              c.client_id == ^session.client_id and c.scope == ^session.scope and
              c.namespace == ^session.namespace and c.status == "complete",
          order_by: [asc: c.id],
          limit: 100,
          select: c.id
        )
      )

    %{
      status: if(jobs == [], do: "idle", else: "queued"),
      session_id: session.session_id,
      input_revision: session.input_revision,
      stages: stages,
      job_ids: Enum.map(jobs, & &1.id),
      artifact_ids: %{
        summaries: summaries,
        windows: windows,
        crystals: crystals,
        facts: for({id, "semantic"} <- artifacts, do: id),
        procedures: for({id, "procedural"} <- artifacts, do: id)
      },
      bounded: true
    }
  end

  defp state_progress(nil), do: %{status: "pending", reason: nil}
  defp state_progress(state), do: %{status: state.status, reason: state.last_error}

  defp owned_session(session_id, partition) do
    repo().one(
      from(s in ProjectedSession,
        where:
          s.session_id == ^session_id and
            s.memory_space_id == ^partition.memory_space_id and s.host_id == ^partition.host_id and
            s.client_id == ^partition.client_id and s.scope == ^partition.scope and
            s.namespace == ^partition.namespace
      )
    )
  end

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)
end

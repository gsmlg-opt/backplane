defmodule Backplane.Memory.Projections.Rebuild do
  @moduledoc "Rebuild orchestration for canonical captured-session production read models."

  import Ecto.Query

  alias Backplane.Memory.Projections.{
    ActivityProjector,
    ActivityStore,
    Gaps,
    ObservationProjector,
    ProjectedObservation,
    ProjectedSession,
    ReplayProjector,
    Revision,
    SessionProjector,
    Snapshot,
    Source,
    State
  }

  alias Backplane.Memory.Audit

  @subject_type "captured_session"
  @projector_names ~w(observations session activity replay)
  @processing_versions %{
    "observations" => "observations-v1",
    "session" => "session-v1",
    "activity" => "activity-v1",
    "replay" => "replay-v1"
  }

  def session(host_id, session_id) do
    with {:ok, subject_id} <- Source.subject_id(host_id, session_id) do
      case repo().transaction(fn ->
             Source.lock_streams(host_id, session_id)

             case Source.events(host_id, session_id) do
               {:ok, [_ | _] = events} ->
                 case canonical_partition(events) do
                   {:ok, _partition} ->
                     input_revision = Revision.input_revision(events)

                     try do
                       rebuild(host_id, session_id, subject_id, events, input_revision)
                     rescue
                       exception ->
                         repo().rollback(
                           {:projection_failed, input_revision, exception, __STACKTRACE__}
                         )
                     end

                   {:error, reason} ->
                     repo().rollback(reason)
                 end

               {:ok, []} ->
                 repo().rollback(:not_found)

               {:error, reason} ->
                 repo().rollback(reason)
             end
           end) do
        {:ok, result} ->
          {:ok, result}

        {:error, :not_found} ->
          {:error, :not_found}

        {:error, :ambiguous_partition} ->
          {:error, :ambiguous_partition}

        {:error, {:projection_failed, input_revision, exception, stacktrace}} ->
          record_failed(host_id, session_id, subject_id, input_revision, exception)
          reraise exception, stacktrace

        {:error, reason} ->
          raise "projection rebuild transaction failed: #{inspect(reason)}"
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp canonical_partition(events) do
    partitions =
      events
      |> Enum.map(&Map.take(&1, [:host_id, :client_id, :scope, :namespace]))

    complete? =
      Enum.all?(partitions, fn partition ->
        Enum.all?([:host_id, :client_id, :scope, :namespace], fn key ->
          value = Map.get(partition, key)
          is_binary(value) and String.trim(value) != ""
        end)
      end)

    case Enum.uniq(partitions) do
      [partition] when complete? -> {:ok, partition}
      _ -> {:error, :ambiguous_partition}
    end
  end

  def all(opts \\ []) do
    on_result = Keyword.get(opts, :on_result, fn _result -> :ok end)
    page_size = Keyword.get(opts, :page_size, 100)

    if is_function(on_result, 1) do
      Source.reduce_subjects(
        0,
        fn subject, completed ->
          case safe_session(subject) do
            {:ok, result} ->
              on_result.(result)
              {:cont, completed + 1}

            {:error, reason} ->
              {:error, %{reason: reason, subject: subject, completed: completed}}
          end
        end,
        page_size: page_size
      )
      |> case do
        {:ok, rebuilt} -> {:ok, %{rebuilt: rebuilt}}
        {:error, report} -> {:error, report}
      end
    else
      {:error, :invalid_on_result}
    end
  end

  defp rebuild(host_id, session_id, subject_id, events, input_revision) do
    gaps = Gaps.find(events)
    outputs = outputs(events, gaps)
    output_revisions = output_revisions(outputs)
    final_status = if gaps == [], do: "complete", else: "pending"

    replace_observation_rows(
      subject_id,
      input_revision,
      Map.fetch!(outputs, "observations")
    )

    replace_session_row(subject_id, input_revision, events, Map.fetch!(outputs, "session"))

    replace_activity_rows(subject_id, input_revision, Map.fetch!(outputs, "activity"))
    replace_replay_rows(subject_id, input_revision, events, Map.fetch!(outputs, "replay"))

    states =
      Enum.map(@projector_names, fn projector ->
        state = mark_running(projector, subject_id, input_revision)

        replace_snapshot(
          projector,
          subject_id,
          input_revision,
          Map.fetch!(output_revisions, projector),
          Map.fetch!(outputs, projector)
        )

        finalize_state(
          state,
          final_status,
          Map.fetch!(output_revisions, projector)
        )
      end)

    %{
      production_read_models: true,
      host_id: host_id,
      session_id: session_id,
      subject_type: @subject_type,
      subject_id: subject_id,
      input_revision: input_revision,
      session_status: get_in(outputs, ["session", "status"]),
      last_event_at: parse_datetime!(get_in(outputs, ["session", "last_event_at"])),
      output_revisions: output_revisions,
      gaps: gaps,
      states: Map.new(states, &{&1.projector, state_result(&1)})
    }
  end

  defp replace_session_row(subject_id, input_revision, events, read_model) do
    now = now()
    first = List.first(events)

    previous_status =
      case repo().get(ProjectedSession, subject_id) do
        %ProjectedSession{status: status} -> status
        nil -> nil
      end

    row = %{
      subject_id: subject_id,
      host_id: read_model["host_id"],
      client_id: read_model["client_id"],
      scope: read_model["scope"],
      namespace: read_model["namespace"],
      session_id: read_model["session_id"],
      project: read_model["project"],
      agent_id: read_model["agent_id"],
      integration: first && first.integration,
      status: read_model["status"],
      started_at: parse_optional_datetime!(read_model["started_at"]),
      ended_at: parse_optional_datetime!(read_model["ended_at"]),
      last_event_at: parse_datetime!(read_model["last_event_at"]),
      source_sequence_max: read_model["source_sequence_max"],
      gap_count: length(read_model["gaps"] || []),
      processing_version: Map.fetch!(@processing_versions, "session"),
      input_revision: input_revision,
      inserted_at: now,
      updated_at: now
    }

    repo().insert_all(ProjectedSession, [row],
      on_conflict:
        {:replace,
         [
           :host_id,
           :client_id,
           :scope,
           :namespace,
           :session_id,
           :project,
           :agent_id,
           :integration,
           :status,
           :started_at,
           :ended_at,
           :last_event_at,
           :source_sequence_max,
           :gap_count,
           :processing_version,
           :input_revision,
           :updated_at
         ]},
      conflict_target: [:subject_id]
    )

    if previous_status != read_model["status"] do
      Audit.log_once(
        "session.lifecycle_transition",
        read_model["agent_id"] || "system",
        [read_model["session_id"]],
        "#{subject_id}:#{input_revision}:#{read_model["status"]}",
        %{
          host_id: read_model["host_id"],
          client_id: read_model["client_id"],
          scope: read_model["scope"],
          namespace: read_model["namespace"],
          session_id: read_model["session_id"],
          from: previous_status,
          to: read_model["status"],
          input_revision: input_revision
        }
      )
    end
  end

  defp outputs(events, gaps) do
    %{
      "observations" => ObservationProjector.project(events),
      "session" => SessionProjector.project(events, gaps),
      "activity" => %{"activity" => ActivityProjector.project(events)},
      "replay" => %{"events" => ReplayProjector.project(events)}
    }
  end

  defp output_revisions(outputs) do
    Map.new(outputs, fn {projector, output} ->
      {:ok, output_revision} = Revision.output_revision(output)
      {projector, output_revision}
    end)
  end

  defp mark_running(projector, subject_id, input_revision) do
    now = now()

    attrs = %{
      projector: projector,
      subject_type: @subject_type,
      subject_id: subject_id,
      processing_version: Map.fetch!(@processing_versions, projector),
      input_revision: input_revision,
      output_revision: nil,
      status: "running",
      last_error: nil,
      started_at: now,
      completed_at: nil
    }

    case locked_state(projector, subject_id) do
      nil ->
        %State{}
        |> State.changeset(Map.put(attrs, :attempt_count, 1))
        |> repo().insert!()

      state ->
        state
        |> State.changeset(Map.put(attrs, :attempt_count, state.attempt_count + 1))
        |> repo().update!()
    end
  end

  defp replace_snapshot(projector, subject_id, input_revision, output_revision, read_model) do
    attrs = %{
      projector: projector,
      subject_type: @subject_type,
      subject_id: subject_id,
      input_revision: input_revision,
      output_revision: output_revision,
      read_model: read_model
    }

    case locked_snapshot(projector, subject_id) do
      nil ->
        %Snapshot{}
        |> Snapshot.changeset(attrs)
        |> repo().insert!()

      snapshot ->
        snapshot
        |> Snapshot.changeset(attrs)
        |> repo().update!()
    end
  end

  defp replace_observation_rows(subject_id, input_revision, read_model) do
    now = now()

    rows =
      Enum.map(read_model["observations"], fn observation ->
        %{
          event_id: observation["event_id"],
          subject_id: subject_id,
          host_id: read_model["host_id"],
          client_id: read_model["client_id"],
          scope: read_model["scope"],
          namespace: read_model["namespace"],
          session_id: read_model["session_id"],
          project: observation["project"],
          agent_id: observation["agent_id"],
          source_sequence: observation["source_sequence"],
          event_type: observation["event_type"],
          occurred_at: parse_datetime!(observation["occurred_at"]),
          tool_name: observation["tool_name"],
          content: observation["content"],
          message: observation["message"],
          importance: observation["importance"] || 0,
          is_error: observation["is_error"] || false,
          file_paths: observation["file_paths"] || [],
          commit_hash: observation["commit_hash"],
          processing_version: Map.fetch!(@processing_versions, "observations"),
          input_revision: input_revision,
          inserted_at: now,
          updated_at: now
        }
      end)

    repo().delete_all(from(row in ProjectedObservation, where: row.subject_id == ^subject_id))

    if rows != [] do
      repo().insert_all(ProjectedObservation, rows)
    end
  end

  defp replace_activity_rows(subject_id, input_revision, read_model) do
    ActivityStore.replace_subject!(subject_id, input_revision, read_model["activity"] || [])
  end

  defp replace_replay_rows(subject_id, input_revision, events, read_model) do
    first = List.first(events)
    partition = Map.take(first, [:host_id, :client_id, :scope, :namespace])

    Backplane.Memory.Replay.Store.put!(
      subject_id,
      input_revision,
      partition,
      first.session_id,
      read_model["events"] || []
    )
  end

  defp parse_datetime!(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.shift_zone!(datetime, "Etc/UTC")
      {:error, reason} -> raise ArgumentError, "invalid projected occurred_at: #{inspect(reason)}"
    end
  end

  defp parse_optional_datetime!(nil), do: nil
  defp parse_optional_datetime!(value), do: parse_datetime!(value)

  defp finalize_state(state, status, output_revision) do
    state
    |> State.changeset(%{
      status: status,
      output_revision: output_revision,
      completed_at: now()
    })
    |> repo().update!()
  end

  defp locked_state(projector, subject_id) do
    repo().one(
      from(s in State,
        where:
          s.projector == ^projector and s.subject_type == ^@subject_type and
            s.subject_id == ^subject_id,
        lock: "FOR UPDATE"
      )
    )
  end

  defp locked_snapshot(projector, subject_id) do
    repo().one(
      from(s in Snapshot,
        where:
          s.projector == ^projector and s.subject_type == ^@subject_type and
            s.subject_id == ^subject_id,
        lock: "FOR UPDATE"
      )
    )
  end

  defp safe_session(subject) do
    session(subject["host_id"], subject["session_id"])
  rescue
    exception -> {:error, {:exception, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @doc false
  def record_failed(host_id, session_id, subject_id, input_revision, exception) do
    error = Exception.message(exception)

    try do
      repo().transaction(fn ->
        Source.lock_streams(host_id, session_id)

        if current_input_revision(host_id, session_id) == input_revision do
          Enum.each(@projector_names, fn projector ->
            attrs = %{
              projector: projector,
              subject_type: @subject_type,
              subject_id: subject_id,
              processing_version: Map.fetch!(@processing_versions, projector),
              input_revision: input_revision,
              output_revision: nil,
              status: "failed",
              last_error: error,
              started_at: now(),
              completed_at: now()
            }

            case locked_state(projector, subject_id) do
              nil ->
                %State{}
                |> State.changeset(Map.put(attrs, :attempt_count, 1))
                |> repo().insert!()

              %State{
                status: status,
                input_revision: state_input_revision,
                output_revision: revision
              }
              when status in ["complete", "pending"] and not is_nil(revision) and
                     state_input_revision == input_revision ->
                :ok

              state ->
                state
                |> State.changeset(Map.put(attrs, :attempt_count, state.attempt_count + 1))
                |> repo().update!()
            end
          end)
        end
      end)
    rescue
      _exception -> :ok
    end

    :ok
  end

  defp current_input_revision(host_id, session_id) do
    case Source.events(host_id, session_id) do
      {:ok, [_ | _] = events} -> Revision.input_revision(events)
      _other -> nil
    end
  end

  defp state_result(state) do
    %{
      status: state.status,
      attempt_count: state.attempt_count,
      processing_version: state.processing_version,
      input_revision: state.input_revision,
      output_revision: state.output_revision
    }
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)
end

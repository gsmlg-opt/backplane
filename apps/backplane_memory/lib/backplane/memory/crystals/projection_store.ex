defmodule Backplane.Memory.Crystals.ProjectionStore do
  @moduledoc false

  import Ecto.Query

  alias Backplane.Memory.Crystals.Crystal
  alias Backplane.Memory.Projections.{Source, State}

  @projector "crystal"
  @subject_type "captured_session"
  @processing_version "crystal-v1"

  def enqueue(host_id, session_id, input_revision, enqueue_fn),
    do: enqueue(host_id, session_id, input_revision, enqueue_fn, [])

  def enqueue(host_id, session_id, input_revision, enqueue_fn, opts)
      when is_function(enqueue_fn, 0) and is_list(opts) do
    subject_id = Source.subject_id!(host_id, session_id)
    source_revision_fn = Keyword.get(opts, :source_revision_fn, &Source.input_revision/2)

    case repo().transaction(fn ->
           lock(subject_id)

           case source_revision_fn.(host_id, session_id) do
             {:ok, %{input_revision: ^input_revision}} ->
               put_state(subject_id, input_revision, "pending", 0)

             {:ok, _newer_input} ->
               stale(locked_state(subject_id))
           end
         end) do
      {:ok, {:stale, _newer_state} = stale} ->
        {:ok, stale}

      {:ok, %State{}} ->
        repo().transaction(fn ->
          lock(subject_id)

          case {locked_state(subject_id), source_revision_fn.(host_id, session_id)} do
            {%State{input_revision: ^input_revision}, {:ok, %{input_revision: ^input_revision}}} ->
              case enqueue_fn.() do
                {:ok, job} ->
                  case source_revision_fn.(host_id, session_id) do
                    {:ok, %{input_revision: ^input_revision}} ->
                      put_state(subject_id, input_revision, "enqueued", 0)
                      job

                    {:ok, _newer_input} ->
                      stale(locked_state(subject_id))
                  end

                {:error, reason} ->
                  repo().rollback(reason)
              end

            {%State{} = newer_state, _source_revision} ->
              {:stale, newer_state}
          end
        end)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stale(%State{} = state), do: {:stale, state}
  defp stale(nil), do: repo().rollback(:projection_state_missing)

  def running(host_id, session_id, input_revision) do
    update(host_id, session_id, input_revision, fn state ->
      put_state(state, input_revision, "running", state.attempt_count + 1,
        started_at: now(),
        completed_at: nil
      )
    end)
  end

  def complete(host_id, session_id, input_revision, %Crystal{} = crystal) do
    update_current(host_id, session_id, input_revision, fn state ->
      put_state(state, input_revision, "complete", state.attempt_count,
        output_revision: crystal.output_revision,
        completed_at: now()
      )
    end)
  end

  def failed(host_id, session_id, input_revision, error_class, terminal? \\ false) do
    update(host_id, session_id, input_revision, fn state ->
      put_state(
        state,
        input_revision,
        if(terminal?, do: "dead_letter", else: "failed"),
        state.attempt_count,
        last_error: safe_error_class(error_class),
        completed_at: now()
      )
    end)
  end

  def skipped(host_id, session_id, input_revision, classification) do
    update(host_id, session_id, input_revision, fn state ->
      put_state(state, input_revision, "skipped", state.attempt_count,
        last_error: safe_error_class(classification),
        completed_at: now()
      )
    end)
  end

  defp update(host_id, session_id, input_revision, update_fn) do
    subject_id = Source.subject_id!(host_id, session_id)

    repo().transaction(fn ->
      lock(subject_id)

      case locked_state(subject_id) do
        nil -> repo().rollback(:projection_state_missing)
        %State{input_revision: ^input_revision} = state -> update_fn.(state)
        %State{} = newer_state -> {:stale, newer_state}
      end
    end)
  end

  defp update_current(host_id, session_id, input_revision, update_fn) do
    subject_id = Source.subject_id!(host_id, session_id)

    repo().transaction(fn ->
      lock(subject_id)

      case {locked_state(subject_id), Source.input_revision(host_id, session_id)} do
        {%State{input_revision: ^input_revision} = state,
         {:ok, %{input_revision: ^input_revision}}} ->
          update_fn.(state)

        {%State{} = state, {:ok, _newer_input}} ->
          {:stale, state}

        {nil, _source_revision} ->
          repo().rollback(:projection_state_missing)

        {%State{} = newer_state, _source_revision} ->
          {:stale, newer_state}
      end
    end)
  end

  defp put_state(subject_id, input_revision, status, attempts) when is_binary(subject_id) do
    attrs = attrs(subject_id, input_revision, status, attempts)

    case locked_state(subject_id) do
      nil -> %State{} |> State.changeset(attrs) |> repo().insert!()
      state -> put_state(state, input_revision, status, attempts)
    end
  end

  defp put_state(%State{} = state, input_revision, status, attempts, extra \\ []) do
    attrs =
      state.subject_id
      |> attrs(input_revision, status, attempts)
      |> Map.merge(Map.new(extra))

    state |> State.changeset(attrs) |> repo().update!()
  end

  defp attrs(subject_id, input_revision, status, attempts) do
    %{
      projector: @projector,
      subject_type: @subject_type,
      subject_id: subject_id,
      processing_version: @processing_version,
      input_revision: input_revision,
      output_revision: nil,
      status: status,
      attempt_count: attempts,
      last_error: nil,
      started_at: nil,
      completed_at: nil
    }
  end

  defp locked_state(subject_id) do
    repo().one(
      from(state in State,
        where:
          state.projector == @projector and state.subject_type == @subject_type and
            state.subject_id == ^subject_id,
        lock: "FOR UPDATE"
      )
    )
  end

  defp lock(subject_id) do
    repo().query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      "#{@projector}:#{subject_id}:#{@processing_version}"
    ])
  end

  defp safe_error_class(value) when is_atom(value), do: Atom.to_string(value)
  defp safe_error_class(_value), do: "crystallization_failed"

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)
end

defmodule Backplane.Memory.Projections.ProcessingState do
  @moduledoc false

  import Ecto.Query

  alias Backplane.Memory.Projections.State

  @statuses ~w(pending enqueued running complete skipped_no_model skipped_disabled failed dead_letter)
  @terminal ~w(complete skipped_no_model skipped_disabled failed dead_letter)

  def statuses, do: @statuses
  def terminal?(status) when status in @terminal, do: true
  def terminal?(_status), do: false

  def failure_status(%Oban.Job{attempt: attempt, max_attempts: max_attempts})
      when is_integer(attempt) and is_integer(max_attempts) and attempt >= max_attempts,
      do: "dead_letter"

  def failure_status(%Oban.Job{}), do: "failed"

  def skipped_status(reason) do
    case normalize_reason(reason) |> String.downcase() do
      reason when reason in ["no_llm", "no_model", "llm_model_missing", "model_not_configured"] ->
        "skipped_no_model"

      reason
      when reason in [
             "disabled",
             "feature_disabled",
             "crystal_disabled",
             "crystal_session_disabled",
             "embedding_circuit_open"
           ] ->
        "skipped_disabled"

      _ ->
        "failed"
    end
  end

  def normalize_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  def normalize_reason(reason) when is_binary(reason), do: String.trim(reason)
  def normalize_reason(reason) when is_exception(reason), do: Exception.message(reason)
  def normalize_reason(_reason), do: "processing_failed"

  def transition(repo, attrs, status, opts \\ []) when status in @statuses do
    case repo.transaction(fn ->
           state =
             repo.one(
               from(s in State,
                 where:
                   s.projector == ^attrs.projector and s.subject_type == ^attrs.subject_type and
                     s.subject_id == ^attrs.subject_id,
                 lock: "FOR UPDATE"
               )
             )

           transition_locked(repo, state, attrs, status, opts)
         end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def transition_current(repo, attrs, status, current_attrs, opts \\ [])
      when status in @statuses and is_function(current_attrs, 0) do
    case repo.transaction(fn ->
           case current_attrs.() do
             {:ok, current} ->
               state = lock_state(repo, attrs)

               if current.input_revision == attrs.input_revision do
                 transition_locked(
                   repo,
                   state,
                   attrs,
                   status,
                   Keyword.put(opts, :authoritative_revision, true)
                 )
               else
                 {:stale, state}
               end

             {:error, reason} ->
               {:error, reason}
           end
         end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def persist_current(repo, attrs, current_attrs, persist, opts \\ [])
      when is_function(current_attrs, 0) and is_function(persist, 0) do
    case repo.transaction(fn ->
           case current_attrs.() do
             {:ok, current} ->
               state = lock_state(repo, attrs)

               if current.input_revision == attrs.input_revision do
                 case persist.() do
                   {:ok, result} ->
                     case transition_locked(
                            repo,
                            state,
                            attrs,
                            "complete",
                            Keyword.put(opts, :authoritative_revision, true)
                          ) do
                       {:ok, terminal_state} -> {result, terminal_state}
                       {:error, reason} -> repo.rollback({:transition, reason})
                       {:stale, stale_state} -> repo.rollback({:stale, stale_state})
                     end

                   {:error, reason} ->
                     repo.rollback({:persistence, reason})
                 end
               else
                 {:stale, state}
               end

             {:error, reason} ->
               {:error, reason}
           end
         end) do
      {:ok, {:stale, state}} -> {:stale, state}
      {:ok, {:error, reason}} -> {:error, reason}
      {:ok, {result, state}} -> {:ok, result, state}
      {:error, {:persistence, reason}} -> {:error, reason}
      {:error, {:transition, reason}} -> {:error, reason}
      {:error, {:stale, state}} -> {:stale, state}
      {:error, reason} -> {:error, reason}
    end
  end

  defp lock_state(repo, attrs) do
    repo.one(
      from(s in State,
        where:
          s.projector == ^attrs.projector and s.subject_type == ^attrs.subject_type and
            s.subject_id == ^attrs.subject_id,
        lock: "FOR UPDATE"
      )
    )
  end

  defp transition_locked(repo, nil, attrs, status, opts) do
    attrs
    |> Map.merge(transition_attrs(status, opts, 0))
    |> then(&State.changeset(%State{}, &1))
    |> repo.insert()
  end

  defp transition_locked(repo, %State{} = state, attrs, status, opts) do
    input_revision = Map.fetch!(attrs, :input_revision)

    revision_changed? = state.input_revision not in [nil, input_revision]
    authoritative_revision? = Keyword.get(opts, :authoritative_revision, false)

    if revision_changed? and not authoritative_revision? do
      {:stale, state}
    else
      state
      |> State.changeset(Map.merge(attrs, transition_attrs(status, opts, state.attempt_count)))
      |> repo.update()
    end
  end

  defp transition_attrs(status, opts, attempts) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    reason = Keyword.get(opts, :reason)

    %{
      status: status,
      attempt_count: if(status == "running", do: attempts + 1, else: attempts),
      last_error: if(reason, do: normalize_reason(reason), else: nil),
      started_at: if(status == "running", do: now, else: nil),
      completed_at: if(terminal?(status), do: now, else: nil)
    }
  end
end

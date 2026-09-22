defmodule Backplane.Memory.Workers.EpisodicWorker do
  @moduledoc "Oban worker: extract semantic memories from session summary (episodic → semantic)."

  use Oban.Worker, queue: :memory, max_attempts: 3

  import Ecto.Query

  alias Backplane.Memory.Summaries.Summary
  alias Backplane.Memory.Memories
  alias Backplane.Memory.PartitionIdentity
  alias Backplane.Memory.Projections.{ProcessingState, ProjectedSession, Source}

  @processing_version "episodic-v1"

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)

  @impl Oban.Worker
  def perform(%Oban.Job{} = job) do
    Backplane.Memory.PipelineTelemetry.span("episodic", job.args, fn ->
      do_perform(job)
    end)
  end

  defp do_perform(%Oban.Job{args: %{"summary_id" => summary_id} = args} = job)
       when is_binary(summary_id) and map_size(args) == 1 do
    with {:ok, summary_id} <- Ecto.UUID.cast(summary_id) do
      run_summary(repo().get(Summary, summary_id), job)
    else
      :error -> {:cancel, :invalid_arguments}
    end
  end

  defp do_perform(%Oban.Job{args: %{"session_id" => session_id} = args})
       when is_binary(session_id) and map_size(args) == 1,
       do: {:cancel, :incomplete_partition}

  defp do_perform(%Oban.Job{}), do: {:cancel, :invalid_arguments}

  defp run_summary(nil, _job), do: :ok

  defp run_summary(%Summary{} = summary, job) do
    case claim_current_revision(summary) do
      {:ok, {partition, state_attrs}} ->
        try do
          case Backplane.Settings.get("memory.llm_model") do
            nil ->
              require Logger
              Logger.debug("[memory] episodic worker: skipping, no llm_model configured")

              persist_current_result(summary, partition, state_attrs, {:skip, :no_model}, job)

            _model ->
              llm_module =
                Application.get_env(:backplane_memory, :llm_module, Backplane.Memory.LLM)

              result = extract(summary, partition, llm_module)
              persist_current_result(summary, partition, state_attrs, result, job)
          end
        rescue
          exception ->
            _ =
              persist_current_result(summary, partition, state_attrs, {:error, exception}, job)

            reraise exception, __STACKTRACE__
        end

      {:error, reason} ->
        {:discard, reason}
    end
  end

  defp claim_current_revision(%Summary{} = summary) do
    case repo().transaction(fn ->
           Source.lock_streams(summary.host_id, summary.session_id)

           with {:ok, partition} <- projected_partition(summary),
                state_attrs = processing_attrs(summary, partition),
                {:ok, _state} <-
                  ProcessingState.transition(repo(), state_attrs, "running",
                    authoritative_revision: true
                  ) do
             {:claimed, {partition, state_attrs}}
           else
             {:stale, _state} -> {:error, :stale_input_revision}
             {:error, reason} -> {:error, reason}
           end
         end) do
      {:ok, {:claimed, result}} -> {:ok, result}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp extract(%Summary{} = summary, _partition, llm_module) do
    case llm_module.extract_facts(summary.content) do
      {:ok, facts} when is_list(facts) ->
        {:ok, normalize_outputs(facts)}

      {:skip, reason} ->
        {:skip, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp persist_current_result(summary, _partition, state_attrs, result, job) do
    case repo().transaction(fn ->
           Source.lock_streams(summary.host_id, summary.session_id)

           with {:ok, partition} <- projected_partition(summary),
                outcome <- persist_result(summary, partition, state_attrs, result, job) do
             case outcome do
               {:rollback_failure, reason} -> repo().rollback({:failure, reason})
               {:rollback, reason} -> repo().rollback({:error, reason})
               {:commit, result} -> result
             end
           else
             {:error, reason} -> repo().rollback({:stale, reason})
           end
         end) do
      {:ok, outcome} ->
        outcome

      {:error, {:stale, reason}} ->
        {:discard, reason}

      {:error, {:failure, reason}} ->
        record_persistence_failure(summary, state_attrs, reason, job)

      {:error, {:error, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp persist_result(summary, partition, state_attrs, {:ok, facts}, _job) do
    case persist_facts(summary, partition, facts) do
      :ok ->
        case ProcessingState.transition(repo(), state_attrs, "complete") do
          {:ok, _state} -> {:commit, :ok}
          {:stale, _state} -> {:rollback, :stale_input_revision}
          {:error, reason} -> {:rollback, reason}
        end

      {:error, reason} ->
        {:rollback_failure, reason}
    end
  end

  defp persist_result(_summary, _partition, state_attrs, {:skip, reason}, _job) do
    case ProcessingState.transition(
           repo(),
           state_attrs,
           ProcessingState.skipped_status(reason),
           reason: reason
         ) do
      {:ok, _state} -> {:commit, :ok}
      {:stale, _state} -> {:rollback, :stale_input_revision}
      {:error, reason} -> {:rollback, reason}
    end
  end

  defp persist_result(_summary, _partition, state_attrs, {:error, reason}, job) do
    case ProcessingState.transition(
           repo(),
           state_attrs,
           ProcessingState.failure_status(job),
           reason: reason
         ) do
      {:ok, _state} -> {:commit, {:error, reason}}
      {:stale, _state} -> {:rollback, :stale_input_revision}
      {:error, transition_reason} -> {:rollback, transition_reason}
    end
  end

  defp record_persistence_failure(summary, state_attrs, reason, job) do
    case repo().transaction(fn ->
           Source.lock_streams(summary.host_id, summary.session_id)

           with {:ok, _partition} <- projected_partition(summary) do
             case ProcessingState.transition(
                    repo(),
                    state_attrs,
                    ProcessingState.failure_status(job),
                    reason: reason
                  ) do
               {:ok, _state} -> {:error, reason}
               {:stale, _state} -> repo().rollback({:stale, :stale_input_revision})
               {:error, transition_reason} -> repo().rollback({:error, transition_reason})
             end
           else
             {:error, stale_reason} -> repo().rollback({:stale, stale_reason})
           end
         end) do
      {:ok, result} -> result
      {:error, {:stale, stale_reason}} -> {:discard, stale_reason}
      {:error, {:error, transition_reason}} -> {:error, transition_reason}
      {:error, transaction_reason} -> {:error, transaction_reason}
    end
  end

  defp persist_facts(summary, partition, facts) do
    require Logger

    errors =
      facts
      |> Enum.with_index()
      |> Enum.flat_map(fn {fact, ordinal} ->
        case Memories.remember(fact,
               type: "semantic",
               memory_space_id: partition.memory_space_id,
               scope: partition.scope,
               namespace: partition.namespace,
               client_id: partition.client_id,
               source_client_id: partition[:source_client_id],
               agent_id: summary.agent_id || "consolidation",
               host_id: summary.host_id,
               session_id: summary.session_id,
               idempotency_scope: "memory-worker:episodic",
               idempotency_key: idempotency_key(summary, ordinal),
               evidence: [summary_evidence(summary)]
             ) do
          {:ok, _} -> []
          {:error, reason} -> [reason]
        end
      end)

    case errors do
      [] ->
        :ok

      [first | rest] ->
        Logger.warning("[memory] episodic worker: #{length(rest) + 1} fact(s) failed to insert")
        {:error, first}
    end
  end

  defp normalize_outputs(outputs) do
    outputs
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp processing_attrs(summary, partition) do
    %{
      memory_space_id: partition.memory_space_id,
      host_id: partition.host_id,
      source_client_id: partition[:source_client_id],
      scope: partition.scope,
      namespace: partition.namespace,
      projector: "episodic",
      subject_type: "captured_session",
      subject_id: summary.subject_id,
      processing_version: @processing_version,
      input_revision: summary.input_revision,
      output_revision: summary.output_revision
    }
  end

  defp idempotency_key(summary, ordinal) do
    revision = sha256(summary.content)
    Enum.join([@processing_version, summary.id, revision, ordinal], ":")
  end

  defp summary_evidence(summary) do
    %{
      source_summary_id: summary.id,
      session_id: summary.session_id,
      agent_id: summary.agent_id || "consolidation",
      host_id: summary.host_id,
      evidence_kind: "derives",
      support_score: 1.0,
      excerpt: String.slice(summary.content, 0, 1_000)
    }
  end

  defp projected_partition(%Summary{subject_id: subject_id} = summary) do
    query =
      from(session in ProjectedSession,
        where: session.subject_id == ^subject_id,
        lock: "FOR UPDATE"
      )

    case repo().one(query) do
      %ProjectedSession{input_revision: revision} = session
      when revision == summary.input_revision ->
        partition =
          Map.take(Map.from_struct(session), [
            :memory_space_id,
            :host_id,
            :client_id,
            :source_client_id,
            :scope,
            :namespace
          ])

        resolve_partition(summary, partition)

      %ProjectedSession{} ->
        {:error, :stale_input_revision}

      nil ->
        record_partition_issue(summary, :incomplete_partition)
        {:error, :incomplete_partition}
    end
  end

  defp sha256(value), do: value |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

  @doc false
  def resolve_partition(%Summary{} = summary, projected_partition) do
    result =
      with {:ok, summary_partition} <- validate_summary_partition(summary),
           {:ok, projected_partition} <-
             PartitionIdentity.validate_generator(projected_partition),
           {:ok, _canonical_match} <-
             PartitionIdentity.validate(summary_partition, projected_partition),
           true <- summary_partition.host_id == projected_partition.host_id do
        {:ok, projected_partition}
      else
        false -> {:error, :partition_mismatch}
        {:error, reason} -> {:error, reason}
      end

    case result do
      {:ok, partition} ->
        {:ok, partition}

      {:error, reason} = error ->
        record_partition_issue(summary, reason)
        error
    end
  end

  defp validate_summary_partition(summary) do
    with {:ok, partition} <- PartitionIdentity.validate(Map.from_struct(summary)),
         true <- present?(summary.host_id) do
      {:ok, Map.put(partition, :host_id, String.trim(summary.host_id))}
    else
      false -> {:error, :incomplete_partition}
      {:error, reason} -> {:error, reason}
    end
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp record_partition_issue(summary, reason) do
    details =
      summary
      |> Map.from_struct()
      |> Map.take([:memory_space_id, :host_id, :client_id, :source_client_id, :scope, :namespace])
      |> Map.new(fn {key, value} -> {to_string(key), value} end)

    Memories.record_partition_issue("memory_summaries", summary.id, reason, details)
  end

  @doc "Enqueue an episodic extraction job for the given session_id."
  @spec enqueue(String.t()) :: {:error, :incomplete_partition}
  def enqueue(_session_id), do: {:error, :incomplete_partition}

  @doc "Enqueue extraction for one exact durable summary revision."
  @spec enqueue_summary(Ecto.UUID.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue_summary(summary_id) when is_binary(summary_id) do
    %{summary_id: summary_id}
    |> new(unique: [period: :infinity, states: :incomplete, keys: [:summary_id]])
    |> Oban.insert()
  end
end

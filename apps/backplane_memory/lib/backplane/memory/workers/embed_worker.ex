defmodule Backplane.Memory.Workers.EmbedWorker do
  @moduledoc "Oban worker: embed a bpm_memories row via the LLM proxy. Fails gracefully — memory stays unembedded on error."

  use Oban.Worker, queue: :memory, max_attempts: 5

  import Ecto.Query

  alias Backplane.Memory.Embedding.CircuitBreaker
  alias Backplane.Memory.Embedding.Client
  alias Backplane.Memory.Memories.Memory
  alias Backplane.Memory.Projections.ProcessingState

  require Logger

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)

  @impl Oban.Worker
  def perform(%Oban.Job{} = job) do
    Backplane.Memory.PipelineTelemetry.span("embedding", job.args, fn ->
      perform_with_client(job, &Client.embed/3)
    end)
  end

  @doc false
  def perform_with_client(%Oban.Job{args: %{"id" => id}} = job, embed_fn) do
    case repo().get(Memory, id) do
      nil ->
        :ok

      %Memory{} = mem ->
        if CircuitBreaker.allow_request?() do
          state_attrs = processing_attrs(mem)

          case transition_current(mem.id, state_attrs, "running") do
            {:ok, _state} ->
              embed_current(mem, state_attrs, job, embed_fn)

            {:stale, _state} ->
              :ok

            {:error, reason} ->
              {:error, reason}
          end
        else
          Logger.warning("[memory] embed skipped: circuit breaker open for id=#{id}")

          _ =
            transition_current(mem.id, processing_attrs(mem), "skipped_disabled",
              reason: :embedding_circuit_open
            )

          :ok
        end
    end
  end

  defp embed_current(mem, state_attrs, job, embed_fn) do
    try do
      case embed_fn.([mem.content], :document, []) do
        {:ok, [vector]} ->
          case persist_embedding(mem.id, state_attrs, vector) do
            {:ok, _memory, _state} ->
              CircuitBreaker.record_success()
              :ok

            {:stale, _state} ->
              :ok

            {:error, reason} ->
              _ =
                transition_current(
                  mem.id,
                  state_attrs,
                  ProcessingState.failure_status(job),
                  reason: reason
                )

              {:error, reason}
          end

        {:error, reason} ->
          CircuitBreaker.record_failure()

          _ =
            transition_current(
              mem.id,
              state_attrs,
              ProcessingState.failure_status(job),
              reason: reason
            )

          {:error, reason}
      end
    rescue
      exception ->
        CircuitBreaker.record_failure()

        _ =
          transition_current(
            mem.id,
            state_attrs,
            ProcessingState.failure_status(job),
            reason: exception
          )

        reraise exception, __STACKTRACE__
    end
  end

  defp persist_embedding(memory_id, attrs, vector) do
    ProcessingState.persist_current(
      repo(),
      attrs,
      fn -> current_attrs(memory_id) end,
      fn ->
        memory =
          repo().one!(from(memory in Memory, where: memory.id == ^memory_id, lock: "FOR UPDATE"))

        memory |> Memory.embed_changeset(vector) |> repo().update()
      end
    )
  end

  @doc "Enqueue an embed job for the given memory id."
  @spec enqueue(String.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(id) do
    %{id: id}
    |> new()
    |> Oban.insert()
  end

  defp processing_attrs(%Memory{} = memory) do
    %{
      memory_space_id: memory.memory_space_id,
      host_id: memory.host_id,
      source_client_id: memory.source_client_id,
      scope: memory.scope,
      namespace: memory.namespace,
      projector: "embedding",
      subject_type: "memory",
      subject_id: memory.id,
      processing_version: "embedding-v1",
      input_revision: Base.encode16(memory.content_hash, case: :lower),
      output_revision: nil
    }
  end

  defp transition_current(memory_id, attrs, status, opts \\ []) do
    ProcessingState.transition_current(
      repo(),
      attrs,
      status,
      fn -> current_attrs(memory_id) end,
      opts
    )
  end

  defp current_attrs(memory_id) do
    case repo().one(from(memory in Memory, where: memory.id == ^memory_id, lock: "FOR UPDATE")) do
      %Memory{} = memory -> {:ok, processing_attrs(memory)}
      nil -> {:error, :not_found}
    end
  end
end

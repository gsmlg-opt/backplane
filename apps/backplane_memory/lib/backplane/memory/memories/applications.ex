defmodule Backplane.Memory.Memories.Applications do
  @moduledoc false

  import Ecto.Query

  alias Backplane.Memory.Memories
  alias Backplane.Memory.Memories.Memory

  @non_vector_fields [
    :id,
    :content,
    :memory_type,
    :scope,
    :agent_id,
    :host_id,
    :client_id,
    :session_id,
    :tags,
    :metadata,
    :embedding_model,
    :content_hash,
    :confidence,
    :access_count,
    :application_count,
    :accessed_at,
    :superseded_by,
    :expires_at,
    :deleted_at,
    :lifecycle_state,
    :inserted_at,
    :updated_at
  ]

  def record(memory_id, application_id, applied_by, partition) do
    with_application(memory_id, application_id, applied_by, partition, fn record -> record.() end)
  end

  def with_application(memory_id, application_id, applied_by, partition, fun)
      when is_binary(memory_id) and is_function(fun, 1) do
    with {:ok, partition} <- exact_partition(partition),
         :ok <- validate_identity(application_id, applied_by) do
      repo().transaction(fn ->
        advisory_lock!(memory_id, application_id)

        fun.(fn ->
          record_locked(memory_id, application_id, applied_by, partition)
        end)
      end)
    end
  end

  def with_application(_memory_id, _application_id, _applied_by, _partition, _fun),
    do: {:error, :invalid_application}

  defp record_locked(memory_id, application_id, applied_by, partition) do
    idempotency_key = memory_id <> ":" <> application_id

    query =
      from(m in Memory,
        where:
          m.id == ^memory_id and is_nil(m.deleted_at) and m.host_id == ^partition.host_id and
            m.client_id == ^partition.client_id and m.scope == ^partition.scope and
            m.namespace == ^partition.namespace,
        select: struct(m, ^@non_vector_fields),
        lock: "FOR UPDATE"
      )

    case repo().one(query) do
      nil ->
        repo().rollback(:not_found)

      %Memory{memory_type: memory_type} when memory_type != "procedural" ->
        repo().rollback(:not_applicable)

      memory ->
        if application_audited?(idempotency_key) do
          %{application_count: memory.application_count, applied: false}
        else
          {1, nil} =
            repo().update_all(
              from(m in Memory, where: m.id == ^memory.id),
              inc: [application_count: 1]
            )

          application_count = memory.application_count + 1

          Backplane.Memory.Audit.log(
            "memory.apply",
            applied_by,
            [memory.id],
            audit_metadata(memory, %{
              application_id: application_id,
              idempotency_key: idempotency_key,
              result: "succeeded",
              application_count: application_count
            })
          )

          %{application_count: application_count, applied: true}
        end
    end
  end

  defp application_audited?(idempotency_key) do
    repo().exists?(
      from(r in "memory_audit_log",
        where: r.operation == "memory.apply",
        where: fragment("?->>'idempotency_key' = ?", r.metadata, ^idempotency_key)
      )
    )
  end

  defp audit_metadata(memory, details) do
    trace = Memories.provenance_trace(memory)

    %{
      host_id: memory.host_id,
      client_id: memory.client_id,
      scope: memory.scope,
      namespace: memory.namespace,
      request_id: List.first(trace.request_ids),
      request_ids: trace.request_ids,
      correlation_id: List.first(trace.correlation_ids),
      correlation_ids: trace.correlation_ids
    }
    |> Map.merge(details)
  end

  defp advisory_lock!(memory_id, application_id) do
    <<lock_key::signed-64, _rest::binary>> =
      :crypto.hash(
        :sha256,
        :erlang.term_to_binary(
          ["memory-application", memory_id, application_id],
          [:deterministic]
        )
      )

    repo().query!("SELECT pg_advisory_xact_lock($1::bigint)", [lock_key])
    :ok
  end

  defp exact_partition(partition) when is_list(partition),
    do: partition |> Map.new() |> exact_partition()

  defp exact_partition(partition) when is_map(partition) do
    values = %{
      host_id: partition[:host_id] || partition["host_id"],
      client_id: partition[:client_id] || partition["client_id"],
      scope: partition[:scope] || partition["scope"],
      namespace: partition[:namespace] || partition["namespace"]
    }

    if Enum.all?(Map.values(values), &(is_binary(&1) and String.trim(&1) != "")),
      do: {:ok, values},
      else: {:error, :unauthorized}
  end

  defp exact_partition(_partition), do: {:error, :unauthorized}

  defp validate_identity(application_id, applied_by)
       when is_binary(application_id) and is_binary(applied_by) do
    if String.trim(application_id) != "" and String.trim(applied_by) != "",
      do: :ok,
      else: {:error, :invalid_application}
  end

  defp validate_identity(_application_id, _applied_by), do: {:error, :invalid_application}

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)
end

defmodule Backplane.Memory.Imports do
  @moduledoc "Durable, auditable lifecycle tracking for host-local import batches."

  alias Backplane.Memory.Audit
  alias Backplane.Memory.Imports.ImportBatch
  alias Backplane.Memory.PartitionIdentity

  def record(partition, attrs) when is_map(partition) and is_map(attrs) do
    with {:ok, partition} <- PartitionIdentity.validate(partition) do
      Backplane.Memory.PipelineTelemetry.span(
        "import." <> to_string(attrs["action"] || "invalid"),
        Map.merge(attrs, %{
          "memory_space_id" => partition.memory_space_id,
          "host_id" => partition[:host_id],
          "scope" => partition.scope,
          "namespace" => partition.namespace
        }),
        fn -> do_record(partition, attrs) end
      )
    end
  end

  def record(_partition, _attrs), do: {:error, :invalid_batch}

  defp do_record(partition, %{"protocol" => "host_import.v1", "action" => "started"} = attrs) do
    host_id = partition[:host_id]
    now = DateTime.utc_now()

    values = %{
      id: attrs["batch_id"],
      memory_space_id: partition.memory_space_id,
      host_id: host_id,
      source_client_id: partition[:source_client_id],
      scope: partition.scope,
      namespace: partition.namespace,
      integration: attrs["integration"],
      source_format: attrs["source_format"],
      source_path_fingerprint: attrs["source_path_fingerprint"],
      status: "started",
      started_at: now
    }

    transaction(fn ->
      with {:ok, batch} <-
             repo().insert(ImportBatch.changeset(%ImportBatch{}, values), on_conflict: :nothing) do
        :ok =
          Audit.log_once(
            "memory.import.started",
            "host:#{host_id}",
            [batch.id],
            batch.id,
            audit_metadata(batch)
          )

        {:ok, batch_reply(batch)}
      end
    end)
  end

  defp do_record(partition, %{"protocol" => "host_import.v1", "action" => action} = attrs)
       when action in ["completed", "failed"] do
    host_id = partition[:host_id]

    transaction(fn ->
      with %ImportBatch{
             host_id: ^host_id,
             memory_space_id: memory_space_id,
             scope: scope,
             namespace: namespace
           } = batch
           when memory_space_id == partition.memory_space_id and scope == partition.scope and
                  namespace == partition.namespace <-
             repo().get(ImportBatch, attrs["batch_id"]),
           {:ok, batch} <- update_batch(batch, action, attrs) do
        :ok =
          Audit.log_once(
            "memory.import.#{action}",
            "host:#{host_id}",
            [batch.id],
            batch.id,
            audit_metadata(batch)
          )

        {:ok, batch_reply(batch)}
      else
        nil -> {:error, :batch_not_found}
        %ImportBatch{} -> {:error, :host_mismatch}
        {:error, _reason} = error -> error
      end
    end)
  end

  defp do_record(_partition, _attrs), do: {:error, :invalid_batch}

  defp update_batch(batch, action, attrs) do
    values = %{
      status: action_status(action),
      discovered_count: attrs["discovered_count"],
      imported_count: attrs["imported_count"],
      duplicate_count: attrs["duplicate_count"],
      rejected_count: attrs["rejected_count"],
      completed_at: DateTime.utc_now(),
      error: sanitize_error(attrs["error"])
    }

    batch |> ImportBatch.changeset(values) |> repo().update()
  end

  defp transaction(fun) do
    case repo().transaction(fun) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp audit_metadata(batch) do
    %{
      "memory_space_id" => batch.memory_space_id,
      "host_id" => batch.host_id,
      "integration" => batch.integration,
      "source_format" => batch.source_format,
      "source_path_fingerprint" => batch.source_path_fingerprint,
      "status" => batch.status,
      "discovered_count" => batch.discovered_count,
      "imported_count" => batch.imported_count,
      "duplicate_count" => batch.duplicate_count,
      "rejected_count" => batch.rejected_count
    }
  end

  defp batch_reply(batch), do: %{"batch_id" => batch.id, "status" => batch.status}
  defp action_status("completed"), do: "completed"
  defp action_status("failed"), do: "failed"
  defp sanitize_error(value) when is_binary(value), do: String.slice(value, 0, 500)
  defp sanitize_error(_value), do: nil
  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)
end

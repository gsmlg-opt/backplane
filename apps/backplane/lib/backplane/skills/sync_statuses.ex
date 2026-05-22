defmodule Backplane.Skills.SyncStatuses do
  @moduledoc """
  Persistence for host-reported skill sync results.
  """

  alias Backplane.Repo
  alias Backplane.Skills.{Host, HostStatus}

  @upsert_fields ~w(skill_id skill_slug desired_version installed_version desired_checksum installed_checksum targets status error metadata updated_at)a

  @doc "Records host-reported skill sync results."
  @spec record_sync_result(Host.t(), map()) :: {:ok, [HostStatus.t()]} | {:error, term()}
  def record_sync_result(%Host{} = host, %{"results" => results}) when is_list(results) do
    if Enum.all?(results, &is_map/1) do
      upsert_results(host, results)
    else
      {:error, :invalid_payload}
    end
  end

  def record_sync_result(%Host{}, _payload) do
    {:error, :invalid_payload}
  end

  defp upsert_results(host, results) do
    Repo.transaction(fn ->
      results
      |> Enum.reduce_while([], fn result, statuses ->
        attrs = status_attrs(host, result)

        case upsert_status(attrs) do
          {:ok, status} -> {:cont, [status | statuses]}
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)
      |> Enum.reverse()
    end)
  end

  defp upsert_status(attrs) do
    %HostStatus{}
    |> HostStatus.changeset(attrs)
    |> Repo.insert(
      conflict_target: [:host_id, :skill_name],
      on_conflict: {:replace, @upsert_fields},
      returning: true
    )
  end

  defp status_attrs(host, result) do
    %{
      host_id: host.id,
      skill_id: result["skill_id"],
      skill_slug: result["skill_slug"],
      skill_name: result["skill_name"],
      desired_version: result["desired_version"],
      installed_version: result["installed_version"],
      desired_checksum: value_or_checksum(result, "desired_checksum"),
      installed_checksum: value_or_checksum(result, "installed_checksum"),
      targets: Map.get(result, "targets") || [],
      status: result["status"],
      error: result["error"],
      metadata: Map.get(result, "metadata") || %{}
    }
  end

  defp value_or_checksum(result, key) do
    if Map.has_key?(result, key) do
      result[key]
    else
      result["checksum"]
    end
  end
end

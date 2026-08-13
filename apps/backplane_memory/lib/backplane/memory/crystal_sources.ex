defmodule Backplane.Memory.CrystalSources do
  @moduledoc "Exact-partition reads for source objects linked to a crystal."

  import Ecto.Query

  alias Backplane.Memory.Coordination.Action
  alias Backplane.Memory.Crystals.{Crystal, SourceAction, SourceSummary}
  alias Backplane.Memory.Projections.ProjectedSession
  alias Backplane.Memory.Summaries.Summary

  def get_action(crystal_id, action_id, partition) do
    with {:ok, partition} <- normalize_partition(partition),
         %Action{} = action <-
           repo().one(
             from(c in Crystal,
               join: link in SourceAction,
               on: link.crystal_id == c.id,
               join: action in Action,
               on: action.id == link.action_id,
               where:
                 c.id == ^crystal_id and link.action_id == ^action_id and
                   c.host_id == ^partition.host_id and c.client_id == ^partition.client_id and
                   c.scope == ^partition.scope and c.namespace == ^partition.namespace and
                   action.host_id == ^partition.host_id and
                   action.client_id == ^partition.client_id and action.scope == ^partition.scope and
                   action.namespace == ^partition.namespace,
               select: action
             )
           ) do
      {:ok, action}
    else
      _missing -> {:error, :not_found}
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  def get_summary(crystal_id, summary_id, partition) do
    with {:ok, partition} <- normalize_partition(partition),
         %Summary{} = summary <-
           repo().one(
             from(c in Crystal,
               join: link in SourceSummary,
               on: link.crystal_id == c.id,
               join: summary in Summary,
               on: summary.id == link.summary_id,
               where:
                 c.id == ^crystal_id and link.summary_id == ^summary_id and
                   c.host_id == ^partition.host_id and c.client_id == ^partition.client_id and
                   c.scope == ^partition.scope and c.namespace == ^partition.namespace and
                   summary.host_id == ^partition.host_id and
                   summary.session_id == c.source_session_id,
               select: summary
             )
           ) do
      {:ok, summary}
    else
      _missing -> {:error, :not_found}
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  def get_session(crystal_id, session_id, partition) do
    with {:ok, partition} <- normalize_partition(partition),
         %ProjectedSession{} = session <-
           repo().one(
             from(c in Crystal,
               join: session in ProjectedSession,
               on: session.session_id == c.source_session_id,
               where:
                 c.id == ^crystal_id and c.source_session_id == ^session_id and
                   c.host_id == ^partition.host_id and c.client_id == ^partition.client_id and
                   c.scope == ^partition.scope and c.namespace == ^partition.namespace and
                   session.host_id == ^partition.host_id and
                   session.client_id == ^partition.client_id and session.scope == ^partition.scope and
                   session.namespace == ^partition.namespace,
               select: session
             )
           ) do
      {:ok, session}
    else
      _missing -> {:error, :not_found}
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  defp normalize_partition(partition) when is_map(partition) do
    normalized = %{
      host_id: Map.get(partition, :host_id, Map.get(partition, "host_id")),
      client_id: Map.get(partition, :client_id, Map.get(partition, "client_id")),
      scope: Map.get(partition, :scope, Map.get(partition, "scope")),
      namespace: Map.get(partition, :namespace, Map.get(partition, "namespace"))
    }

    if Enum.all?(normalized, fn {_key, value} -> is_binary(value) and String.trim(value) != "" end),
       do: {:ok, normalized},
       else: {:error, :not_found}
  end

  defp normalize_partition(_partition), do: {:error, :not_found}
  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)
end

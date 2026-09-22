defmodule Backplane.Memory.Profiles do
  @moduledoc "Context for reading and triggering project intelligence profiles."

  import Ecto.Query

  alias Backplane.Memory.Profiles.Profile
  alias Backplane.Memory.PartitionIdentity
  alias Backplane.Memory.Workers.ProfileBuildWorker

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)

  @doc "Return cached profile for project, or nil if not yet built."
  def get(project) when is_binary(project) do
    repo().one(
      from(profile in Profile,
        where:
          profile.project == ^project and is_nil(profile.host_id) and
            is_nil(profile.client_id) and is_nil(profile.scope) and is_nil(profile.namespace)
      )
    )
  end

  def get(project, partition) when is_binary(project) and is_map(partition) do
    with {:ok, partition} <- PartitionIdentity.validate(partition) do
      repo().get_by(Profile, Keyword.merge([project: project], partition_fields(partition)))
    end
  end

  @doc """
  Return a cached unpartitioned profile as `{:ok, profile}`, or `{:building, nil}`.
  """
  def get_or_build(project) when is_binary(project) do
    case get(project) do
      nil -> {:building, nil}
      profile -> {:ok, profile}
    end
  end

  @doc """
  Return a cached partitioned profile or enqueue a rebuild.
  Returns `{:ok, profile}`, `{:building, nil}`, or `{:error, reason}` when
  partition validation or enqueueing rejects the request.
  """
  def get_or_build(project, partition) when is_binary(project) and is_map(partition) do
    with {:ok, partition} <- PartitionIdentity.validate(partition) do
      case get(project, partition) do
        nil ->
          case ProfileBuildWorker.enqueue(project, partition) do
            {:ok, _job} -> {:building, nil}
            {:error, _reason} = error -> error
          end

        profile ->
          {:ok, profile}
      end
    end
  end

  defp partition_fields(partition) do
    for key <- [:memory_space_id, :scope, :namespace],
        do: {key, Map.fetch!(partition, key)}
  end
end

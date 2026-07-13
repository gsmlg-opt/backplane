defmodule Backplane.Memory.Profiles do
  @moduledoc "Context for reading and triggering project intelligence profiles."

  alias Backplane.Memory.Profiles.Profile
  alias Backplane.Memory.Workers.ProfileBuildWorker

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)

  @doc "Return cached profile for project, or nil if not yet built."
  def get(project) when is_binary(project) do
    repo().get(Profile, project)
  end

  @doc """
  Return cached profile or trigger async rebuild.
  Returns `{:ok, profile}` or `{:building, nil}`.
  """
  def get_or_build(project) when is_binary(project) do
    case get(project) do
      nil ->
        ProfileBuildWorker.enqueue(project)
        {:building, nil}

      profile ->
        {:ok, profile}
    end
  end
end

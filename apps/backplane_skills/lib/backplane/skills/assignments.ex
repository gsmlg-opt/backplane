defmodule Backplane.Skills.Assignments do
  @moduledoc """
  Public context for host skill assignments.
  """

  import Ecto.Query

  alias Backplane.Repo
  alias Backplane.Skills.{Host, HostAssignment, Skill}

  @doc "Assign a skill to a host agent."
  @spec assign_skill(Host.t(), Skill.t(), map()) ::
          {:ok, HostAssignment.t()} | {:error, Ecto.Changeset.t()}
  def assign_skill(%Host{} = host, %Skill{} = skill, attrs \\ %{}) when is_map(attrs) do
    params =
      attrs
      |> stringify_keys()
      |> Map.merge(%{"host_id" => host.id, "skill_id" => skill.id})

    %HostAssignment{}
    |> HostAssignment.changeset(params)
    |> Repo.insert()
  end

  @doc "Update a host skill assignment."
  @spec update_assignment(HostAssignment.t(), map()) ::
          {:ok, HostAssignment.t()} | {:error, Ecto.Changeset.t()}
  def update_assignment(%HostAssignment{} = assignment, attrs) when is_map(attrs) do
    assignment
    |> HostAssignment.changeset(stringify_keys(attrs))
    |> Repo.update()
  end

  @doc "List enabled skill assignments for a host agent."
  @spec list_enabled_for_host(Host.t()) :: [HostAssignment.t()]
  def list_enabled_for_host(%Host{id: host_id}) do
    HostAssignment
    |> where([assignment], assignment.host_id == ^host_id and assignment.enabled == true)
    |> Repo.all()
  end

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(values) when is_list(values), do: Enum.map(values, &stringify_keys/1)
  defp stringify_keys(value), do: value
end

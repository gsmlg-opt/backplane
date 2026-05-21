defmodule Backplane.Skills.DesiredState do
  @moduledoc """
  Builds the skill desired-state payload for authenticated host agents.
  """

  import Ecto.Query

  alias Backplane.Repo
  alias Backplane.Skills.{Host, HostAssignment, Skill}

  @doc "Return enabled archive-backed skill assignments for a host agent."
  @spec for_host(Host.t()) :: {:ok, map()}
  def for_host(%Host{} = host) do
    skills =
      HostAssignment
      |> where([assignment], assignment.host_id == ^host.id and assignment.enabled == true)
      |> join(:inner, [assignment], skill in Skill, on: skill.id == assignment.skill_id)
      |> where(
        [_assignment, skill],
        skill.enabled == true and skill.source_kind == "archive" and not is_nil(skill.archive_ref)
      )
      |> order_by([_assignment, skill], asc: skill.slug)
      |> select([assignment, skill], {assignment, skill})
      |> Repo.all()
      |> Enum.map(fn {assignment, skill} -> desired_skill(assignment, skill) end)

    {:ok, %{schema_version: 1, host: %{id: host.id, name: host.name}, skills: skills}}
  end

  defp desired_skill(%HostAssignment{} = assignment, %Skill{} = skill) do
    %{
      id: skill.id,
      slug: skill.slug,
      name: skill.name,
      version: skill.version,
      checksum: skill.content_hash,
      targets: assignment.targets,
      enabled: assignment.enabled,
      download_url: "/api/host-agent/skills/#{URI.encode_www_form(skill.slug)}/download"
    }
  end
end

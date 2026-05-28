defmodule Backplane.Skills.DesiredState do
  @moduledoc """
  Builds the skill desired-state payload for authenticated host agents.
  """

  import Ecto.Query

  alias Backplane.Repo
  alias Backplane.Skills.{AgentMcpServer, AgentMcpServers, Host, HostAssignment, Skill}

  @doc "Return enabled archive-backed skill assignments and MCP server configs for a host agent."
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

    mcp_servers =
      AgentMcpServers.list_enabled_for_host(host.id)
      |> Enum.map(&desired_mcp_server/1)

    {:ok,
     %{
       schema_version: 2,
       host: %{id: host.id, name: host.name},
       skills: skills,
       mcp_servers: mcp_servers
     }}
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

  defp desired_mcp_server(%AgentMcpServer{} = server) do
    base = %{
      id: server.id,
      name: server.name,
      prefix: server.prefix,
      transport: server.transport,
      enabled: server.enabled
    }

    case server.transport do
      "http" ->
        Map.put(base, :url, server.url)

      "stdio" ->
        base
        |> Map.put(:command, server.command)
        |> Map.put(:args, server.args || [])
        |> Map.put(:env, server.env || %{})

      _ ->
        base
    end
  end
end

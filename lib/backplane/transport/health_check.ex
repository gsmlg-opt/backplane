defmodule Backplane.Transport.HealthCheck do
  @moduledoc """
  Health check endpoint logic. Returns status of all engines.
  """

  alias Backplane.Docs.{DocChunk, Project}
  alias Backplane.Proxy.Pool
  alias Backplane.Registry.ToolRegistry
  alias Backplane.Repo
  alias Backplane.Skills.Registry, as: SkillsRegistry

  def check do
    upstreams = get_upstreams()
    degraded = Enum.any?(upstreams, fn u -> u.status != :connected end)

    %{
      status: if(degraded, do: "degraded", else: "ok"),
      engines: %{
        proxy: %{
          upstreams: upstreams,
          total_tools: ToolRegistry.count()
        },
        skills: %{
          total: SkillsRegistry.count()
        },
        docs: get_docs_summary(),
        git: %{status: "ok"}
      }
    }
  end

  defp get_upstreams do
    Pool.list_upstreams()
    |> Enum.map(fn u ->
      %{name: u.name, status: u.status, tool_count: u.tool_count}
    end)
  rescue
    _ -> []
  end

  defp get_docs_summary do
    project_count = Repo.aggregate(Project, :count)
    chunk_count = Repo.aggregate(DocChunk, :count)
    %{projects: project_count, chunks: chunk_count}
  rescue
    _ -> %{projects: 0, chunks: 0}
  end
end

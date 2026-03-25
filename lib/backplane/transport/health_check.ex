defmodule Backplane.Transport.HealthCheck do
  @moduledoc """
  Health check endpoint logic. Returns status of all engines.
  """

  def check do
    upstreams = get_upstreams()
    degraded = Enum.any?(upstreams, fn u -> u.status != :connected end)

    %{
      status: if(degraded, do: "degraded", else: "ok"),
      engines: %{
        proxy: %{
          upstreams: upstreams,
          total_tools: Backplane.Registry.ToolRegistry.count()
        },
        skills: %{
          total: Backplane.Skills.Registry.count()
        },
        docs: get_docs_summary(),
        git: %{status: "ok"}
      }
    }
  end

  defp get_upstreams do
    try do
      Backplane.Proxy.Pool.list_upstreams()
      |> Enum.map(fn u ->
        %{name: u.name, status: u.status, tool_count: u.tool_count}
      end)
    rescue
      _ -> []
    end
  end

  defp get_docs_summary do
    try do
      project_count = Backplane.Repo.aggregate(Backplane.Docs.Project, :count)
      chunk_count = Backplane.Repo.aggregate(Backplane.Docs.DocChunk, :count)
      %{projects: project_count, chunks: chunk_count}
    rescue
      _ -> %{projects: 0, chunks: 0}
    end
  end
end

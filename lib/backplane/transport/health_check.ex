defmodule Backplane.Transport.HealthCheck do
  @moduledoc """
  Health check endpoint logic. Returns status of all engines.
  """

  require Logger

  alias Backplane.Docs.{DocChunk, Project}
  alias Backplane.Proxy.Pool
  alias Backplane.Registry.ToolRegistry
  alias Backplane.Repo
  alias Backplane.Skills.Registry, as: SkillsRegistry

  @spec check() :: map()
  def check do
    upstreams = get_upstreams()
    docs = get_docs_summary()
    upstream_degraded = Enum.any?(upstreams, fn u -> u.status != :connected end)
    db_degraded = docs[:status] == "error"

    status =
      cond do
        db_degraded -> "degraded"
        upstream_degraded -> "degraded"
        true -> "ok"
      end

    %{
      status: status,
      engines: %{
        proxy: %{
          upstreams: upstreams,
          total_tools: ToolRegistry.count()
        },
        skills: %{
          total: SkillsRegistry.count()
        },
        docs: docs,
        git: get_git_summary()
      }
    }
  end

  defp get_upstreams do
    Pool.list_upstreams()
    |> Enum.map(fn u ->
      %{
        name: u.name,
        status: u.status,
        tool_count: u.tool_count,
        last_ping_at: u[:last_ping_at],
        last_pong_at: u[:last_pong_at],
        consecutive_ping_failures: u[:consecutive_ping_failures] || 0
      }
    end)
  rescue
    e ->
      Logger.warning("Failed to get upstreams: #{Exception.message(e)}")
      []
  end

  defp get_git_summary do
    providers = Application.get_env(:backplane, :git_providers, %{})

    provider_count =
      Enum.sum(for {_type, instances} <- providers, is_list(instances), do: length(instances))

    %{status: "ok", providers: provider_count}
  rescue
    e ->
      Logger.warning("Failed to get git summary: #{Exception.message(e)}")
      %{status: "unknown", providers: 0}
  end

  defp get_docs_summary do
    project_count = Repo.aggregate(Project, :count)
    chunk_count = Repo.aggregate(DocChunk, :count)
    %{status: "ok", projects: project_count, chunks: chunk_count}
  rescue
    e ->
      Logger.warning("Failed to get docs summary: #{Exception.message(e)}")
      %{status: "error", projects: 0, chunks: 0}
  end
end

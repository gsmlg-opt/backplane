defmodule Backplane.Transport.HealthCheck do
  @moduledoc """
  Health check endpoint logic. Returns status of all engines.
  """

  require Logger

  alias Backplane.Proxy.Pool
  alias Backplane.Registry.ToolRegistry
  alias Backplane.Skills.Registry, as: SkillsRegistry

  @spec check() :: map()
  def check do
    upstreams = get_upstreams()
    upstream_degraded = Enum.any?(upstreams, fn u -> u.status != :connected end)

    status =
      if upstream_degraded do
        "degraded"
      else
        "ok"
      end

    %{
      status: status,
      version: Backplane.version(),
      engines: %{
        proxy: %{
          upstreams: upstreams,
          total_tools: ToolRegistry.count()
        },
        skills: %{
          total: SkillsRegistry.count()
        }
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

end

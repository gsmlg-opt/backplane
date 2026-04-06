defmodule Backplane.Metrics.Prometheus do
  @moduledoc """
  Hand-rolled Prometheus exposition format renderer.
  Reads from ETS counters maintained by Backplane.Metrics.
  """

  alias Backplane.Cache
  alias Backplane.Metrics
  alias Backplane.Proxy.Pool
  alias Backplane.Registry.ToolRegistry
  alias Backplane.Skills.Registry, as: SkillsRegistry

  require Logger

  @doc "Render all metrics in Prometheus text exposition format."
  @spec render() :: String.t()
  def render do
    snapshot = Metrics.snapshot()

    [
      render_tool_calls(snapshot),
      render_tool_call_duration(snapshot),
      render_upstream_status(),
      render_cache_metrics(),
      render_gauges()
    ]
    |> List.flatten()
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp render_tool_calls(snapshot) do
    total = get_counter(snapshot, "tool_calls_total")
    success = get_counter(snapshot, "tool_calls_success")
    errors = get_counter(snapshot, "tool_calls_errors")

    [
      "# HELP backplane_tool_calls_total Total tool calls",
      "# TYPE backplane_tool_calls_total counter",
      "backplane_tool_calls_total{status=\"ok\"} #{success}",
      "backplane_tool_calls_total{status=\"error\"} #{errors}",
      "backplane_tool_calls_total #{total}"
    ]
  end

  defp render_tool_call_duration(snapshot) do
    timing = get_in(snapshot, [:timings, "tool_call_duration"]) || %{count: 0, avg_us: 0}

    [
      "# HELP backplane_tool_call_duration_microseconds Tool call latency",
      "# TYPE backplane_tool_call_duration_microseconds summary",
      "backplane_tool_call_duration_microseconds_count #{timing[:count] || 0}",
      "backplane_tool_call_duration_microseconds_sum #{timing[:total_us] || 0}"
    ]
  end

  defp render_upstream_status do
    upstreams =
      try do
        Pool.list_upstreams()
      rescue
        _ -> []
      end

    lines = [
      "# HELP backplane_upstream_status Upstream connection status (1=connected, 0=disconnected)",
      "# TYPE backplane_upstream_status gauge"
    ]

    upstream_lines =
      Enum.map(upstreams, fn u ->
        value = if u.status == :connected, do: 1, else: 0
        "backplane_upstream_status{upstream=\"#{u.name}\"} #{value}"
      end)

    lines ++ upstream_lines
  end

  defp render_cache_metrics do
    stats = Cache.stats()

    [
      "# HELP backplane_cache_hit_ratio Cache hit ratio",
      "# TYPE backplane_cache_hit_ratio gauge",
      "backplane_cache_hit_ratio #{stats.hit_rate}",
      "# HELP backplane_cache_entries Current cache entry count",
      "# TYPE backplane_cache_entries gauge",
      "backplane_cache_entries #{stats.size}",
      "# HELP backplane_cache_evictions_total Total cache evictions",
      "# TYPE backplane_cache_evictions_total counter",
      "backplane_cache_evictions_total #{stats.evictions}"
    ]
  end

  defp render_gauges do
    tool_count =
      try do
        ToolRegistry.count()
      rescue
        _ -> 0
      end

    skill_count =
      try do
        SkillsRegistry.count()
      rescue
        _ -> 0
      end

    [
      "# HELP backplane_tool_count Total registered tools",
      "# TYPE backplane_tool_count gauge",
      "backplane_tool_count #{tool_count}",
      "# HELP backplane_skill_count Total registered skills",
      "# TYPE backplane_skill_count gauge",
      "backplane_skill_count #{skill_count}"
    ]
  end

  defp get_counter(snapshot, name) do
    get_in(snapshot, [:counters, name]) || 0
  end
end

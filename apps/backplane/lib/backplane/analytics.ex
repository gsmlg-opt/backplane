defmodule Backplane.Analytics do
  @moduledoc """
  Aggregate query functions over audit logs.
  All queries use inserted_at filtering to avoid full table scans.
  """

  import Ecto.Query

  alias Backplane.Audit.{SkillLoadLog, ToolCallLog}
  alias Backplane.Repo

  @doc "Tool call summary grouped by tool name for a time period."
  @spec tool_call_summary(:day | :week | :month) :: [map()]
  def tool_call_summary(period \\ :day) do
    cutoff = period_cutoff(period)

    ToolCallLog
    |> where([l], l.inserted_at >= ^cutoff)
    |> group_by([l], l.tool_name)
    |> select([l], %{
      tool_name: l.tool_name,
      call_count: count(l.id),
      error_count: count(fragment("CASE WHEN ? = 'error' THEN 1 END", l.status)),
      avg_duration_us: avg(l.duration_us),
      p50_duration_us: fragment("percentile_cont(0.5) WITHIN GROUP (ORDER BY ?)", l.duration_us),
      p99_duration_us: fragment("percentile_cont(0.99) WITHIN GROUP (ORDER BY ?)", l.duration_us)
    })
    |> order_by([l], desc: count(l.id))
    |> Repo.all()
    |> Enum.map(fn row ->
      %{
        row
        | avg_duration_us: safe_float(row.avg_duration_us),
          p50_duration_us: safe_int(row.p50_duration_us),
          p99_duration_us: safe_int(row.p99_duration_us)
      }
    end)
  end

  @doc "Tool calls grouped by client for a time period."
  @spec tool_calls_by_client(:day | :week | :month) :: [map()]
  def tool_calls_by_client(period \\ :day) do
    cutoff = period_cutoff(period)

    ToolCallLog
    |> where([l], l.inserted_at >= ^cutoff)
    |> group_by([l], l.client_name)
    |> select([l], %{
      client_name: l.client_name,
      call_count: count(l.id),
      unique_tools: fragment("COUNT(DISTINCT ?)", l.tool_name)
    })
    |> order_by([l], desc: count(l.id))
    |> Repo.all()
  end

  @doc "Skill load summary grouped by skill name for a time period."
  @spec skill_load_summary(:day | :week | :month) :: [map()]
  def skill_load_summary(period \\ :day) do
    cutoff = period_cutoff(period)

    SkillLoadLog
    |> where([l], l.inserted_at >= ^cutoff)
    |> group_by([l], l.skill_name)
    |> select([l], %{
      skill_name: l.skill_name,
      load_count: count(l.id),
      unique_clients: fragment("COUNT(DISTINCT ?)", l.client_name)
    })
    |> order_by([l], desc: count(l.id))
    |> Repo.all()
  end

  @doc "Top tools by call count."
  @spec top_tools(pos_integer()) :: [map()]
  def top_tools(limit \\ 10) do
    ToolCallLog
    |> group_by([l], l.tool_name)
    |> select([l], %{tool_name: l.tool_name, count: count(l.id)})
    |> order_by([l], desc: count(l.id))
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "Top skills by load count."
  @spec top_skills(pos_integer()) :: [map()]
  def top_skills(limit \\ 10) do
    SkillLoadLog
    |> group_by([l], l.skill_name)
    |> select([l], %{skill_name: l.skill_name, count: count(l.id)})
    |> order_by([l], desc: count(l.id))
    |> limit(^limit)
    |> Repo.all()
  end

  defp period_cutoff(:day), do: DateTime.utc_now() |> DateTime.add(-86_400, :second)
  defp period_cutoff(:week), do: DateTime.utc_now() |> DateTime.add(-604_800, :second)
  defp period_cutoff(:month), do: DateTime.utc_now() |> DateTime.add(-2_592_000, :second)

  defp safe_float(nil), do: 0.0
  defp safe_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp safe_float(f) when is_float(f), do: f
  defp safe_float(i) when is_integer(i), do: i / 1

  defp safe_int(nil), do: 0
  defp safe_int(f) when is_float(f), do: round(f)
  defp safe_int(i) when is_integer(i), do: i
  defp safe_int(%Decimal{} = d), do: Decimal.to_integer(Decimal.round(d))
end

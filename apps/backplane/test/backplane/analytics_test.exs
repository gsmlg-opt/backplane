defmodule Backplane.AnalyticsTest do
  use Backplane.DataCase, async: true

  alias Backplane.Analytics
  alias Backplane.Audit.{SkillLoadLog, ToolCallLog}

  setup do
    now = DateTime.utc_now()

    for i <- 1..5 do
      Repo.insert!(%ToolCallLog{
        tool_name: "docs::query-docs",
        status: "ok",
        duration_us: 1000 * i,
        client_name: "client-a",
        inserted_at: now
      })
    end

    for i <- 1..3 do
      Repo.insert!(%ToolCallLog{
        tool_name: "git::repo-tree",
        status: if(i == 1, do: "error", else: "ok"),
        duration_us: 2000 * i,
        client_name: "client-b",
        inserted_at: now
      })
    end

    Repo.insert!(%SkillLoadLog{
      skill_name: "elixir-review",
      client_name: "client-a",
      loaded_deps: ["base-lib"],
      inserted_at: now
    })

    :ok
  end

  describe "tool_call_summary/1" do
    test "aggregates call counts by tool" do
      results = Analytics.tool_call_summary(:day)

      docs = Enum.find(results, &(&1.tool_name == "docs::query-docs"))
      git = Enum.find(results, &(&1.tool_name == "git::repo-tree"))

      assert docs.call_count == 5
      assert git.call_count == 3
    end

    test "computes correct avg_duration from log data" do
      results = Analytics.tool_call_summary(:day)

      docs = Enum.find(results, &(&1.tool_name == "docs::query-docs"))
      # durations: 1000, 2000, 3000, 4000, 5000 -> avg = 3000.0
      assert_in_delta docs.avg_duration_us, 3000.0, 0.1
    end

    test "groups by day period correctly" do
      results = Analytics.tool_call_summary(:day)
      assert length(results) == 2
    end

    test "excludes data outside period" do
      old_time = DateTime.utc_now() |> DateTime.add(-2 * 86_400, :second)

      Repo.insert!(%ToolCallLog{
        tool_name: "old::tool",
        status: "ok",
        duration_us: 999,
        client_name: "client-x",
        inserted_at: old_time
      })

      results = Analytics.tool_call_summary(:day)
      tool_names = Enum.map(results, & &1.tool_name)
      refute "old::tool" in tool_names
    end
  end

  describe "tool_calls_by_client/1" do
    test "groups by client" do
      results = Analytics.tool_calls_by_client(:day)

      client_a = Enum.find(results, &(&1.client_name == "client-a"))
      client_b = Enum.find(results, &(&1.client_name == "client-b"))

      assert client_a.call_count == 5
      assert client_b.call_count == 3
    end

    test "counts unique tools per client" do
      results = Analytics.tool_calls_by_client(:day)

      client_a = Enum.find(results, &(&1.client_name == "client-a"))
      client_b = Enum.find(results, &(&1.client_name == "client-b"))

      assert client_a.unique_tools == 1
      assert client_b.unique_tools == 1
    end
  end

  describe "skill_load_summary/1" do
    test "aggregates by skill name" do
      results = Analytics.skill_load_summary(:day)

      skill = Enum.find(results, &(&1.skill_name == "elixir-review"))
      assert skill.load_count == 1
    end

    test "counts unique clients" do
      # Add another load from a different client
      Repo.insert!(%SkillLoadLog{
        skill_name: "elixir-review",
        client_name: "client-b",
        loaded_deps: [],
        inserted_at: DateTime.utc_now()
      })

      results = Analytics.skill_load_summary(:day)
      skill = Enum.find(results, &(&1.skill_name == "elixir-review"))

      assert skill.load_count == 2
      assert skill.unique_clients == 2
    end
  end

  describe "top_tools/1" do
    test "returns tools ordered by call count" do
      results = Analytics.top_tools(10)

      assert length(results) == 2
      assert hd(results).tool_name == "docs::query-docs"
      assert hd(results).count == 5
    end

    test "respects limit" do
      results = Analytics.top_tools(1)

      assert length(results) == 1
      assert hd(results).tool_name == "docs::query-docs"
    end
  end
end

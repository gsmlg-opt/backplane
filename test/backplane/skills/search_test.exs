defmodule Backplane.Skills.SearchTest do
  use Backplane.DataCase, async: true

  alias Backplane.Repo
  alias Backplane.Skills.{Search, Skill}

  setup do
    insert_skill(
      "s1",
      "GenServer Patterns",
      "Best practices for GenServer",
      ["elixir", "otp"],
      "db",
      true
    )

    insert_skill(
      "s2",
      "Phoenix LiveView",
      "Building real-time apps with LiveView",
      ["phoenix", "elixir"],
      "db",
      true
    )

    insert_skill(
      "s3",
      "Ecto Queries",
      "Advanced Ecto query composition",
      ["elixir", "ecto"],
      "git:myskills",
      true
    )

    insert_skill("s4", "Disabled Skill", "Should not appear", ["hidden"], "db", false)

    insert_skill(
      "s5",
      "React Components",
      "React component patterns",
      ["react", "frontend"],
      "local:web",
      true
    )

    :ok
  end

  describe "query/2" do
    test "finds skills by name match (weighted highest)" do
      results = Search.query("GenServer")
      names = Enum.map(results, & &1.name)
      assert "GenServer Patterns" in names
    end

    test "finds skills by description match" do
      results = Search.query("real-time")
      names = Enum.map(results, & &1.name)
      assert "Phoenix LiveView" in names
    end

    test "finds skills by content match (weighted lower)" do
      results = Search.query("query composition")
      names = Enum.map(results, & &1.name)
      assert "Ecto Queries" in names
    end

    test "finds skills by tag match" do
      results = Search.query("otp")
      names = Enum.map(results, & &1.name)
      assert "GenServer Patterns" in names
    end

    test "filters by tags (AND match)" do
      results = Search.query("elixir", tags: ["otp"])
      names = Enum.map(results, & &1.name)
      assert "GenServer Patterns" in names
      refute "Phoenix LiveView" in names
    end

    test "filters by source type" do
      results = Search.query("elixir", source: "git")
      names = Enum.map(results, & &1.name)
      assert "Ecto Queries" in names
      refute "GenServer Patterns" in names
    end

    test "filters by required tools (AND match)" do
      # Insert a skill with specific tools
      insert_skill_with_tools(
        "s6",
        "Docker Deployment",
        "Deploy with Docker",
        ["devops"],
        ["git::repo-tree", "git::file-content"],
        "db",
        true
      )

      results = Search.query("Docker", tools: ["git::repo-tree"])
      names = Enum.map(results, & &1.name)
      assert "Docker Deployment" in names

      results = Search.query("Docker", tools: ["git::repo-tree", "nonexistent::tool"])
      names = Enum.map(results, & &1.name)
      refute "Docker Deployment" in names
    end

    test "excludes disabled skills" do
      results = Search.query("Disabled")
      names = Enum.map(results, & &1.name)
      refute "Disabled Skill" in names
    end

    test "respects limit" do
      results = Search.query("elixir", limit: 1)
      assert length(results) <= 1
    end

    test "returns empty for no matches" do
      results = Search.query("zzznonexistent")
      assert results == []
    end

    test "returns all enabled skills when search is nil" do
      results = Search.query(nil)
      names = Enum.map(results, & &1.name)
      # Should return enabled skills ordered by name (no relevance ranking)
      assert "GenServer Patterns" in names
      assert "Phoenix LiveView" in names
      refute "Disabled Skill" in names
    end

    test "returns all enabled skills when search is empty string" do
      results = Search.query("")
      names = Enum.map(results, & &1.name)
      assert "GenServer Patterns" in names
      assert "Phoenix LiveView" in names
      refute "Disabled Skill" in names
    end
  end

  defp insert_skill(id, name, description, tags, source, enabled) do
    insert_skill_with_tools(id, name, description, tags, [], source, enabled)
  end

  defp insert_skill_with_tools(id, name, description, tags, tools, source, enabled) do
    content = "# #{name}\n\n#{description}\n\nDetailed content about #{Enum.join(tags, ", ")}."
    hash = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

    %Skill{}
    |> Skill.changeset(%{
      id: id,
      name: name,
      description: description,
      tags: tags,
      tools: tools,
      content: content,
      content_hash: hash,
      source: source,
      enabled: enabled
    })
    |> Repo.insert!()
  end
end

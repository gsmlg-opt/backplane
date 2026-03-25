defmodule Backplane.Hub.DiscoverTest do
  use Backplane.DataCase, async: false

  alias Backplane.Hub.Discover
  alias Backplane.Skills.{Skill, Registry}

  setup do
    # Clear tool registry (app registers tools on boot, so they're there)
    # Insert a skill for search
    content = "# Elixir GenServer patterns and best practices"
    hash = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

    %Skill{}
    |> Skill.changeset(%{
      id: "disc/elixir",
      name: "Elixir Patterns",
      description: "Design patterns for Elixir",
      tags: ["elixir"],
      content: content,
      content_hash: hash,
      source: "db",
      enabled: true
    })
    |> Repo.insert!()

    if :ets.whereis(:backplane_skills) != :undefined do
      Registry.refresh()
    end

    :ok
  end

  describe "search/2" do
    test "returns results across tools, skills, docs" do
      {:ok, results} = Discover.search("elixir")
      assert is_list(results.tools)
      assert is_list(results.skills)
      assert is_list(results.docs)
      assert is_list(results.repos)
    end

    test "scopes to tools only when scope: [tools]" do
      {:ok, results} = Discover.search("skill", scope: ["tools"])
      assert length(results.tools) > 0
      assert results.skills == []
      assert results.docs == []
      assert results.repos == []
    end

    test "scopes to skills only when scope: [skills]" do
      {:ok, results} = Discover.search("elixir", scope: ["skills"])
      assert results.tools == []
      assert length(results.skills) > 0
    end

    test "scopes to docs only when scope: [docs]" do
      {:ok, results} = Discover.search("test", scope: ["docs"])
      assert results.tools == []
      assert results.skills == []
      assert is_list(results.docs)
    end

    test "scopes to repos only when scope: [repos]" do
      {:ok, results} = Discover.search("test", scope: ["repos"])
      assert results.tools == []
      assert results.skills == []
      assert results.docs == []
      assert is_list(results.repos)
    end

    test "limits results per scope" do
      {:ok, results} = Discover.search("skill", scope: ["tools"], limit: 1)
      assert length(results.tools) <= 1
    end

    test "returns empty groups for no matches" do
      {:ok, results} = Discover.search("zzzznonexistent999")
      assert results.tools == []
      assert results.skills == []
    end

    test "handles missing engines gracefully" do
      {:ok, results} = Discover.search("anything")
      assert is_map(results)
      assert Map.has_key?(results, :tools)
      assert Map.has_key?(results, :skills)
      assert Map.has_key?(results, :docs)
      assert Map.has_key?(results, :repos)
    end
  end
end

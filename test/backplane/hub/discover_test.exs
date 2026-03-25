defmodule Backplane.Hub.DiscoverTest do
  use Backplane.DataCase, async: false

  alias Backplane.Hub.Discover
  alias Backplane.Skills.{Registry, Skill}

  setup do
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

    # Ensure native tools are registered in the tool registry
    if :ets.whereis(:backplane_tools) != :undefined do
      alias Backplane.Registry.{Tool, ToolRegistry}

      for module <- [
            Backplane.Tools.Skill,
            Backplane.Tools.Docs,
            Backplane.Tools.Git,
            Backplane.Tools.Hub
          ],
          tool_def <- module.tools() do
        tool = %Tool{
          name: tool_def.name,
          description: tool_def.description,
          input_schema: tool_def.input_schema,
          origin: :native,
          module: tool_def.module,
          handler: tool_def.handler
        }

        ToolRegistry.register_native(tool)
      end
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
      assert results.tools != []
      assert results.skills == []
      assert results.docs == []
      assert results.repos == []
    end

    test "scopes to skills only when scope: [skills]" do
      {:ok, results} = Discover.search("elixir", scope: ["skills"])
      assert results.tools == []
      assert results.skills != []
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

    test "search_repos returns matching projects by id" do
      Repo.insert!(
        %Backplane.Docs.Project{
          id: "discover-repo-test",
          repo: "https://github.com/test/discover-repo.git",
          ref: "main",
          description: "A test project for discovery"
        },
        on_conflict: :nothing
      )

      {:ok, results} = Discover.search("discover-repo", scope: ["repos"])
      assert Enum.any?(results.repos, fn r -> r.id == "discover-repo-test" end)
    end

    test "search_repos returns matching projects by description" do
      Repo.insert!(
        %Backplane.Docs.Project{
          id: "desc-search-proj",
          repo: "https://github.com/test/desc.git",
          ref: "main",
          description: "Unique searchable description for hub discovery"
        },
        on_conflict: :nothing
      )

      {:ok, results} = Discover.search("Unique searchable description", scope: ["repos"])
      assert Enum.any?(results.repos, fn r -> r.id == "desc-search-proj" end)
    end

    test "search_repos maps project fields correctly" do
      Repo.insert!(
        %Backplane.Docs.Project{
          id: "field-map-proj",
          repo: "https://github.com/test/fields.git",
          ref: "main",
          description: "Field mapping test"
        },
        on_conflict: :nothing
      )

      {:ok, results} = Discover.search("field-map-proj", scope: ["repos"])
      [proj | _] = results.repos
      assert Map.has_key?(proj, :id)
      assert Map.has_key?(proj, :repo)
      assert Map.has_key?(proj, :description)
    end

    test "search with multiple scopes returns data for each" do
      {:ok, results} = Discover.search("skill", scope: ["tools", "skills"])
      assert is_list(results.tools)
      assert is_list(results.skills)
      assert results.docs == []
      assert results.repos == []
    end
  end
end

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
      true
    )

    insert_skill(
      "s2",
      "Phoenix LiveView",
      "Building real-time apps with LiveView",
      ["phoenix", "elixir"],
      true
    )

    insert_skill(
      "s3",
      "Ecto Queries",
      "Advanced Ecto query composition",
      ["elixir", "ecto"],
      true
    )

    insert_skill("s4", "Disabled Skill", "Should not appear", ["hidden"], false)

    insert_skill(
      "s5",
      "React Components",
      "React component patterns",
      ["react", "frontend"],
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

    test "finds skills by tag match via search_vector" do
      results = Search.query("otp")
      names = Enum.map(results, & &1.name)
      assert "GenServer Patterns" in names
    end

    test "tags in search_vector have higher weight than content" do
      # "frontend" only appears as a tag on s5, not in name/description
      results = Search.query("frontend")
      names = Enum.map(results, & &1.name)
      assert "React Components" in names
    end

    test "filters by tags (AND match)" do
      results = Search.query("elixir", tags: ["otp"])
      names = Enum.map(results, & &1.name)
      assert "GenServer Patterns" in names
      refute "Phoenix LiveView" in names
    end

    test "includes archive metadata and omits content" do
      [result] = Search.query("GenServer")

      assert result.slug == "genserver-patterns"
      assert result.version == "1.0.0"
      assert result.license == "MIT"
      assert result.homepage == "https://example.com/genserver-patterns"
      assert result.content_hash
      assert result.archive_ref == "sha256/#{String.duplicate("a", 64)}.tar.gz"
      assert result.size_bytes == 123
      assert result.file_count == 2
      refute Map.has_key?(result, :content)
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

  defp insert_skill(id, name, description, tags, enabled) do
    content = "# #{name}\n\n#{description}\n\nDetailed content about #{Enum.join(tags, ", ")}."
    hash = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
    slug = Backplane.Skills.Skill.slugify(name)

    %Skill{}
    |> Skill.changeset(%{
      id: id,
      slug: slug,
      name: name,
      description: description,
      tags: tags,
      content: content,
      content_hash: hash,
      version: "1.0.0",
      license: "MIT",
      homepage: "https://example.com/#{slug}",
      archive_ref: "sha256/#{String.duplicate("a", 64)}.tar.gz",
      size_bytes: 123,
      file_count: 2,
      enabled: enabled
    })
    |> Repo.insert!()
  end
end

defmodule Backplane.Skills.SearchTest do
  use Backplane.DataCase, async: true

  alias Backplane.Repo
  alias Backplane.Skills.{Search, Skill}

  setup do
    insert_skill("s1", "GenServer Patterns", "Best practices for GenServer", ["elixir", "otp"])

    insert_skill("s2", "Phoenix LiveView", "Building real-time apps with LiveView", [
      "phoenix",
      "elixir"
    ])

    insert_skill("s3", "Ecto Queries", "Advanced Ecto query composition", ["elixir", "ecto"],
      version: "1.2.3",
      license: "MIT",
      homepage: "https://example.com/ecto",
      archive_ref:
        "sha256/abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd.tar.gz",
      source_kind: "archive",
      size_bytes: 4096,
      file_count: 7
    )

    insert_skill("s4", "Disabled Skill", "Should not appear", ["hidden"], enabled: false)
    insert_skill("s5", "React Components", "React component patterns", ["react", "frontend"])

    :ok
  end

  describe "query/2" do
    test "finds skills by full-text query" do
      results = Search.query("GenServer")
      names = Enum.map(results, & &1.name)
      assert "GenServer Patterns" in names
    end

    test "finds skills by description match" do
      results = Search.query("real-time")
      names = Enum.map(results, & &1.name)
      assert "Phoenix LiveView" in names
    end

    test "finds skills by content match" do
      results = Search.query("query composition")
      names = Enum.map(results, & &1.name)
      assert "Ecto Queries" in names
    end

    test "finds skills by tag text stored in content" do
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

    test "requires all tags in the tag filter" do
      results = Search.query(nil, tags: ["elixir", "ecto"])
      names = Enum.map(results, & &1.name)
      assert names == ["Ecto Queries"]
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

    test "filters to archive-backed skills when archive_only is true" do
      results = Search.query("elixir", archive_only: true)
      names = Enum.map(results, & &1.name)

      assert names == ["Ecto Queries"]
    end

    test "includes v1 metadata fields in results" do
      [result] = Search.query("Ecto")

      assert result == %{
               id: "s3",
               slug: "ecto-queries",
               name: "Ecto Queries",
               description: "Advanced Ecto query composition",
               tags: ["elixir", "ecto"],
               version: "1.2.3",
               license: "MIT",
               homepage: "https://example.com/ecto",
               content_hash: result.content_hash,
               archive_ref:
                 "sha256/abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd.tar.gz",
               size_bytes: 4096,
               file_count: 7
             }

      assert byte_size(result.content_hash) == 64
    end

    test "omits full content from search results" do
      [result] = Search.query("GenServer")

      refute Map.has_key?(result, :content)
    end

    test "returns empty for no matches" do
      results = Search.query("zzznonexistent")
      assert results == []
    end

    test "returns all enabled skills when search is nil" do
      results = Search.query(nil)
      names = Enum.map(results, & &1.name)

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

  defp insert_skill(id, name, description, tags, attrs \\ []) do
    content = "# #{name}\n\n#{description}\n\nDetailed content about #{Enum.join(tags, ", ")}."
    hash = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

    base_attrs = %{
      id: id,
      slug: slugify(name),
      name: name,
      description: description,
      tags: tags,
      content: content,
      content_hash: hash,
      enabled: true
    }

    %Skill{}
    |> Skill.changeset(Map.merge(base_attrs, Map.new(attrs)))
    |> Repo.insert!()
  end

  defp slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end
end

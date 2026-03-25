defmodule Backplane.Skills.LoaderTest do
  use ExUnit.Case, async: true

  alias Backplane.Skills.Loader

  @valid_skill """
  ---
  name: elixir-genserver
  description: Best practices for GenServer design
  tags: [elixir, otp, genserver]
  tools: [file_read, file_write]
  model: claude-sonnet-4
  version: "1.2.0"
  ---

  # GenServer Production Patterns

  ## When to Use a GenServer
  Use GenServer when you need stateful processes.
  """

  @minimal_skill """
  ---
  name: minimal-skill
  ---

  Just some content.
  """

  describe "parse/1" do
    test "extracts name from frontmatter" do
      {:ok, entry} = Loader.parse(@valid_skill)
      assert entry.name == "elixir-genserver"
    end

    test "extracts description from frontmatter" do
      {:ok, entry} = Loader.parse(@valid_skill)
      assert entry.description == "Best practices for GenServer design"
    end

    test "extracts tags array from frontmatter" do
      {:ok, entry} = Loader.parse(@valid_skill)
      assert entry.tags == ["elixir", "otp", "genserver"]
    end

    test "extracts tools array from frontmatter" do
      {:ok, entry} = Loader.parse(@valid_skill)
      assert entry.tools == ["file_read", "file_write"]
    end

    test "extracts model from frontmatter (optional)" do
      {:ok, entry} = Loader.parse(@valid_skill)
      assert entry.model == "claude-sonnet-4"
    end

    test "extracts version from frontmatter" do
      {:ok, entry} = Loader.parse(@valid_skill)
      assert entry.version == "1.2.0"
    end

    test "extracts markdown body after frontmatter" do
      {:ok, entry} = Loader.parse(@valid_skill)
      assert String.contains?(entry.content, "GenServer Production Patterns")
    end

    test "handles minimal frontmatter (only name)" do
      {:ok, entry} = Loader.parse(@minimal_skill)
      assert entry.name == "minimal-skill"
    end

    test "defaults missing fields (tags -> [], version -> 1.0.0)" do
      {:ok, entry} = Loader.parse(@minimal_skill)
      assert entry.tags == []
      assert entry.version == "1.0.0"
    end

    test "computes SHA256 content_hash" do
      {:ok, entry} = Loader.parse(@valid_skill)
      assert is_binary(entry.content_hash)
      assert String.length(entry.content_hash) == 64
    end

    test "returns error for missing frontmatter" do
      assert {:error, :missing_frontmatter} = Loader.parse("No frontmatter here")
    end

    test "returns error for malformed YAML in frontmatter" do
      bad = """
      ---
      name: [invalid: yaml: {broken
      ---

      Content.
      """

      assert {:error, :malformed_frontmatter} = Loader.parse(bad)
    end

    test "returns error when YAML parses to non-map (e.g. a list)" do
      bad = """
      ---
      - item1
      - item2
      ---

      Content.
      """

      assert {:error, :malformed_frontmatter} = Loader.parse(bad)
    end

    test "returns error when name is missing from frontmatter" do
      bad = """
      ---
      description: No name provided
      tags: [test]
      ---

      Content.
      """

      assert {:error, :missing_frontmatter} = Loader.parse(bad)
    end

    test "returns error when text before frontmatter delimiters" do
      bad = "Some text before\n---\nname: test\n---\nContent."
      assert {:error, :missing_frontmatter} = Loader.parse(bad)
    end

    test "handles tags as non-list (string) gracefully" do
      skill = """
      ---
      name: string-tags
      tags: not-a-list
      ---

      Content.
      """

      {:ok, entry} = Loader.parse(skill)
      assert entry.tags == []
    end

    test "handles whitespace before first --- delimiter" do
      skill = """
        \n---
      name: whitespace-test
      ---

      Content.
      """

      {:ok, entry} = Loader.parse(skill)
      assert entry.name == "whitespace-test"
    end

    test "version is converted to string when given as number" do
      skill = """
      ---
      name: version-num
      version: 2
      ---

      Content.
      """

      {:ok, entry} = Loader.parse(skill)
      assert entry.version == "2"
    end
  end
end

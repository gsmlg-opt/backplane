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
  end
end

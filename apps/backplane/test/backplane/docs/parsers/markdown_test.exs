defmodule Backplane.Docs.Parsers.MarkdownTest do
  use ExUnit.Case, async: true

  alias Backplane.Docs.Parsers.Markdown

  describe "parse/2" do
    test "splits on ## headings" do
      content = """
      ## Installation

      Run `mix deps.get`

      ## Usage

      Call the function.
      """

      {:ok, chunks} = Markdown.parse(content, "README.md")
      assert length(chunks) == 2

      assert Enum.at(chunks, 0).content =~ "Installation"
      assert Enum.at(chunks, 0).content =~ "mix deps.get"
      assert Enum.at(chunks, 1).content =~ "Usage"
    end

    test "all chunks have guide type" do
      content = "## Section\n\nSome content."
      {:ok, chunks} = Markdown.parse(content, "guide.md")

      Enum.each(chunks, fn chunk ->
        assert chunk.chunk_type == "guide"
      end)
    end

    test "handles document with no headings as single chunk" do
      content = "Just some text without any headings.\n\nAnother paragraph."
      {:ok, chunks} = Markdown.parse(content, "notes.md")
      assert length(chunks) == 1
      assert hd(chunks).content =~ "Just some text"
    end

    test "handles empty document" do
      {:ok, chunks} = Markdown.parse("", "empty.md")
      assert chunks == []
    end

    test "preserves heading text in content" do
      content = "## My Heading\n\nBody text here."
      {:ok, chunks} = Markdown.parse(content, "doc.md")
      assert [chunk] = chunks
      assert chunk.content =~ "## My Heading"
      assert chunk.content =~ "Body text here"
    end

    test "handles # top-level heading" do
      content = """
      # Title

      Some intro text.

      ## Section

      Section content.
      """

      {:ok, chunks} = Markdown.parse(content, "README.md")
      assert length(chunks) >= 2
    end

    test "sets source_path correctly" do
      content = "## Test\n\nContent."
      {:ok, chunks} = Markdown.parse(content, "docs/guide.md")

      Enum.each(chunks, fn chunk ->
        assert chunk.source_path == "docs/guide.md"
      end)
    end

    test "includes preamble text before first heading" do
      content = "Some preamble text here.\n\n## First Section\n\nSection body."
      {:ok, chunks} = Markdown.parse(content, "doc.md")
      assert length(chunks) == 2

      preamble = Enum.find(chunks, fn c -> c.content =~ "preamble" end)
      assert preamble != nil
      assert preamble.chunk_type == "guide"
    end

    test "skips empty chunks from whitespace-only sections" do
      content = "## Heading\n\n\n\n## Another\n\nContent here."
      {:ok, chunks} = Markdown.parse(content, "doc.md")

      # Empty section between headings should be filtered out
      Enum.each(chunks, fn chunk ->
        refute chunk.content == ""
      end)
    end

    test "drops orphan lines after the last section has been finalized" do
      # Lines that appear after a section is finalized but before a new heading
      # and when sections already exist — hits the `true -> {sections, current}` branch
      content = "## First\n\nContent.\n\n## Second\n\nMore content."
      {:ok, chunks} = Markdown.parse(content, "doc.md")
      assert length(chunks) == 2
    end
  end

  describe "parse/2 with fixture files" do
    test "parses guide_with_headings.md fixture" do
      content = Backplane.Fixtures.read_fixture("markdown", "guide_with_headings.md")
      {:ok, chunks} = Markdown.parse(content, "docs/guide.md")

      assert length(chunks) >= 4
      assert Enum.all?(chunks, fn c -> c.chunk_type == "guide" end)
      assert Enum.all?(chunks, fn c -> c.source_path == "docs/guide.md" end)

      headings = Enum.map(chunks, & &1.content)
      assert Enum.any?(headings, &(&1 =~ "Installation"))
      assert Enum.any?(headings, &(&1 =~ "Configuration"))
      assert Enum.any?(headings, &(&1 =~ "Troubleshooting"))
    end

    test "parses flat_document.md fixture as single chunk" do
      content = Backplane.Fixtures.read_fixture("markdown", "flat_document.md")
      {:ok, chunks} = Markdown.parse(content, "docs/flat.md")

      assert length(chunks) == 1
      assert hd(chunks).content =~ "flat document with no headings"
    end

    test "parses guide_with_frontmatter.md fixture" do
      content = Backplane.Fixtures.read_fixture("markdown", "guide_with_frontmatter.md")
      {:ok, chunks} = Markdown.parse(content, "docs/deploy.md")

      # Frontmatter is treated as content (markdown parser doesn't strip it)
      assert chunks != []
      assert Enum.any?(chunks, fn c -> c.content =~ "Deployment" end)
    end
  end
end

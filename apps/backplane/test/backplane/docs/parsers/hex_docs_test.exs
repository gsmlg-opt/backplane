defmodule Backplane.Docs.Parsers.HexDocsTest do
  use ExUnit.Case, async: true

  alias Backplane.Docs.Parsers.HexDocs

  describe "parse/2" do
    test "extracts chunks from a module documentation page" do
      html = """
      <html><body>
      <h1>Foo.Bar</h1>
      <div>Module documentation for Foo.Bar. This module handles requests.</div>
      <h2>Summary</h2>
      <div>Functions available in this module for processing data.</div>
      <h2>hello/1</h2>
      <div>Greets the user with a personalized message based on their name.</div>
      <h2>Types</h2>
      <div>Custom types defined in this module for type safety.</div>
      </body></html>
      """

      {:ok, chunks} = HexDocs.parse(html, "doc/Foo.Bar.html")

      assert length(chunks) >= 3

      moduledoc = Enum.find(chunks, &(&1.chunk_type == "moduledoc"))
      assert moduledoc != nil
      assert moduledoc.module == "Foo.Bar"

      func_doc = Enum.find(chunks, &(&1.chunk_type == "function_doc"))
      assert func_doc != nil
      assert func_doc.function == "hello/1"

      type_doc = Enum.find(chunks, &(&1.chunk_type == "typespec"))
      assert type_doc != nil
    end

    test "extracts chunks from a guide page" do
      html = """
      <html><body>
      <h1>Getting Started</h1>
      <div>This guide walks you through setting up the project and running it locally.</div>
      <h2>Installation</h2>
      <div>Run mix deps.get to install dependencies. Then run mix ecto.setup for the database.</div>
      <h2>Configuration</h2>
      <div>Edit config/runtime.exs to set your environment variables and secrets.</div>
      </body></html>
      """

      {:ok, chunks} = HexDocs.parse(html, "doc/getting-started.html")

      assert length(chunks) >= 2
      assert Enum.all?(chunks, &(&1.chunk_type == "guide"))
      assert Enum.all?(chunks, &(&1.module == nil))
    end

    test "skips api-reference pages" do
      html = "<html><body><h1>API Reference</h1><div>Index page</div></body></html>"

      {:ok, chunks} = HexDocs.parse(html, "doc/api-reference.html")
      assert chunks == []
    end

    test "handles empty content gracefully" do
      {:ok, chunks} = HexDocs.parse("", "doc/Empty.html")
      assert chunks == []
    end

    test "handles malformed HTML without crashing" do
      html = "<div>Some text without closing tags<h2>Heading<div>More text"
      {:ok, chunks} = HexDocs.parse(html, "doc/Malformed.html")
      assert is_list(chunks)
    end
  end

  describe "strip_html_tags/1" do
    test "removes all HTML tags" do
      assert HexDocs.strip_html_tags("<p>Hello <b>World</b></p>") == "Hello World"
    end

    test "removes script and style tags with content" do
      html = "<div>Text<script>alert('xss')</script><style>.x{color:red}</style>More</div>"
      result = HexDocs.strip_html_tags(html)
      refute result =~ "alert"
      refute result =~ "color"
      assert result =~ "Text"
      assert result =~ "More"
    end

    test "decodes HTML entities" do
      assert HexDocs.strip_html_tags("&amp; &lt; &gt; &quot;") == "& < > \""
    end
  end

  describe "split_html_sections/1" do
    test "splits on heading tags" do
      html = "<h1>Title</h1><p>Body one</p><h2>Section</h2><p>Body two</p>"
      sections = HexDocs.split_html_sections(html)

      assert length(sections) >= 2
    end

    test "handles content before first heading" do
      html = "<p>Preface</p><h1>Title</h1><p>Body</p>"
      sections = HexDocs.split_html_sections(html)

      assert sections != []
    end
  end

  describe "parse/2 rescue branch (L19-20)" do
    test "returns {:ok, []} when content causes an internal exception" do
      # We cannot easily force extract_chunks to raise via public inputs because
      # it is well-guarded, but we can verify the rescue contract by passing
      # content and a path whose combination triggers a code path that could
      # raise. The rescue clause at L19-20 returns {:ok, []} on any exception.
      # The safest way to exercise it directly is to note that parse/2 is a
      # thin wrapper: pass a non-binary (atom) as content, which causes
      # String.contains? to raise an ArgumentError inside extract_chunks.
      result = HexDocs.parse(:not_a_binary, "doc/Foo.Bar.html")
      assert result == {:ok, []}
    end
  end

  describe "parse_generic_html / generic path (L36-37, L100, L102)" do
    # The `true` branch in extract_chunks (L36-37) fires when the source_path
    # is neither an api-reference path, a module page (.html with uppercase
    # basename), nor a guide page (.html or .htm extension without module name).
    # A path with a non-.html extension (e.g., ".xml") passes all three guards
    # and falls into parse_generic_html, covering L36-37, L100, and L102.

    test "extracts a generic chunk from a non-html-extension path with sufficient content" do
      content = "<div>This is generic page content with enough text to exceed ten chars.</div>"

      {:ok, chunks} = HexDocs.parse(content, "doc/changelog.xml")

      assert length(chunks) == 1
      [chunk] = chunks
      assert chunk.chunk_type == "guide"
      assert chunk.module == nil
      assert chunk.function == nil
      assert chunk.source_path == "doc/changelog.xml"
      assert String.contains?(chunk.content, "generic page content")
    end

    test "returns empty list for generic path when stripped text is too short" do
      # L102: the else branch of `if String.length(text) > 10` — content that
      # strips down to 10 characters or fewer.
      content = "<div>Hi</div>"

      {:ok, chunks} = HexDocs.parse(content, "doc/tiny.xml")

      assert chunks == []
    end
  end
end

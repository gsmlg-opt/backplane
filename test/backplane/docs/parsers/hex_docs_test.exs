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
end

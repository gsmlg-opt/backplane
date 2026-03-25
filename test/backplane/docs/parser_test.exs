defmodule Backplane.Docs.ParserTest do
  use ExUnit.Case, async: true

  alias Backplane.Docs.Parser

  describe "parser_for/1" do
    test "selects Elixir parser for .ex files" do
      assert Parser.parser_for("lib/my_module.ex") == Backplane.Docs.Parsers.Elixir
    end

    test "selects Elixir parser for .exs files" do
      assert Parser.parser_for("test/my_test.exs") == Backplane.Docs.Parsers.Elixir
    end

    test "selects Markdown parser for .md files" do
      assert Parser.parser_for("docs/guide.md") == Backplane.Docs.Parsers.Markdown
    end

    test "selects Generic parser for unknown extensions" do
      assert Parser.parser_for("config.json") == Backplane.Docs.Parsers.Generic
      assert Parser.parser_for("readme.txt") == Backplane.Docs.Parsers.Generic
      assert Parser.parser_for("data.yml") == Backplane.Docs.Parsers.Generic
    end
  end
end

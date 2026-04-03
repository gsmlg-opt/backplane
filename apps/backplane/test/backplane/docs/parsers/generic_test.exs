defmodule Backplane.Docs.Parsers.GenericTest do
  use ExUnit.Case, async: true

  alias Backplane.Docs.Parsers.Generic

  describe "parse/2" do
    test "splits on blank lines" do
      content = "First paragraph.\n\nSecond paragraph.\n\nThird paragraph."
      {:ok, chunks} = Generic.parse(content, "file.txt")
      assert length(chunks) == 3
      assert Enum.at(chunks, 0).content == "First paragraph."
      assert Enum.at(chunks, 1).content == "Second paragraph."

      Enum.each(chunks, fn chunk ->
        assert chunk.chunk_type == "code"
        assert chunk.source_path == "file.txt"
      end)
    end

    test "handles empty content" do
      {:ok, chunks} = Generic.parse("", "empty.txt")
      assert chunks == []
    end
  end
end

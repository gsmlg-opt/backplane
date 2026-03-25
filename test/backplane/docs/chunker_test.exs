defmodule Backplane.Docs.ChunkerTest do
  use ExUnit.Case, async: true

  alias Backplane.Docs.Chunker

  describe "process/1" do
    test "adds content_hash and token count" do
      chunks = [
        %{
          source_path: "lib/foo.ex",
          module: "Foo",
          function: nil,
          chunk_type: "moduledoc",
          content: "This is a module with enough content to pass the minimum size threshold."
        }
      ]

      [result] = Chunker.process(chunks)
      assert is_binary(result.content_hash)
      assert String.length(result.content_hash) == 64
      assert is_integer(result.tokens)
      assert result.tokens > 0
    end

    test "filters out chunks below minimum size" do
      chunks = [
        %{
          source_path: "lib/foo.ex",
          module: nil,
          function: nil,
          chunk_type: "code",
          content: "tiny"
        },
        %{
          source_path: "lib/foo.ex",
          module: nil,
          function: nil,
          chunk_type: "code",
          content: "This content is long enough to pass the minimum chunk size threshold."
        }
      ]

      result = Chunker.process(chunks)
      assert length(result) == 1
      assert hd(result).content =~ "long enough"
    end

    test "preserves metadata fields" do
      chunks = [
        %{
          source_path: "lib/bar.ex",
          module: "Bar",
          function: "hello/1",
          chunk_type: "function_doc",
          content: "Greets the given person by name and returns a string."
        }
      ]

      [result] = Chunker.process(chunks)
      assert result.module == "Bar"
      assert result.function == "hello/1"
      assert result.chunk_type == "function_doc"
      assert result.source_path == "lib/bar.ex"
    end

    test "computes deterministic hashes" do
      content = "Same content yields same hash every time it is computed."

      chunks = [
        %{source_path: "a.ex", module: nil, function: nil, chunk_type: "code", content: content},
        %{source_path: "b.ex", module: nil, function: nil, chunk_type: "code", content: content}
      ]

      [a, b] = Chunker.process(chunks)
      assert a.content_hash == b.content_hash
    end
  end
end

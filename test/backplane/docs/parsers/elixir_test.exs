defmodule Backplane.Docs.Parsers.ElixirTest do
  use ExUnit.Case, async: true

  alias Backplane.Docs.Parsers.Elixir, as: ElixirParser

  describe "parse/2" do
    test "extracts moduledoc from heredoc" do
      code = ~S'''
      defmodule MyApp.Foo do
        @moduledoc """
        This is the module documentation.
        It spans multiple lines.
        """
      end
      '''

      {:ok, chunks} = ElixirParser.parse(code, "lib/my_app/foo.ex")
      assert [chunk] = chunks
      assert chunk.chunk_type == "moduledoc"
      assert chunk.module == "MyApp.Foo"
      assert chunk.content =~ "This is the module documentation"
    end

    test "extracts moduledoc from single-line string" do
      code = ~S'''
      defmodule MyApp.Bar do
        @moduledoc "A short module doc."
      end
      '''

      {:ok, chunks} = ElixirParser.parse(code, "lib/my_app/bar.ex")
      assert [chunk] = chunks
      assert chunk.chunk_type == "moduledoc"
      assert chunk.content == "A short module doc."
    end

    test "handles @moduledoc false" do
      code = ~S'''
      defmodule MyApp.Hidden do
        @moduledoc false
      end
      '''

      {:ok, chunks} = ElixirParser.parse(code, "lib/my_app/hidden.ex")
      assert chunks == []
    end

    test "extracts function doc with @doc" do
      code = ~S'''
      defmodule MyApp.Math do
        @doc """
        Adds two numbers.
        """
        def add(a, b), do: a + b
      end
      '''

      {:ok, chunks} = ElixirParser.parse(code, "lib/my_app/math.ex")
      assert [chunk] = chunks
      assert chunk.chunk_type == "function_doc"
      assert chunk.function == "add/2"
      assert chunk.content =~ "Adds two numbers"
    end

    test "includes @spec in function_doc" do
      code = ~S'''
      defmodule MyApp.Math do
        @doc "Adds two numbers."
        @spec add(integer(), integer()) :: integer()
        def add(a, b), do: a + b
      end
      '''

      {:ok, chunks} = ElixirParser.parse(code, "lib/my_app/math.ex")
      assert [chunk] = chunks
      assert chunk.content =~ "@spec add(integer(), integer()) :: integer()"
      assert chunk.content =~ "Adds two numbers"
    end

    test "extracts typedoc with @type" do
      code = ~S'''
      defmodule MyApp.Types do
        @typedoc "Represents a user ID"
        @type user_id :: pos_integer()
      end
      '''

      {:ok, chunks} = ElixirParser.parse(code, "lib/my_app/types.ex")
      assert [chunk] = chunks
      assert chunk.chunk_type == "typespec"
      assert chunk.content =~ "Represents a user ID"
      assert chunk.content =~ "@type user_id"
    end

    test "handles nested defmodule" do
      code = ~S'''
      defmodule MyApp.Outer do
        @moduledoc "Outer module"

        defmodule Inner do
          @moduledoc "Inner module"
        end
      end
      '''

      {:ok, chunks} = ElixirParser.parse(code, "lib/my_app/outer.ex")
      assert length(chunks) == 2

      outer = Enum.find(chunks, &(&1.module == "MyApp.Outer"))
      assert outer.content == "Outer module"

      inner = Enum.find(chunks, &String.ends_with?(&1.module || "", "Inner"))
      assert inner.content == "Inner module"
    end

    test "handles @doc false" do
      code = ~S'''
      defmodule MyApp.Internal do
        @doc false
        def secret, do: :hidden
      end
      '''

      {:ok, chunks} = ElixirParser.parse(code, "lib/my_app/internal.ex")
      assert chunks == []
    end

    test "handles syntax errors gracefully" do
      code = "defmodule Broken do\n  @doc \"broken\n  def"

      {:ok, chunks} = ElixirParser.parse(code, "lib/broken.ex")
      assert is_list(chunks)
    end

    test "handles empty file" do
      {:ok, chunks} = ElixirParser.parse("", "lib/empty.ex")
      assert chunks == []
    end

    test "extracts function arity correctly for zero args" do
      code = ~S'''
      defmodule MyApp.Health do
        @doc "Returns ok"
        def check, do: :ok
      end
      '''

      {:ok, chunks} = ElixirParser.parse(code, "lib/my_app/health.ex")
      assert [chunk] = chunks
      assert chunk.function == "check/0"
    end
  end
end

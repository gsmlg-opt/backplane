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

    test "extracts typedoc from heredoc" do
      code = ~S'''
      defmodule MyApp.Types do
        @typedoc """
        A complex type
        with multiline docs.
        """
        @type complex :: {atom(), integer()}
      end
      '''

      {:ok, chunks} = ElixirParser.parse(code, "lib/my_app/types.ex")
      assert [chunk] = chunks
      assert chunk.chunk_type == "typespec"
      assert chunk.content =~ "A complex type"
      assert chunk.content =~ "with multiline docs"
      assert chunk.content =~ "@type complex"
    end

    test "handles @typep with typedoc" do
      code = ~S'''
      defmodule MyApp.Types do
        @typedoc "Private state type"
        @typep state :: map()
      end
      '''

      {:ok, chunks} = ElixirParser.parse(code, "lib/my_app/types.ex")
      assert [chunk] = chunks
      assert chunk.chunk_type == "typespec"
      assert chunk.content =~ "Private state type"
      assert chunk.content =~ "@typep state"
    end

    test "handles @opaque with typedoc" do
      code = ~S'''
      defmodule MyApp.Types do
        @typedoc "Opaque handle"
        @opaque handle :: reference()
      end
      '''

      {:ok, chunks} = ElixirParser.parse(code, "lib/my_app/types.ex")
      assert [chunk] = chunks
      assert chunk.chunk_type == "typespec"
      assert chunk.content =~ "Opaque handle"
      assert chunk.content =~ "@opaque handle"
    end

    test "skips @type without typedoc" do
      code = ~S'''
      defmodule MyApp.Types do
        @type simple :: atom()
      end
      '''

      {:ok, chunks} = ElixirParser.parse(code, "lib/my_app/types.ex")
      assert chunks == []
    end

    test "skips function without @doc" do
      code = ~S'''
      defmodule MyApp.Internal do
        def helper(x), do: x + 1
      end
      '''

      {:ok, chunks} = ElixirParser.parse(code, "lib/my_app/internal.ex")
      assert chunks == []
    end

    test "clears @spec when function has no @doc" do
      code = ~S'''
      defmodule MyApp.Math do
        @spec secret(integer()) :: integer()
        def secret(x), do: x * 2

        @doc "Public function"
        def public(x), do: x + 1
      end
      '''

      {:ok, chunks} = ElixirParser.parse(code, "lib/my_app/math.ex")
      assert [chunk] = chunks
      assert chunk.function == "public/1"
      # spec from secret/1 should not leak into public/1
      refute chunk.content =~ "secret"
    end

    test "extracts defmacro doc" do
      code = ~S'''
      defmodule MyApp.Macros do
        @doc "A useful macro"
        defmacro my_macro(expr), do: expr
      end
      '''

      {:ok, chunks} = ElixirParser.parse(code, "lib/my_app/macros.ex")
      assert [chunk] = chunks
      assert chunk.function == "my_macro/1"
      assert chunk.content =~ "A useful macro"
    end

    test "extracts defmacrop doc" do
      code = ~S'''
      defmodule MyApp.Macros do
        @doc "Private macro"
        defmacrop helper(x), do: x
      end
      '''

      {:ok, chunks} = ElixirParser.parse(code, "lib/my_app/macros.ex")
      assert [chunk] = chunks
      assert chunk.function == "helper/1"
    end

    test "counts args with nested brackets correctly" do
      code = ~S'''
      defmodule MyApp.Complex do
        @doc "Complex args"
        def process(%{key: val}, [a, b], {c, d}), do: {val, a, b, c, d}
      end
      '''

      {:ok, chunks} = ElixirParser.parse(code, "lib/my_app/complex.ex")
      assert [chunk] = chunks
      assert chunk.function == "process/3"
    end

    test "handles multiple functions with interleaved docs" do
      code = ~S'''
      defmodule MyApp.Multi do
        @doc "First function"
        def first(a), do: a

        @doc "Second function"
        @spec second(integer(), integer()) :: integer()
        def second(a, b), do: a + b

        def undocumented(x), do: x
      end
      '''

      {:ok, chunks} = ElixirParser.parse(code, "lib/my_app/multi.ex")
      assert length(chunks) == 2

      first = Enum.find(chunks, &(&1.function == "first/1"))
      assert first.content == "First function"

      second = Enum.find(chunks, &(&1.function == "second/2"))
      assert second.content =~ "@spec second"
      assert second.content =~ "Second function"
    end

    test "handles heredoc that reaches EOF without closing triple-quote" do
      code = ~S'''
      defmodule MyApp.Broken do
        @doc """
        This doc never closes
      '''

      {:ok, chunks} = ElixirParser.parse(code, "lib/my_app/broken.ex")
      assert is_list(chunks)
    end

    test "module name is nil outside defmodule" do
      code = ~S'''
      @doc "Orphan doc"
      def orphan, do: :ok
      '''

      {:ok, chunks} = ElixirParser.parse(code, "lib/orphan.ex")
      assert [chunk] = chunks
      assert chunk.module == nil
    end

    test "handles defp with doc" do
      code = ~S'''
      defmodule MyApp.Private do
        @doc "Private but documented"
        defp internal(x), do: x
      end
      '''

      {:ok, chunks} = ElixirParser.parse(code, "lib/my_app/private.ex")
      assert [chunk] = chunks
      assert chunk.function == "internal/1"
    end

    test "handles function with question mark in name" do
      code = ~S'''
      defmodule MyApp.Check do
        @doc "Checks validity"
        def valid?(x), do: is_binary(x)
      end
      '''

      {:ok, chunks} = ElixirParser.parse(code, "lib/my_app/check.ex")
      assert [chunk] = chunks
      assert chunk.function == "valid?/1"
    end

    test "handles function with bang in name" do
      code = ~S'''
      defmodule MyApp.Fetch do
        @doc "Fetches or raises"
        def fetch!(id), do: id
      end
      '''

      {:ok, chunks} = ElixirParser.parse(code, "lib/my_app/fetch.ex")
      assert [chunk] = chunks
      assert chunk.function == "fetch!/1"
    end

    test "rescue returns {:ok, []} for non-binary content" do
      # Passing nil causes String.split to raise, exercising the rescue branch
      {:ok, chunks} = ElixirParser.parse(nil, "lib/broken.ex")
      assert chunks == []
    end

    test "extracts zero-arity function" do
      code = ~S'''
      defmodule MyApp.Config do
        @doc "Returns configuration."
        def config() do
          %{}
        end
      end
      '''

      {:ok, chunks} = ElixirParser.parse(code, "lib/my_app/config.ex")
      func_chunks = Enum.filter(chunks, &(&1.chunk_type == "function_doc"))
      assert Enum.any?(func_chunks, fn c -> c.function == "config/0" end)
    end

    test "handles function with nested parens/brackets in args" do
      code = ~S'''
      defmodule MyApp.Complex do
        @doc "Complex args."
        def process(%{key: val}, [head | tail], {a, b}) do
          :ok
        end
      end
      '''

      {:ok, chunks} = ElixirParser.parse(code, "lib/my_app/complex.ex")
      func_chunks = Enum.filter(chunks, &(&1.chunk_type == "function_doc"))
      assert Enum.any?(func_chunks, fn c -> c.function == "process/3" end)
    end

    test "handles function with no-paren definition" do
      code = ~S'''
      defmodule MyApp.NoParen do
        @doc "A constant."
        def value, do: 42
      end
      '''

      {:ok, chunks} = ElixirParser.parse(code, "lib/my_app/no_paren.ex")
      func_chunks = Enum.filter(chunks, &(&1.chunk_type == "function_doc"))
      # count_args(_) returns 0 for non-parenthesized defs
      assert Enum.any?(func_chunks, fn c -> c.function =~ "value" end)
    end

    test "counts args with nested brackets and parens" do
      # This exercises the bracket depth tracking: (, [, {, ), ], }
      code = ~S'''
      defmodule MyApp.Brackets do
        @doc "Takes a tuple, list, and map."
        def process({a, b}, [c | _rest], %{key: val}) do
          {a, b, c, val}
        end
      end
      '''

      {:ok, chunks} = ElixirParser.parse(code, "lib/my_app/brackets.ex")
      func_chunks = Enum.filter(chunks, &(&1.chunk_type == "function_doc"))
      assert Enum.any?(func_chunks, fn c -> c.function == "process/3" end)
    end

    test "counts args with nested parentheses inside function args" do
      # Exercises the "(" and ")" depth tracking branches in count_args_balanced
      code = ~S'''
      defmodule MyApp.Nested do
        @doc "Default arg with nested parens."
        def transform(opts \\ Keyword.new([])) do
          opts
        end
      end
      '''

      {:ok, chunks} = ElixirParser.parse(code, "lib/my_app/nested.ex")
      func_chunks = Enum.filter(chunks, &(&1.chunk_type == "function_doc"))
      assert Enum.any?(func_chunks, fn c -> c.function == "transform/1" end)
    end
  end
end

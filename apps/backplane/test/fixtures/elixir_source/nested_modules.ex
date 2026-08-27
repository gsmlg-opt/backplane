defmodule Example.Outer do
  @moduledoc "The outer module."

  @doc "Outer function."
  def outer_func, do: :outer

  defmodule Inner do
    @moduledoc "A nested inner module."

    @doc "Inner function with an argument."
    @spec inner_func(String.t()) :: atom()
    def inner_func(_arg), do: :inner

    defmodule DeepNested do
      @moduledoc "A deeply nested module."

      @doc "Deep function."
      def deep_func, do: :deep
    end
  end

  defmodule Sibling do
    @moduledoc "A sibling nested module."

    @doc "Sibling function."
    def sibling_func, do: :sibling
  end
end

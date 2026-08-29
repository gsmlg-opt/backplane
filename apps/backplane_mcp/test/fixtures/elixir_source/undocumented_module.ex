defmodule Example.Undocumented do
  @moduledoc false

  def run(input) do
    process(input)
  end

  defp process(input), do: {:ok, input}
end

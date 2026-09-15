defmodule EmptyTool do
  @moduledoc """
  Clean-consumer fixture proving an inert runtime with no configured tools.
  """

  alias Backplane.AgentRuntime.Error
  alias Backplane.AgentRuntime.Tools

  def verify! do
    nil = Process.whereis(Backplane.AgentRuntime.Tools.LocalResource)
    nil = Process.whereis(Backplane.AgentRuntime.Tools.LocalCommand)
    {:ok, tools} = Tools.new(%{})
    [] = Tools.available_tools(tools)

    {:error, %Error{class: :unsupported_capability}} =
      Tools.memory_search(tools, %{memory_scope: "task"}, %{scope: "task"})

    :ok
  end
end

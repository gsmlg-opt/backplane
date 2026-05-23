defmodule Mix.Tasks.Agent.RunTest do
  use ExUnit.Case, async: true

  test "mix agent.run task is available" do
    assert Code.ensure_loaded?(Mix.Tasks.Agent.Run)
    assert function_exported?(Mix.Tasks.Agent.Run, :run, 1)
  end
end

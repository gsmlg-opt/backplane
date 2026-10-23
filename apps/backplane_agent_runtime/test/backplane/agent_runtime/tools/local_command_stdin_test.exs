defmodule Backplane.AgentRuntime.Tools.LocalCommandStdinTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.Error
  alias Backplane.AgentRuntime.Tools.LocalCommand

  test "a closed stdin port reports an error without crashing its owner" do
    executable = System.find_executable("cat")
    port = Port.open({:spawn_executable, executable}, [:binary])
    assert Port.close(port)
    state = %{active: %{port => %{}}}

    assert {:reply, {:error, %Error{class: :execution_failure}}, ^state} =
             LocalCommand.handle_call(
               {:write, %{port: port}, "input"},
               {self(), make_ref()},
               state
             )
  end
end

defmodule Backplane.AgentRuntime.CodexSessionIncarnationTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{Command, Error}
  alias Backplane.AgentRuntime.Codex.{Backend, ResourceRegistry}

  defmodule RecordingCommand do
    def write(command, _invocation, _job, chars) do
      send(command.server, {:command_stdin_written, chars})
      :ok
    end

    def read(_command, _invocation, _job, opts) do
      {:ok,
       %{output: [], cursor: Keyword.fetch!(opts, :cursor), status: :running, exit_status: nil}}
    end

    def cancel(_command, _invocation), do: :ok
    def start(_command, _request, _opts), do: {:error, Error.new(:unsupported_capability)}
  end

  test "trusted invocation incarnation fences an older numeric command session" do
    {:ok, registry} = ResourceRegistry.start_link([])

    {:ok, command} =
      Command.new(%{adapter: RecordingCommand, allowed_environment: %{}, server: self()})

    assert {:ok, session_id} =
             ResourceRegistry.register_session(
               registry,
               "same-run",
               %{
                 job: %{owner_run_id: "same-run"},
                 cursor: 0
               },
               incarnation: 1
             )

    operation = %{
      tool_name: "write_stdin",
      arguments: %{"session_id" => session_id, "chars" => "forbidden"},
      run_id: "same-run",
      incarnation: 2,
      backend_context: %{
        family: :local,
        context: %{command: command, caller: %{run_id: "same-run"}, session_registry: registry},
        resource_owner_pid: self()
      }
    }

    assert {:error, %Error{class: :resource_conflict}} = Backend.execute(operation)
    refute_receive {:command_stdin_written, _}

    assert {:ok, %{cursor: 0}} = ResourceRegistry.fetch_session(registry, session_id, "same-run")
  end
end

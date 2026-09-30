defmodule Backplane.AgentRuntime.CodexFollowupRepairsTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{Command, Error}
  alias Backplane.AgentRuntime.Codex.{CodeMode, ResourceRegistry}

  defmodule OwnerOnlyCommand do
    def start(_command, _request, _opts), do: {:error, Error.new(:resource_conflict, "busy")}
    def read(_command, _invocation, _job, _opts), do: {:error, Error.new(:not_found)}
    def write(_command, _invocation, _job, _chars), do: :ok

    def cancel(command, _invocation),
      do:
        Agent.update(command.server, fn %{cancelled: count} = state ->
          %{state | cancelled: count + 1}
        end)
  end

  test "Code Mode workers are temporary and never supervisor-replayed" do
    spec = CodeMode.Worker.child_spec(code: "return 1;")
    assert spec.restart == :temporary
  end

  test "unsupported process lifecycle capability is rejected before spawning" do
    registry = start_supervised!(ResourceRegistry)
    {:ok, worker_supervisor} = ResourceRegistry.worker_supervisor(registry)

    assert {:error, %Error{class: :unsupported_capability}} =
             CodeMode.execute(registry, "run", "return 1;",
               deno_path: "/does/not/exist",
               host_context: %{process_lifecycle_capability: :unsupported},
               dispatcher: fn _, _ -> {:ok, %{}} end
             )

    assert DynamicSupervisor.which_children(worker_supervisor) == []
  end

  test "a backend without per-invocation confirmation cannot cancel its owner" do
    {:ok, server} = Agent.start_link(fn -> %{cancelled: 0} end)

    assert {:ok, command} =
             Command.new(%{
               adapter: OwnerOnlyCommand,
               server: server,
               allowed_environment: %{}
             })

    assert {:error, %Error{class: :unknown_outcome}} =
             Command.cancel_confirmed(command, %{owner_run_id: "run", session_id: 1}, 100)

    assert Agent.get(server, & &1.cancelled) == 0
  end
end

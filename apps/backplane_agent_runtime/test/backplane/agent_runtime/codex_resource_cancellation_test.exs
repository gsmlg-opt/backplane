defmodule Backplane.AgentRuntime.CodexResourceCancellationTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{Codex.DynamicRuntime, Conversation, Error, ToolEffects}

  defmodule Adapter do
    def read_resource(arguments, operation) do
      send(operation.backend_context.test, {:resource_owner, self(), arguments})

      receive do
        :finish -> {:ok, %{contents: []}}
      end
    end

    def list_resources(arguments, operation), do: read_resource(arguments, operation)
    def list_resource_templates(arguments, operation), do: read_resource(arguments, operation)
  end

  test "resource callbacks execute in their actual effect caller while the runtime stays responsive" do
    runtime = start_supervised!({DynamicRuntime, mcp_adapter: Adapter})

    test = self()

    for tool <- ["read_mcp_resource", "list_mcp_resources", "list_mcp_resource_templates"] do
      caller = Task.async(fn -> DynamicRuntime.call(operation(runtime, tool, test)) end)
      assert_receive {:resource_owner, owner, _}, 500
      assert owner == caller.pid
      assert length(DynamicRuntime.contracts(%{dynamic_runtime: runtime})) == 3
      send(caller.pid, :finish)
      assert {:ok, %{contents: []}} = Task.await(caller)
    end
  end

  test "verified cancellation is bound to the original exact operation and JSON evidence" do
    operation =
      identity()
      |> Map.put(:resource_registration, "resource-1")
      |> Map.put(:stop_generation, "stop-1")

    evidence = %{
      registration_id: "resource-1",
      stop_generation: "stop-1",
      local_cleanup: :confirmed,
      local: :cancelled,
      remote: :unknown,
      logical_id: "logical-1",
      request_id: "wire-1",
      client_incarnation: "client-1",
      method: "resources/read",
      cleanup_evidence: %{workers_down: true, worker_count: 0, transport: :confirmed}
    }

    assert {:ok, assertion} = ToolEffects.confirm_cancellation(operation, evidence)
    assert {:ok, normalized} = ToolEffects.validate_cancellation(assertion, operation)
    assert normalized["local_cleanup"] == "confirmed"

    assert {:error, %Error{class: :unknown_outcome}} =
             ToolEffects.validate_cancellation(assertion, %{operation | incarnation: 1.0})

    for bad <- [
          %{evidence | local_cleanup: :uncertain},
          %{evidence | stop_generation: "old"},
          %{evidence | registration_id: "old"},
          %{
            evidence
            | cleanup_evidence: %{workers_down: false, worker_count: 1, transport: :confirmed}
          }
        ] do
      assert {:error, %Error{class: :unknown_outcome}} =
               ToolEffects.confirm_cancellation(operation, bad)
    end
  end

  test "cancellation registration requires every admitted identity field" do
    token = make_ref()
    invocation = identity() |> Map.put(:collaboration_binding, %{fingerprint: "binding"})
    binding = %{run_id: "run", owner_id: "session", incarnation: 2, run_incarnation: 1}
    operation = Map.put(invocation, :session_binding_identity, binding)

    state = %{
      run: %{run_id: "run", incarnation: 1},
      opts: [session_binding: binding],
      effect: %{
        token: token,
        task: %{ref: make_ref(), pid: self()},
        role: {:tool, invocation, [], nil}
      },
      stopping: nil,
      cancellations: %{}
    }

    for field <- [
          :turn_id,
          :catalog_revision,
          :tool_call_id,
          :enclosing_invocation_id,
          :collaboration_binding
        ] do
      assert {:reply, {:error, %Error{class: :resource_conflict}}, ^state} =
               Conversation.handle_call(
                 {:register_cancellation, token, Map.delete(operation, field), "probe"},
                 {self(), make_ref()},
                 state
               )
    end

    assert {:reply, {:error, %Error{class: :resource_conflict}}, ^state} =
             Conversation.handle_call(
               {:register_cancellation, token, %{operation | arguments: %{}}, "probe"},
               {self(), make_ref()},
               state
             )

    assert {:reply, _, registered} =
             Conversation.handle_call(
               {:register_cancellation, token, operation, "valid"},
               {self(), make_ref()},
               state
             )

    assert registered.cancellations[invocation.invocation_id].operation === operation
  end

  defp operation(runtime, tool, test) do
    %{
      tool_name: tool,
      arguments: %{"uri" => "mem://pending"},
      backend_context: %{runtime: runtime, test: test}
    }
  end

  defp identity do
    %{
      run_id: "run",
      incarnation: 1,
      step_id: "step",
      attempt_id: "attempt",
      invocation_id: "invocation",
      tool_name: "read_mcp_resource",
      tool_revision: 1,
      catalog_revision: 1,
      tool_call_id: "call",
      turn_id: "turn",
      enclosing_invocation_id: "invocation",
      arguments: %{"uri" => "mem://pending"}
    }
  end
end

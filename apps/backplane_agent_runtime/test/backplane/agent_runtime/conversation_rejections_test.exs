defmodule Backplane.AgentRuntime.ConversationRejectionsTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{
    Approval,
    Conversation,
    EphemeralStore,
    Error,
    ToolEffects,
    ToolRegistry
  }

  defmodule Provider do
    def stream(request, context) do
      send(context.test, {:provider, request, self()})

      Stream.resource(
        fn -> nil end,
        fn state ->
          receive do: ({:events, events} -> {events, state})
        end,
        fn _ -> :ok end
      )
    end
  end

  defmodule HostBackend do
    def execute(operation) do
      context = operation.backend_context
      send(context.test, {:host_admitted, operation, self()})

      case context.mode do
        :nested ->
          context.nested_dispatch.(%{tool_name: "write", arguments: %{}})

        :gated ->
          receive do: (:release -> reject(operation, Error.new(:forbidden, "denied")))

        :unproven ->
          {:error, Error.new(:forbidden, "denied", details: %{dispatched: false})}

        :replay ->
          reject(%{operation | invocation_id: "another"}, Error.new(:forbidden, "denied"))

        mode when mode in [:replaced, :disabled] ->
          receive do
            {:registration, revision} when revision != operation.tool_revision ->
              reject(
                operation,
                Error.new(:resource_conflict, "registration changed before dispatch")
              )

            {:registration, _revision} ->
              send(context.test, :tool_executed)
              {:ok, %{text: "executed"}}
          end

        :unattended ->
          reject(operation, Error.new(:forbidden, "unattended approval is unavailable"))

        mode ->
          approval = %{
            approval_id: "approval",
            run_id: operation.run_id,
            tool_name: operation.tool_name,
            tool_revision: operation.tool_revision,
            arguments_digest: "digest",
            current_time: 10,
            expires_at: 20
          }

          decision = %{
            approval_id: "approval",
            resolver_id: "host",
            decision: :approved,
            tool_name: operation.tool_name,
            tool_revision: operation.tool_revision,
            arguments_digest: "digest"
          }

          {approval, decision} =
            case mode do
              :forged -> {approval, %{decision | approval_id: "forged"}}
              :expired -> {%{approval | current_time: 21}, decision}
              :denied -> {approval, %{decision | decision: :denied}}
              :mismatched -> {approval, %{decision | arguments_digest: "different"}}
              :boolean -> {approval, true}
            end

          case Approval.decide(approval, decision) do
            {:ok, :approved} ->
              send(context.test, :tool_executed)
              {:ok, %{text: "executed"}}

            {:ok, :denied} ->
              reject(operation, Error.new(:forbidden, "denied"))

            {:error, error} ->
              reject(operation, error)
          end
      end
    end

    defp reject(operation, error), do: ToolEffects.reject(operation, error)
  end

  for mode <- [
        :forged,
        :expired,
        :denied,
        :mismatched,
        :boolean,
        :unattended,
        :replaced,
        :disabled
      ] do
    test "trusted #{mode} rejection continues without invoking the tool" do
      pid = start(unquote(mode))
      begin_tool(pid, "write")
      assert_receive {:host_admitted, operation, worker}, 1_000

      case unquote(mode) do
        :replaced -> send(worker, {:registration, 2})
        :disabled -> send(worker, {:registration, :disabled})
        _ -> :ok
      end

      assert_receive {:provider, request, provider}, 1_000
      message = List.last(request.messages)
      assert message.role == :tool
      assert message.tool_call_id == operation.tool_call_id
      assert message.result.is_error
      assert %Error{} = message.result.error
      send(provider, {:events, [done()]})
      assert_receive {:agent_runtime, _, %{type: :run_completed}}, 1_000
      assert Conversation.status(pid).run.active_tools == %{}
      refute_receive :tool_executed, 20
    end
  end

  test "nested rejection settles its own invocation and resumes the provider" do
    pid = start(:denied)
    begin_tool(pid, "outer")
    assert_receive {:host_admitted, %{tool_name: "outer"}, _}, 1_000
    assert_receive {:host_admitted, %{tool_name: "write"}, _}, 1_000
    assert_receive {:provider, request, provider}, 1_000
    assert List.last(request.messages).result.is_error
    send(provider, {:events, [done()]})
    assert_receive {:agent_runtime, _, %{type: :run_completed}}, 1_000
    assert Conversation.status(pid).run.active_tools == %{}
    refute_receive :tool_executed, 20
  end

  for mode <- [:unproven, :replay] do
    test "#{mode} rejection fails closed for a mutating invocation" do
      pid = start(unquote(mode))
      begin_tool(pid, "write")
      assert_receive {:host_admitted, _, _}, 1_000
      assert_receive {:agent_runtime, _, %{type: :run_cancelled, state: :unknown_outcome}}, 1_000
      assert map_size(Conversation.status(pid).run.active_tools) == 1
      refute_receive {:provider, _, _}, 20
      refute_receive :tool_executed, 20
    end
  end

  test "cancellation fences a late trusted rejection" do
    pid = start(:gated)
    begin_tool(pid, "write")
    assert_receive {:host_admitted, _, worker}, 1_000
    state = :sys.get_state(pid)
    token = state.effect.task.ref

    operation = elem(state.effect.role, 1)
    {:rejected, rejection} = ToolEffects.reject(operation, Error.new(:forbidden, "denied"))
    result = ToolEffects.validate_rejection(rejection, operation)

    assert :ok = Conversation.cancel(pid)
    send(worker, :release)
    send(pid, {token, result})
    assert_receive {:agent_runtime, _, %{type: :run_cancelled, state: :unknown_outcome}}, 1_000
    assert map_size(Conversation.status(pid).run.active_tools) == 1
    refute_receive {:provider, _, _}, 20
    refute_receive {:agent_runtime, _, %{type: :run_completed}}, 20
    refute_receive :tool_executed, 20
  end

  defp start(mode) do
    {:ok, table} = EphemeralStore.new(1)
    run_id = "rejection-#{System.unique_integer([:positive])}"

    registry =
      Enum.reduce([{"write", mode}, {"outer", :nested}], %ToolRegistry{}, fn {name, mode},
                                                                             registry ->
        {:ok, registry} =
          ToolRegistry.register(registry, %{
            tool_name: name,
            tool_revision: 1,
            schema: %{"type" => "object", "properties" => %{}},
            safety: %{read_only: false, retry_safe: false, parallel_safe: false},
            backend: HostBackend,
            backend_context: %{test: self(), mode: mode}
          })

        registry
      end)

    start_supervised!(
      {Conversation,
       [
         run_id: run_id,
         incarnation: 1,
         store: EphemeralStore,
         context: table,
         provider: Provider,
         provider_context: %{test: self()},
         subscriber: self(),
         registry: registry,
         authority: %{
           caller: "host",
           run_id: run_id,
           grants: ["write", "outer"],
           tool_revision: 1
         },
         work: 20,
         run_timeout: 5_000
       ]}
    )
  end

  defp begin_tool(pid, name) do
    assert {:ok, _} = Conversation.prompt(pid, "start")
    assert_receive {:provider, _, provider}, 1_000

    send(
      provider,
      {:events,
       [
         %{type: :tool_call_completed, tool_call: %{id: "call", name: name, arguments: %{}}},
         done()
       ]}
    )
  end

  defp done, do: %{type: :response_completed, message: %{role: :assistant, content: "done"}}
end

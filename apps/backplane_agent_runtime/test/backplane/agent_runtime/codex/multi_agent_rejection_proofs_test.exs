defmodule Backplane.AgentRuntime.Codex.MultiAgentRejectionProofsTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{EphemeralStore, Error, ToolEffects, ToolRegistry}
  alias Backplane.AgentRuntime.Codex.MultiAgent

  defmodule Provider do
    def stream(request, context) do
      send(context.test, {:provider, request.run_id, self()})

      Stream.resource(
        fn -> nil end,
        fn state ->
          receive do
            {:events, events} -> {events, state}
          end
        end,
        fn _ -> :ok end
      )
    end
  end

  test "capacity refusal proves non-dispatch of only the exact identified invocation" do
    runtime = start_runtime(max_threads: 1)
    operation = operation(runtime, :v2, "spawn_agent", spawn_arguments("worker"))
    assert {:ok, before_rejection} = MultiAgent.snapshot(runtime)

    assert_rejection(operation, :resource_conflict)

    assert {:ok, ^before_rejection} = MultiAgent.snapshot(runtime)
    refute_receive {:child_preparation, _, _}, 20
    refute_receive {:admission_receipt, _}, 20
    refute_receive {:provider, _, _}, 20
  end

  test "duplicate task refusal does not reserve or prepare another child" do
    runtime = start_runtime()
    operation = operation(runtime, :v2, "spawn_agent", spawn_arguments("worker"))
    assert {:ok, %{task_name: "/root/worker"}} = MultiAgent.call(operation)
    assert_receive {:child_preparation, _, run_id}, 1_000
    assert_receive {:admission_receipt, %{status: :created, run_id: ^run_id}}, 1_000
    assert_receive {:provider, ^run_id, provider}, 1_000
    assert {:ok, before_rejection} = MultiAgent.snapshot(runtime)

    assert_rejection(%{operation | invocation_id: "duplicate-invocation"}, :validation)

    assert {:ok, ^before_rejection} = MultiAgent.snapshot(runtime)
    assert Process.alive?(provider)
    refute_receive {:child_preparation, _, _}, 20
    refute_receive {:admission_receipt, _}, 20
    refute_receive {:provider, _, _}, 20
  end

  test "terminal V2 follow-up at capacity proves refusal before replacement preparation" do
    runtime = start_runtime(max_threads: 2)
    completed = operation(runtime, :v2, "spawn_agent", spawn_arguments("completed"))
    assert {:ok, %{task_name: "/root/completed"}} = MultiAgent.call(completed)
    assert_receive {:child_preparation, _, completed_run}, 1_000
    assert_receive {:admission_receipt, %{status: :created, run_id: ^completed_run}}, 1_000
    assert_receive {:provider, ^completed_run, completed_provider}, 1_000

    send(completed_provider, {
      :events,
      [%{type: :response_completed, message: %{role: :assistant, content: "done"}}]
    })

    assert eventually(fn ->
             {:ok, snapshot} = MultiAgent.snapshot(runtime)

             Enum.any?(
               snapshot.agents,
               &(&1.name == "/root/completed" and &1.status == :completed)
             )
           end)

    running = operation(runtime, :v2, "spawn_agent", spawn_arguments("running"))
    assert {:ok, %{task_name: "/root/running"}} = MultiAgent.call(running)
    assert_receive {:child_preparation, _, running_run}, 1_000
    assert_receive {:admission_receipt, %{status: :created, run_id: ^running_run}}, 1_000
    assert_receive {:provider, ^running_run, running_provider}, 1_000
    assert {:ok, before_rejection} = MultiAgent.snapshot(runtime)

    followup =
      operation(runtime, :v2, "followup_task", %{
        "target" => "/root/completed",
        "message" => "do more work"
      })

    assert_rejection(followup, :resource_conflict)

    assert {:ok, ^before_rejection} = MultiAgent.snapshot(runtime)
    assert Process.alive?(running_provider)
    refute_receive {:child_preparation, _, _}, 20
    refute_receive {:admission_receipt, _}, 20
    refute_receive {:provider, _, _}, 20
  end

  for {profile, tool, arguments} <- [
        {:v2, "send_message", %{"target" => "missing", "message" => "hello"}},
        {:v2, "followup_task", %{"target" => "missing", "message" => "continue"}},
        {:v2, "interrupt_agent", %{"target" => "missing"}},
        {:v1, "multi_agent_v1::send_input", %{"target" => "missing", "message" => "continue"}},
        {:v1, "multi_agent_v1::close_agent", %{"target" => "missing"}},
        {:v1, "multi_agent_v1::resume_agent", %{"id" => "missing"}}
      ] do
    test "#{tool} missing-target refusal has exact non-dispatch proof" do
      runtime = start_runtime()

      operation =
        operation(
          runtime,
          unquote(profile),
          unquote(tool),
          unquote(Macro.escape(arguments))
        )

      assert {:ok, before_rejection} = MultiAgent.snapshot(runtime)
      assert_rejection(operation, :not_found)
      assert {:ok, ^before_rejection} = MultiAgent.snapshot(runtime)
      refute_receive {:child_preparation, _, _}, 20
      refute_receive {:admission_receipt, _}, 20
      refute_receive {:provider, _, _}, 20
    end
  end

  test "legacy operations without full identity retain generic errors" do
    runtime = start_runtime(max_threads: 1)

    for {tool, arguments, error_class} <- [
          {"spawn_agent", spawn_arguments("worker"), :resource_conflict},
          {"send_message", %{"target" => "missing", "message" => "hello"}, :not_found}
        ] do
      operation = %{
        backend_context: %{runtime: runtime, profile: :v2},
        run_id: "root",
        tool_name: tool,
        arguments: arguments
      }

      assert {:error, %Error{class: ^error_class}} = result = MultiAgent.call(operation)
      assert ToolEffects.settlement(result, %{read_only: false}) == :uncertain
    end

    refute_receive {:child_preparation, _, _}, 20
    refute_receive {:admission_receipt, _}, 20
  end

  for error_class <- [:execution_failure, :resource_conflict] do
    test "#{error_class} preparation failure after reservation remains uncertain" do
      runtime = start_runtime(preparation_error_class: unquote(error_class))
      operation = operation(runtime, :v2, "spawn_agent", spawn_arguments("worker"))

      assert {:error, %Error{class: unquote(error_class)}} = result = MultiAgent.call(operation)
      assert ToolEffects.settlement(result, %{read_only: false}) == :uncertain
      assert_receive {:child_preparation, _, run_id}, 1_000
      assert_receive {:admission_receipt, %{status: :rejected, run_id: ^run_id}}, 1_000
      assert {:ok, snapshot} = MultiAgent.snapshot(runtime)
      assert snapshot.agents == []
      assert [%{status: :rejected, run_id: ^run_id}] = snapshot.admissions
      refute_receive {:provider, _, _}, 20
    end
  end

  defp eventually(check, remaining \\ 100)
  defp eventually(_check, 0), do: false

  defp eventually(check, remaining) do
    if check.() do
      true
    else
      Process.sleep(5)
      eventually(check, remaining - 1)
    end
  end

  defp assert_rejection(operation, error_class) do
    assert {:rejected, %ToolEffects.Rejection{} = proof} = MultiAgent.call(operation)

    assert {:ok, %{is_error: true, error: %Error{class: ^error_class}}} =
             result =
             ToolEffects.validate_rejection(proof, operation)

    assert ToolEffects.settlement(result, %{read_only: false}) == :settled

    for {field, replacement} <- [
          run_id: "other-run",
          incarnation: 2,
          step_id: "other-step",
          attempt_id: "other-attempt",
          invocation_id: "other-invocation",
          tool_name: "other-tool",
          tool_revision: 2,
          catalog_revision: 2,
          tool_call_id: "other-call",
          turn_id: "other-turn",
          arguments: Map.put(operation.arguments, "different", true)
        ] do
      assert {:error, %Error{class: :unknown_outcome}} =
               ToolEffects.validate_rejection(proof, Map.put(operation, field, replacement))
    end
  end

  defp operation(runtime, profile, tool, arguments) do
    %{
      backend_context: %{runtime: runtime, profile: profile},
      run_id: "root",
      incarnation: 1,
      step_id: "step",
      attempt_id: "attempt",
      invocation_id: "invocation",
      tool_name: tool,
      tool_revision: 1,
      catalog_revision: 1,
      tool_call_id: "call",
      turn_id: "turn",
      arguments: arguments
    }
  end

  defp spawn_arguments(name), do: %{"task_name" => name, "message" => "hold open"}

  defp start_runtime(options \\ []) do
    test = self()

    start_supervised!(
      {MultiAgent,
       parent_run_id: "root",
       parent_name: "/root",
       parent_authority: %{caller: "host", run_id: "root", grants: []},
       max_concurrent_threads_per_session: Keyword.get(options, :max_threads, 4),
       child_options: fn request, run_id, _parent ->
         send(test, {:child_preparation, request, run_id})

         if error_class = Keyword.get(options, :preparation_error_class) do
           {:error, Error.new(error_class, "preparation failed after reservation")}
         else
           {:ok, store} = EphemeralStore.new(1)

           {:ok,
            [
              run_id: run_id,
              store: EphemeralStore,
              context: store,
              provider: Provider,
              provider_context: %{test: test},
              registry: %ToolRegistry{},
              tools: [],
              authority: %{caller: "host", run_id: run_id, grants: []},
              schema_admission: :strict,
              work: 10,
              run_timeout: :infinity
            ]}
         end
       end,
       admission_receipt: fn receipt ->
         send(test, {:admission_receipt, receipt})
         :ok
       end}
    )
  end
end

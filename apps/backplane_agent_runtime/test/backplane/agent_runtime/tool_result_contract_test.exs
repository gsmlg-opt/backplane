defmodule Backplane.AgentRuntime.ToolResultContractTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{Budget, EphemeralStore, Error, Execution, ToolRegistry}
  alias Backplane.AgentRuntime.ToolResultContract

  defmodule ImageBackend do
    def execute(operation) do
      send(operation.backend_context.test, {:executed, operation})
      {:ok, operation.backend_context.result}
    end
  end

  test "selection uses admitted binding identity, persists before effect and cannot be reselected" do
    result = image_result()
    {record, invocation, _descriptor, opts} = fixture(result)
    test = self()
    limits = %{output_limit: 2_000_000, json_limit: 2_000_000}

    selector = fn selected, identity ->
      assert selected.backend == ImageBackend
      assert selected.tool_revision == 7
      assert identity.tool_name == "image"
      assert identity.invocation_id == invocation.invocation_id
      refute Map.has_key?(identity, :arguments)
      refute Map.has_key?(identity, :result_contract)
      send(test, :selected)
      {:ok, limits}
    end

    {:ok, store} = EphemeralStore.new(1)
    invocation = Map.put(invocation, :result_contract, %{output_limit: :infinity})

    assert {:ok, committed, prepared} =
             Execution.commit(
               EphemeralStore,
               store,
               record,
               %{command: {:tool_invoked, 10, invocation}},
               Keyword.put(opts, :tool_result_contract, selector)
             )

    assert_receive :selected
    refute_received {:executed, _}
    contract = Map.put(limits, :schema_version, 1)
    assert prepared.operation.result_contract == contract
    assert [%{operation: %{result_contract: ^contract}}] = committed.outbox
    assert {:ok, %{run: saved}} = EphemeralStore.load(store, record.run_id)
    assert saved.execution_intents["tool:call"].operation.result_contract == contract

    assert {:ok, [^result]} =
             Execution.dispatch(prepared,
               output_limit: 1,
               tool_result_contract: fn _, _ -> flunk("must never reselect") end
             )

    assert_receive {:executed, %{result_contract: ^contract}}
    refute_received :selected
  end

  test "unselected tools retain their original default even if arguments request more" do
    {record, invocation, _descriptor, opts} = fixture(image_result())
    {:ok, store} = EphemeralStore.new(1)

    assert {:error, %Error{class: :resource_conflict, details: %{limit: 1_048_576}}} =
             Execution.run(
               EphemeralStore,
               store,
               record,
               %{command: {:tool_invoked, 10, invocation}},
               Keyword.put(opts, :tool_result_contract, fn _, _ -> :default end)
             )

    assert_receive {:executed, operation}
    refute Map.has_key?(operation, :result_contract)
  end

  test "malformed or failing selectors refuse before durable admission or effect" do
    {record, invocation, _descriptor, opts} = fixture(image_result())

    selectors = [
      :invalid,
      fn _, _ -> {:ok, %{output_limit: :infinity, json_limit: 2_000_000}} end,
      fn _, _ -> {:ok, %{output_limit: 2_000_000, json_limit: 0}} end,
      fn _, _ -> {:ok, %{output_limit: 2_000_000, json_limit: 2_000_000, extra: true}} end,
      fn _, _ -> raise "private callback failure" end,
      fn _, _ -> exit(:callback_failed) end
    ]

    for selector <- selectors do
      {:ok, store} = EphemeralStore.new(1)

      assert {:error, %Error{class: :validation}} =
               Execution.commit(
                 EphemeralStore,
                 store,
                 record,
                 %{command: {:tool_invoked, 10, invocation}},
                 Keyword.put(opts, :tool_result_contract, selector)
               )

      assert {:error, %Error{class: :not_found}} = EphemeralStore.load(store, record.run_id)
      refute_received {:executed, _}
    end
  end

  test "selected result does not change provider output accounting" do
    assert Backplane.AgentRuntime.ProviderOutput.limit(
             tool_result_contract: fn _, _ ->
               {:ok, %{output_limit: 9_000_000, json_limit: 9_000_000}}
             end
           ) == 1_048_576

    assert {:error, %Error{class: :validation}} =
             ToolResultContract.validate(%{
               schema_version: 1,
               output_limit: 2_147_483_648,
               json_limit: 2_000_000
             })
  end

  defp image_result do
    %{
      content: [%{type: "image", mimeType: "image/png", data: String.duplicate("A", 1_100_000)}],
      details: %{path: "image.png", original: true}
    }
  end

  defp fixture(result) do
    record = %{
      run_id: "contract-#{System.unique_integer([:positive])}",
      incarnation: 1,
      expected_revision: 0,
      state: :running,
      deadline: nil,
      outcome: nil,
      children: [],
      current_step: %{step_id: "step", attempt_id: "attempt"}
    }

    invocation = %{
      run_id: record.run_id,
      incarnation: 1,
      step_id: "step",
      attempt_id: "attempt",
      invocation_id: "call",
      tool_name: "image",
      tool_revision: 7,
      arguments: %{"output_limit" => 9_000_000}
    }

    descriptor = %{
      tool_name: "image",
      tool_revision: 7,
      schema: %{type: "object", additionalProperties: true},
      safety: %{read_only: true, retry_safe: true, parallel_safe: true},
      backend: ImageBackend,
      backend_context: %{test: self(), result: result}
    }

    {:ok, registry} = ToolRegistry.register(%ToolRegistry{}, descriptor)
    {:ok, budget} = Budget.new(%{work: 1})

    {record, invocation, descriptor,
     [
       registry: registry,
       authority: %{caller: "host", run_id: record.run_id, grants: ["image"], tool_revision: 7},
       budget: budget
     ]}
  end
end

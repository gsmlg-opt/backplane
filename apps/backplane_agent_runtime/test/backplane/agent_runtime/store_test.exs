defmodule Backplane.AgentRuntime.StoreTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.EphemeralStore
  alias Backplane.AgentRuntime.Error
  alias Backplane.AgentRuntime.Kernel

  describe "contract" do
    test "executes a kernel transition and exposes async discipline" do
      {:ok, store} = EphemeralStore.new(System.unique_integer([:positive]))
      run = base_run()
      command = {:admit, 10, %{state: :running, input: %{"message" => "hi"}}}
      {:ok, _run, _transition, []} = Kernel.execute(run, command)

      assert {:ok, %{revision: 1, outbox: [], mode: :ephemeral}} =
               Backplane.AgentRuntime.Store.store(
                 EphemeralStore,
                 store,
                 %{run | expected_revision: 0},
                 %{command: command}
               )

      assert {:ok, loaded} = EphemeralStore.load(store, run.run_id)
      assert loaded.run.state == :running
      assert loaded.revision == 1
      assert loaded.ephemeral == true
    end

    test "rejects stale and duplicate compare-and-set commits" do
      {:ok, store} = EphemeralStore.new(System.unique_integer([:positive]))
      run = base_run()
      command = {:admit, 10, %{state: :running}}
      {:ok, _run, _transition, []} = Kernel.execute(run, command)

      {:ok, _} = EphemeralStore.store(store, %{run | expected_revision: 0}, %{command: command})

      assert {:error, %Error{class: :resource_conflict}} =
               EphemeralStore.store(store, %{run | expected_revision: 0}, %{command: command})

      assert {:error, %Error{class: :resource_conflict}} =
               EphemeralStore.store(store, %{run | expected_revision: 2}, %{command: command})
    end

    test "kernel rejection is not a durable acknowledgement" do
      {:ok, store} = EphemeralStore.new(System.unique_integer([:positive]))
      run = base_run()

      assert {:error, %Error{class: :validation}} =
               EphemeralStore.store(
                 store,
                 %{run | expected_revision: 0, state: :completed},
                 %{command: {:admit, 10, %{}}}
               )

      assert {:error, %Error{class: :not_found}} = EphemeralStore.load(store, run.run_id)
    end
  end

  describe "mode disclosure" do
    test "declares ephemeral restart loss and missing durable features" do
      assert EphemeralStore.mode() == :ephemeral

      capabilities = EphemeralStore.capabilities()

      assert capabilities.restart_loss == true
      assert capabilities.recovery_records == false
      assert capabilities.artifact_references == false
    end
  end

  defp base_run do
    %{
      run_id: "run_#{System.unique_integer([:positive])}",
      expected_revision: 0,
      state: :queued,
      deadline: nil,
      outcome: nil,
      children: []
    }
  end
end
